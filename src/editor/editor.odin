// The editor: snapshot buffers with per-file locking and rollback, line
// and content operations, encoding- and line-ending-preserving saves, and
// the sha256 content hash used as the symbol-cache key.
//
// The buffer base is the naive snapshot design: contents are normalised to
// LF in memory, in-memory edits hide the disk until save, and a failed
// edit rolls back to the snapshot plus a disk re-read. Saves are
// synchronous, so a held buffer is never dirty — on every reuse and every
// read the buffer re-probes the disk through the IO port and adopts the
// decoded bytes when they differ, which keeps the editor's view, the
// symbol sources, and the sync listeners on one current file state
// instead of silently reverting an external writer on the next save.
// Buffer lifecycle events (open/change/close) reach language
// servers through the Buffer_Listener the services layer installs;
// symbol-shaped edits (replace body, insert before/after, docstrings,
// move) resolve their symbols through a caller-supplied symbol-source
// port and land with the tools that need them.
package editor

import "base:runtime"
import "core:encoding/hex"
import "core:crypto/sha2"
import "core:strings"
import "core:sync"
import "src:config"
import "src:platform"
import "src:regex"
import "src:safety"
import "src:util"

MAX_FILE_BYTES :: 32 << 20 // bound on any one document read

// The buffer bound. Open documents are data, not a cache — but the
// daemon's lifetime is unbounded and every distinct edited file stays
// resident forever without a cap, so the set is bounded like a cache:
// beyond EDITOR_MAX_BUFFERS files or EDITOR_MAX_BYTES of charged content
// the least recently used buffers drop through the ordinary close path.
// Buffers are never dirty (saves are synchronous), so a drop only costs a
// later re-read from disk.
EDITOR_MAX_BUFFERS :: 128
EDITOR_MAX_BYTES   :: 64 * 1024 * 1024

// Per-entry fixed charge beyond the contents: the rel_path clone, the
// buffer struct, and the lines/line_seps dynamic headers (line views
// borrow contents and add nothing).
BUFFER_FIXED_COST :: 128

// ---------------------------------------------------------------------------
// Errors and the file-IO port
// ---------------------------------------------------------------------------

// Editor_Err is the editor's closed failure vocabulary. Procedures return
// the kind plus a context message (paths, positions); the service boundary
// maps the kind structurally onto platform.Err — no string matching
// anywhere.
Editor_Err :: enum {
	None,
	Invalid,        // malformed request values (line numbers, modes, patterns)
	Invalid_Symbol, // the resolved symbol's shape does not support the operation
	NotFound,       // file not found
	Outside_Root,   // path escapes the project root (containment refusal)
	Too_Large,      // file exceeds the editor read limit
	Position,       // position outside the file, body positions unavailable
	IO,             // open/read/write failures
	Internal,       // invariant violations (unknown action)
}

// File_IO_Port is the editor's file-system seam: the domain layer must not
// touch core:os directly (testability — processes and the OS belong to the
// services layer), so the constructor injects the two operations the editor
// needs. The provider polices the size bound and classifies failures into
// Editor_Err kinds; the editor keeps the encoding and line-ending policy.
// `data` returns allocated in `alloc` and owned by the caller.
File_Read_Proc :: proc(user: rawptr, abs_path: string, max_bytes: i64, alloc: runtime.Allocator) -> (data: []u8, err: Editor_Err, msg: string)
File_Write_Proc :: proc(user: rawptr, abs_path: string, data: []u8) -> (err: Editor_Err, msg: string)

// File_Stat_Proc is the optional stat half of the port: the buffer's
// reload probe uses it to gate the full read (see buffer_reload_if_changed).
// Ports without one (test fakes) keep the always-probe behavior.
File_Stat_Proc :: proc(user: rawptr, abs_path: string) -> (mtime_ns: i64, size: i64, ok: bool)

File_IO_Port :: struct {
	user:  rawptr,
	read:  File_Read_Proc,
	write: File_Write_Proc,
	stat:  File_Stat_Proc, // optional; nil disables the reload gate
}

// ---------------------------------------------------------------------------
// File buffer
// ---------------------------------------------------------------------------

File_Buffer :: struct {
	rel_path:     string, // owned clone (alloc); the spelling this buffer opened under (listener events, messages)
	// key is the buffers-map identity: the ASCII-case-folded spelling on
	// case-insensitive filesystems (platform.path_fold), a copy of
	// rel_path's spelling on case-sensitive ones — case-varied spellings
	// of one file are one buffer and one serialization domain. Owned
	// clone; the map is keyed by it and file_buffer_destroy frees it.
	key:          string,
	contents:     string, // owned clone, LF-normalised, BOM-stripped
	// lines are views into contents — rebuilt on every set; never freed
	// individually.
	lines:        [dynamic]string,
	// line_seps[i] is the byte width of line i's terminator in contents
	// (2 for the "\r\n" an LSP-supplied edit can reintroduce after the
	// read side folded CRLF to LF, 1 for plain "\n"; a lone "\r" is
	// content, not a separator). Rebuilt with lines — the pair is what
	// makes line/col -> byte-offset math correct for either spelling.
	line_seps:    [dynamic]u8,
	// the disk file carries a leading UTF-8 BOM (a file-level marker the
	// buffer strips; save restores it). Files without one stay without.
	has_utf8_bom: bool,
	// The disk stat the buffer's contents last synced against (set by the
	// reload probe and the save path when the IO port offers a stat). A
	// matching (mtime_ns, size) lets the reload probe skip the full
	// read+decode+compare a buffer hit otherwise pays on every read;
	// has_disk_stat false (new buffers, ports without a stat) always probes.
	disk_mtime_ns: i64,
	disk_size:     i64,
	has_disk_stat:    bool,
	version:       int,
	ed:            ^Editor, // owning editor; nil = standalone untracked buffer (the ledger hook)
	allocator:     runtime.Allocator,
}

file_buffer_init :: proc(buf: ^File_Buffer, rel_path: string, contents: string, a := context.allocator) {
	buf^ = {
		rel_path = strings.clone(rel_path, a),
		contents = strings.clone(contents, a),
		lines    = make([dynamic]string, 0, 64, a),
		allocator    = a,
	}
	rebuild_lines(buf)
}

file_buffer_destroy :: proc(buf: ^File_Buffer) {
	if buf == nil {
		return
	}
	if buf.rel_path != "" {
		delete(buf.rel_path, buf.allocator)
	}
	if buf.key != "" {
		delete(buf.key, buf.allocator)
	}
	if buf.contents != "" {
		delete(buf.contents, buf.allocator)
	}
	delete(buf.lines)
	delete(buf.line_seps)
	a := buf.allocator
	free(buf, a)
}

// file_buffer_set_contents replaces the buffer contents (borrowed string,
// cloned into the buffer's allocator) and bumps the version. A tracked
// buffer charges the size delta to its editor's ledger; the mutating
// thread holds the file's h.mu, and the charge takes e.mu — the
// documented h.mu -> e.mu order.
file_buffer_set_contents :: proc(buf: ^File_Buffer, contents: string) {
	old_len := len(buf.contents)
	if buf.contents != "" {
		delete(buf.contents, buf.allocator)
	}
	buf.contents = strings.clone(contents, buf.allocator)
	buf.version += 1
	rebuild_lines(buf)
	if buf.ed != nil {
		editor_charge_buffer(buf.ed, buf, len(contents) - old_len)
	}
}

rebuild_lines :: proc(buf: ^File_Buffer) {
	delete(buf.lines)
	buf.lines = make([dynamic]string, 0, 64, buf.allocator)
	delete(buf.line_seps)
	buf.line_seps = make([dynamic]u8, 0, 64, buf.allocator)
	start := 0
	for i := 0; i <= len(buf.contents); i += 1 {
		if i < len(buf.contents) && buf.contents[i] != '\n' {
			continue
		}
		line := buf.contents[start:i]
		sep := u8(1)
		// The CRLF strip needs the '\n' this loop stopped at: the final
		// segment (i == len) has no terminator, so a '\r' ending it is
		// content and must stay in the view — stripping it there would
		// shift end-of-file column math one byte early.
		if i < len(buf.contents) && len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
			sep = 2 // the view drops the \r of a \r\n; offset math must keep it
		}
		append(&buf.lines, line)
		append(&buf.line_seps, sep)
		start = i + 1
	}
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

// Buffer_Slot is one entry of the editor's buffer LRU. The array is
// oldest-first: eviction walks from index 0, and the tail is the most
// recently used buffer. The charged cost mirrors the buffer's size at
// insert and at every contents change — maintained only under Editor.mu,
// so the prune pass never reads a buffer a concurrent edit may be
// resizing under its file lock.
Buffer_Slot :: struct {
	buf:  ^File_Buffer,
	cost: int,
}

Editor :: struct {
	project_root: string,
	// The project root's symlink-resolved spelling, computed once at init:
	// the containment check re-resolved the root on every checked read —
	// one lstat+readlink per component per read — for a root that cannot
	// change under the running editor (pathguard_resolve_root keeps the
	// raw spelling when resolution fails; the containment path handles
	// both identically).
	root_resolved: string,
	line_ending:   config.Line_Ending,
	encoding:     string, // "" = utf-8
	io:           File_IO_Port, // the injected file-system seam
	buffers:      map[string]^File_Buffer, // open documents are data, not a cache
	// The buffer bound's ledger: lru is oldest-first (the tail is most
	// recently used), buffer_bytes sums the slot costs. Both are guarded
	// by mu alongside the maps.
	lru:          [dynamic]Buffer_Slot,
	buffer_bytes: int,
	max_buffers:  int, // entry cap (EDITOR_MAX_BUFFERS unless injected)
	max_bytes:    int, // byte cap (EDITOR_MAX_BYTES unless injected)
	file_locks:   map[string]^File_Lock,
	listener:     Buffer_Listener, // optional external sink (the language-server document sync)
	allocator:    runtime.Allocator,
	mu:           sync.Mutex, // guards the buffers/file_locks maps and File_Lock.inuse
	lock_ops:     int,        // pruning counter for file_locks
}

// Buffer_Listener forwards buffer lifecycle events to an external sink:
// a buffer's creation (open), every durable content change (a completed
// edit transaction or a rollback — both leave the buffer in the state
// observers should see), and its removal (close). Callbacks run under the
// edited file's lock: sinks must not re-enter the editor for the same
// path. The struct is copied on install; `user` carries the sink's state.
Buffer_Listener :: struct {
	on_open:   proc(user: rawptr, rel_path: string, contents: string),
	on_change: proc(user: rawptr, rel_path: string, contents: string),
	on_close:  proc(user: rawptr, rel_path: string),
	user:      rawptr,
}

// editor_set_listener installs (or replaces) the buffer listener.
editor_set_listener :: proc(e: ^Editor, l: Buffer_Listener) {
	e.listener = l
}

// editor_clear_listener detaches the listener (the teardown path — the
// sink is usually being destroyed).
editor_clear_listener :: proc(e: ^Editor) {
	e.listener = {}
}

buffer_notify_open :: proc(e: ^Editor, rel_path: string, contents: string) {
	if e.listener.on_open != nil {
		e.listener.on_open(e.listener.user, rel_path, contents)
	}
}

buffer_notify_change :: proc(e: ^Editor, rel_path: string, contents: string) {
	if e.listener.on_change != nil {
		e.listener.on_change(e.listener.user, rel_path, contents)
	}
}

buffer_notify_close :: proc(e: ^Editor, rel_path: string) {
	if e.listener.on_close != nil {
		e.listener.on_close(e.listener.user, rel_path)
	}
}

// File_Lock is a per-file lock handle. inuse (guarded by Editor.mu)
// counts callers between file_lock and file_release, so the prune in
// file_release frees only entries nobody holds — a handle returned by
// file_lock stays valid until its release. (A garbage-collected lock
// table could delete unlocked entries outright — the collector keeps
// handed-out handles alive — but manual memory needs the count instead.)
File_Lock :: struct {
	path:  string, // owned clone of the folded spelling; the map key must outlive its callers' scopes
	mu:    sync.Mutex,
	inuse: int,
}

FILE_LOCK_PRUNE_INTERVAL :: 256

editor_init :: proc(
	e: ^Editor,
	project_root: string,
	line_ending: config.Line_Ending,
	encoding: string,
	io: File_IO_Port,
	a := context.allocator,
	max_buffers := EDITOR_MAX_BUFFERS,
	max_bytes := EDITOR_MAX_BYTES,
) {
	max_buffers_cap := max(max_buffers, 1)
	max_bytes_cap := max(max_bytes, 1)
	e^ = {
		project_root = strings.clone(project_root, a),
		root_resolved = safety.pathguard_resolve_root(project_root, a),
		line_ending  = line_ending,
		encoding     = strings.clone(encoding, a),
		io           = io,
		buffers      = make(map[string]^File_Buffer, 8, a),
		lru          = make([dynamic]Buffer_Slot, 0, 16, a),
		max_buffers  = max_buffers_cap,
		max_bytes    = max_bytes_cap,
		file_locks   = make(map[string]^File_Lock, 8, a),
		allocator    = a,
	}
}

editor_destroy :: proc(e: ^Editor) {
	for _, buf in e.buffers {
		file_buffer_destroy(buf)
	}
	delete(e.buffers)
	delete(e.lru)
	for _, h in e.file_locks {
		delete(h.path, e.allocator)
		free(h, e.allocator)
	}
	delete(e.file_locks)
	if e.project_root != "" {
		delete(e.project_root, e.allocator)
	}
	if e.root_resolved != "" {
		delete(e.root_resolved, e.allocator)
	}
	if e.encoding != "" {
		delete(e.encoding, e.allocator)
	}
	e^ = {}
}

// file_lock acquires the per-file lock handle: find-or-create and inuse
// increment happen atomically under e.mu, so the returned handle cannot
// be pruned away before its file_release. Pair every acquisition with
// file_release and lock h.mu only between the two.
file_lock :: proc(e: ^Editor, rel_path: string) -> ^File_Lock {
	// The fold gives case-varied spellings of one file one lock handle
	// (case-insensitive filesystems); on case-sensitive systems it is
	// the input unchanged.
	key := platform.path_fold(rel_path, context.temp_allocator)
	sync.mutex_lock(&e.mu)
	h, ok := e.file_locks[key]
	if !ok {
		h = new(File_Lock, e.allocator)
		h^ = {path = strings.clone(key, e.allocator)}
		e.file_locks[h.path] = h
	}
	h.inuse += 1
	sync.mutex_unlock(&e.mu)
	return h
}

// file_release drops a file_lock acquisition. Every FILE_LOCK_PRUNE_INTERVAL
// releases it prunes entries with inuse == 0: a handle nobody holds cannot
// be locked (h.mu is only locked between acquire and release), so freeing
// it is safe, while held entries — including callers waiting on h.mu — are
// spared.
file_release :: proc(e: ^Editor, rel_path: string) {
	key := platform.path_fold(rel_path, context.temp_allocator)
	sync.mutex_lock(&e.mu)
	h, ok := e.file_locks[key]
	if !ok {
		sync.mutex_unlock(&e.mu)
		return
	}
	h.inuse -= 1
	e.lock_ops += 1
	if e.lock_ops >= FILE_LOCK_PRUNE_INTERVAL {
		e.lock_ops = 0
		victims := make([dynamic]string, 0, 8, context.temp_allocator)
		for _, m in e.file_locks {
			if m.inuse == 0 {
				append(&victims, m.path)
			}
		}
		for path in victims {
			m := e.file_locks[path]
			delete_key(&e.file_locks, path)
			delete(m.path, e.allocator)
			free(m, e.allocator)
		}
	}
	sync.mutex_unlock(&e.mu)
}

// ---------------------------------------------------------------------------
// Buffer bound (LRU)
// ---------------------------------------------------------------------------

// buffer_cost is a buffer's charge: contents plus rel_path plus a fixed
// per-entry overhead.
buffer_cost :: proc(buf: ^File_Buffer) -> int {
	return len(buf.contents) + len(buf.rel_path) + BUFFER_FIXED_COST
}

// lru_find returns the buffer's slot index, -1 when absent (caller holds mu).
lru_find :: proc(e: ^Editor, buf: ^File_Buffer) -> int {
	for slot, i in e.lru {
		if slot.buf == buf {
			return i
		}
	}
	return -1
}

// lru_insert charges a freshly created buffer and marks it most recently
// used (caller holds mu; the buffer is not yet visible to other threads).
lru_insert :: proc(e: ^Editor, buf: ^File_Buffer) {
	slot := Buffer_Slot{buf = buf, cost = buffer_cost(buf)}
	append(&e.lru, slot)
	e.buffer_bytes += slot.cost
}

// lru_touch marks an already-tracked buffer most recently used (caller
// holds mu).
lru_touch :: proc(e: ^Editor, buf: ^File_Buffer) {
	i := lru_find(e, buf)
	if i >= 0 && i != len(e.lru) - 1 {
		slot := e.lru[i]
		ordered_remove(&e.lru, i)
		append(&e.lru, slot)
	}
}

// lru_forget removes a buffer from the LRU and refunds its charge (caller
// holds mu).
lru_forget :: proc(e: ^Editor, buf: ^File_Buffer) {
	i := lru_find(e, buf)
	if i >= 0 {
		e.buffer_bytes -= e.lru[i].cost
		ordered_remove(&e.lru, i)
	}
}

// editor_charge_buffer applies a contents-size delta to a tracked buffer's
// ledger entry (called from file_buffer_set_contents, whose caller holds
// the file's h.mu — taking e.mu here keeps the h.mu -> e.mu order).
editor_charge_buffer :: proc(e: ^Editor, buf: ^File_Buffer, delta: int) {
	sync.mutex_lock(&e.mu)
	i := lru_find(e, buf)
	if i >= 0 {
		e.lru[i].cost += delta
		e.buffer_bytes += delta
	}
	sync.mutex_unlock(&e.mu)
}

// editor_prune_buffers enforces the buffer bound: beyond max_buffers
// entries or max_bytes charged, the least recently used buffers drop
// through the ordinary close path (per-file lock, listener notification —
// the language-server document sync unpins its hot tree on close). The
// file that triggered the prune is spared: a buffer whose own cost
// exceeds max_bytes stays resident rather than dropping the just-edited
// file to admit nothing, leaving the ledger above the cap until that
// buffer closes or ages out — the same overshoot rule Bounded_Cache
// applies to pinned entries. Call it outside every editor lock (the edit
// paths register it as their first defer, so it runs last, after the file
// lock is released).
editor_prune_buffers :: proc(e: ^Editor, keep: string) {
	victims := make([dynamic]string, 0, 8, context.temp_allocator)
	defer delete(victims)
	sync.mutex_lock(&e.mu)
	if len(e.lru) > e.max_buffers || e.buffer_bytes > e.max_bytes {
		rem_entries := len(e.lru)
		rem_bytes := e.buffer_bytes
		for i := 0; i < len(e.lru); i += 1 {
			if rem_entries <= e.max_buffers && rem_bytes <= e.max_bytes {
				break
			}
			slot := e.lru[i]
			if platform.path_equal(slot.buf.rel_path, keep) {
				continue
			}
			append(&victims, slot.buf.rel_path)
			rem_entries -= 1
			rem_bytes -= slot.cost
		}
	}
	sync.mutex_unlock(&e.mu)
	for v in victims {
		editor_drop_buffer(e, v)
	}
}

// ---------------------------------------------------------------------------
// Snapshot discipline
// ---------------------------------------------------------------------------

// buffer_reload_if_changed adopts external disk bytes into a live buffer
// (the file lock must be held). Saves are synchronous, so a held buffer
// is never dirty: whenever the decoded disk read differs from the
// buffer, the disk carries a newer external state — adopt it, keeping
// reads, edits, and the sync listeners on one view instead of silently
// reverting the external change on the next save. A failed probe read
// keeps the buffer as-is (the disk may be gone; the caller's own
// existence checks decide).
buffer_reload_if_changed :: proc(e: ^Editor, rel_path: string, buf: ^File_Buffer) {
	// One stat decides whether the disk can have moved since the bytes
	// this buffer last synced against: a matching (mtime_ns, size) skips
	// the full read+decode+compare the probe otherwise pays on every
	// buffered read. The recorded stat is taken BEFORE the read it pairs
	// with, so every failure direction of a mid-probe change re-probes
	// rather than serving stale bytes: a write landing between stat and
	// read leaves the record older than the buffer's bytes, and the next
	// probe's differing stat adopts the newer state. Nanosecond stamps
	// make a same-size rewrite inside one timestamp quantum the only
	// residual window; a stat failure or an unknown record runs the full
	// probe exactly as before (external-change adoption is the contract
	// this probe exists for).
	pre_mtime, pre_size: i64
	has_pre := false
	if e.io.stat != nil {
		if abs, perr, _ := safe_path(e, rel_path); perr == .None {
			if mtime_ns, size, ok := e.io.stat(e.io.user, abs); ok {
				if buf.has_disk_stat && mtime_ns == buf.disk_mtime_ns && size == buf.disk_size {
					return
				}
				pre_mtime, pre_size, has_pre = mtime_ns, size, true
			}
		}
	}
	if data, had_bom, derr, _ := read_file_bytes(e, rel_path); derr == .None {
		// Sync the BOM marker on every probe: an external tool can add or
		// drop it without changing the decoded text.
		buf.has_utf8_bom = had_bom
		if data != buf.contents {
			file_buffer_set_contents(buf, data)
			buffer_notify_change(e, rel_path, buf.contents)
		}
		delete(data, e.allocator)
		if has_pre {
			buf.disk_mtime_ns = pre_mtime
			buf.disk_size = pre_size
			buf.has_disk_stat = true
		}
	}
}

// editor_read_file returns the file's contents from the open buffer (with
// any in-memory edits) or a fresh disk snapshot. The result is owned by
// the editor's allocator; the caller frees it.
editor_read_file :: proc(e: ^Editor, rel_path: string) -> (contents: string, err: Editor_Err, msg: string) {
	if _, perr, pmsg := safe_path(e, rel_path); perr != .None {
		return "", perr, pmsg
	}
	// Hold the file lock while cloning: a concurrent drop or edit on the
	// same file would otherwise free or rehash buf.contents mid-clone (map
	// lookups alone under e.mu do not cover the clone).
	h := file_lock(e, rel_path)
	defer file_release(e, rel_path)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)

	sync.mutex_lock(&e.mu)
	buf, ok := e.buffers[platform.path_fold(rel_path, context.temp_allocator)]
	if ok {
		lru_touch(e, buf)
	}
	sync.mutex_unlock(&e.mu)
	if ok {
		buffer_reload_if_changed(e, rel_path, buf)
		return strings.clone(buf.contents, e.allocator), .None, ""
	}
	data, _, rerr, rmsg := read_file_bytes(e, rel_path)
	return data, rerr, rmsg
}

// Edited_File is the edit-scope view handed to edit callbacks: reads and
// text edits operate on the locked snapshot buffer.
Edited_File :: struct {
	buf: ^File_Buffer,
}

// edited_insert_text inserts text at a zero-based line / UTF-16-column
// position.
edited_insert_text :: proc(ef: ^Edited_File, line: int, col: int, text: string) -> (err: Editor_Err, msg: string) {
	offset, ok := position_offset(ef.buf, line, col)
	if !ok {
		return .Position, "position outside file"
	}
	updated := strings.concatenate({ef.buf.contents[:offset], text, ef.buf.contents[offset:]}, context.temp_allocator)
	file_buffer_set_contents(ef.buf, updated)
	return .None, ""
}

// edited_delete_between removes the text between two zero-based
// line/UTF-16-column positions (inclusive start, exclusive end).
edited_delete_between :: proc(ef: ^Edited_File, start_line, start_col, end_line, end_col: int) -> (err: Editor_Err, msg: string) {
	start_off, ok := position_offset(ef.buf, start_line, start_col)
	if !ok {
		return .Position, "start position outside file"
	}
	end_off, ok2 := position_offset(ef.buf, end_line, end_col)
	if !ok2 {
		return .Position, "end position outside file"
	}
	if end_off < start_off {
		return .Position, "end position before start position"
	}
	updated := strings.concatenate({ef.buf.contents[:start_off], ef.buf.contents[end_off:]}, context.temp_allocator)
	file_buffer_set_contents(ef.buf, updated)
	return .None, ""
}

// edited_blank_line reports a line carrying nothing but horizontal
// whitespace (the buffer's line view already strips a CRLF terminator's
// CR, so a blank CRLF line reads as "").
edited_blank_line :: proc(line: string) -> bool {
	for c in line {
		if c != ' ' && c != '\t' {
			return false
		}
	}
	return true
}

// edited_collapse_blank_run trims the blank-line run at a deletion seam
// back to the neighborhood's shape. Removing a whole symbol merges the
// blank separators that surrounded it (plus, for a range delete that
// stops mid-line, the body's own trailing newline) into one multi-blank
// run; `residue` counts the run lines the deletion itself contributed
// (1 when the range kept the body's trailing newline, 0 for a
// whole-lines delete), and the run keeps a single separator only when
// it is longer than that residue. A run touching the start or the end
// of the file goes entirely. The seam line must itself be blank — a
// leftover trailing comment makes it not so and the call is a no-op.
// Line-granular deletes only: whole lines in, whole lines out.
edited_collapse_blank_run :: proc(ef: ^Edited_File, seam: int, residue: int) -> (err: Editor_Err, msg: string) {
	lines := ef.buf.lines
	if seam < 0 || seam >= len(lines) || !edited_blank_line(lines[seam]) {
		return .None, ""
	}
	top := seam
	for top > 0 && edited_blank_line(lines[top - 1]) {
		top -= 1
	}
	bot := seam
	for bot < len(lines) && edited_blank_line(lines[bot]) {
		bot += 1
	}
	keep := 0
	if bot - top > residue {
		keep = 1
	}
	if top == 0 || bot == len(lines) {
		keep = 0
	}
	if bot == len(lines) {
		// The run reaches EOF: deleting up to the start of the last line
		// leaves the final line's terminator as the file's newline.
		if top + keep >= len(lines) - 1 {
			return .None, ""
		}
		return edited_delete_between(ef, top+keep, 0, len(lines)-1, 0)
	}
	if bot - top <= keep {
		return .None, ""
	}
	return edited_delete_between(ef, top+keep, 0, bot, 0)
}

// position_offset converts a zero-based line / UTF-16 column to a byte
// offset in the buffer contents. The per-line separator width comes from
// line_seps: the stored line views hide a CRLF terminator's \r, so a flat
// "+1" per line drifts one byte per preceding CRLF line. A file with no
// trailing newline has no phantom final line, so the position one line
// past its last (line == len(lines), col 0) is accepted as the end of
// content — that is where end-of-file inserts and last-line deletes land.
position_offset :: proc(buf: ^File_Buffer, line: int, col: int) -> (offset: int, ok: bool) {
	if line < 0 || line >= len(buf.lines) {
		ends_with_newline := len(buf.contents) > 0 && buf.contents[len(buf.contents)-1] == '\n'
		if line == len(buf.lines) && col == 0 && !ends_with_newline {
			return len(buf.contents), true
		}
		return 0, false
	}
	line_start := 0
	for i := 0; i < line; i += 1 {
		line_start += len(buf.lines[i]) + int(buf.line_seps[i])
	}
	byte_col := util.utf16_col_to_byte_offset(buf.lines[line], col)
	return line_start + byte_col, true
}

// Edit_Action is one buffer edit expressed as data: an insert at a
// position, a delete between positions, or both in order (the
// replace-lines composition — a failed insert rolls back the delete
// because both run inside one edit_file scope).
Edit_Kind :: enum {
	Insert,
	Delete,
	Delete_Then_Insert,
	Replace_Content,
}

Edit_Action :: struct {
	kind:           Edit_Kind,
	start_line:     int,
	start_col:      int,
	end_line:       int,
	end_col:        int,
	text:           string, // inserted text (borrowed for the call's duration)
	needle:         string,
	repl:           string,
	mode:           string,
	allow_multiple: bool,
}

apply_action :: proc(ef: ^Edited_File, action: Edit_Action, a: runtime.Allocator) -> (err: Editor_Err, msg: string) {
	switch action.kind {
	case .Insert:
		return edited_insert_text(ef, action.start_line, action.start_col, action.text)
	case .Delete:
		return edited_delete_between(ef, action.start_line, action.start_col, action.end_line, action.end_col)
	case .Delete_Then_Insert:
		if derr, dmsg := edited_delete_between(ef, action.start_line, action.start_col, action.end_line, action.end_col); derr != .None {
			return derr, dmsg
		}
		return edited_insert_text(ef, action.start_line, 0, action.text)
	case .Replace_Content:
		parsed, pok := regex.replace_mode_from_string(action.mode)
		if !pok {
			return .Invalid, strings.concatenate(
				{"invalid mode \"", action.mode, "\": must be ", util.quoted_join(regex.REPLACE_MODE_NAMES, " or ", "\"", context.temp_allocator)},
				context.temp_allocator,
			)
		}
		cr: regex.Content_Replacer
		regex.content_replacer_init(&cr, parsed, action.allow_multiple)
		updated, rerr := regex.content_replace(&cr, ef.buf.contents, action.needle, action.repl, a)
		if rerr != nil {
			// The replacer types its failures: a missing needle is a
			// NotFound, everything else (bad pattern, mode) is Invalid.
			rkind := platform.err_kind(rerr)
			ekind: Editor_Err = .Invalid
			if rkind == .NotFound {
				ekind = .NotFound
			}
			return ekind, platform.err_message(rerr, context.temp_allocator)
		}
		defer delete(updated, a)
		file_buffer_set_contents(ef.buf, updated)
		return .None, ""
	}
	return .Internal, "unknown edit action"
}

// buffer_acquire returns the live buffer for rel_path, loading the file
// on first use; a reused buffer first adopts any external disk change
// (saves are synchronous, so the disk can only be ahead through an
// external writer). The caller holds the file lock for rel_path.
buffer_acquire :: proc(e: ^Editor, rel_path: string) -> (^File_Buffer, Editor_Err, string) {
	key := platform.path_fold(rel_path, context.temp_allocator)
	sync.mutex_lock(&e.mu)
	buf, ok := e.buffers[key]
	if ok {
		lru_touch(e, buf)
	}
	sync.mutex_unlock(&e.mu)
	if !ok {
		data, had_bom, derr, dmsg := read_file_bytes(e, rel_path)
		if derr != .None {
			return nil, derr, dmsg
		}
		buf = new(File_Buffer, e.allocator)
		file_buffer_init(buf, rel_path, data, e.allocator)
		buf.ed = e
		buf.has_utf8_bom = had_bom
		buf.key = strings.clone(key, e.allocator)
		delete(data, e.allocator)
		sync.mutex_lock(&e.mu)
		// Key by the buffer's own folded clone: the caller's spelling
		// views request-arena memory that dies after dispatch, and
		// case-varied spellings of one file must land on this one buffer
		// (file_buffer_destroy frees the key bytes).
		e.buffers[buf.key] = buf
		lru_insert(e, buf)
		sync.mutex_unlock(&e.mu)
		buffer_notify_open(e, rel_path, buf.contents)
	} else {
		buffer_reload_if_changed(e, rel_path, buf)
	}
	return buf, .None, ""
}

// edit_file runs one edit under the file lock with snapshot rollback:
// the action edits the buffer; on action or save failure the buffer is
// restored from the snapshot (re-reading the disk when possible), so a
// partial edit never reaches the disk.
edit_file :: proc(e: ^Editor, rel_path: string, action: Edit_Action) -> (err: Editor_Err, msg: string) {
	if _, perr, pmsg := safe_path(e, rel_path); perr != .None {
		return perr, strings.concatenate({"invalid relative path: ", pmsg}, context.temp_allocator)
	}

	// First-registered defer fires last: the bound check runs outside
	// every editor lock (it takes per-victim file locks itself).
	defer editor_prune_buffers(e, rel_path)

	h := file_lock(e, rel_path)
	defer file_release(e, rel_path)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)

	buf, acq_err, acq_msg := buffer_acquire(e, rel_path)
	if acq_err != .None {
		return acq_err, acq_msg
	}
	snapshot := strings.clone(buf.contents, e.allocator)
	defer delete(snapshot, e.allocator)

	ef := Edited_File{buf = buf}
	if aerr, amsg := apply_action(&ef, action, e.allocator); aerr != .None {
		rollback_buffer(e, buf, rel_path, snapshot)
		return aerr, amsg
	}

	if serr, smmsg := save(e, rel_path, buf.contents, buf.has_utf8_bom); serr != .None {
		rollback_buffer(e, buf, rel_path, snapshot)
		return serr, strings.concatenate({"save edited file: ", smmsg}, context.temp_allocator)
	}
	// The written bytes have no observed stat: drop the reload gate's
	// record so the next read probes (and re-records with a pre-read
	// stat). Stating after our own write would pair the record with
	// whoever wrote last, not necessarily this buffer.
	buf.has_disk_stat = false
	buffer_notify_change(e, rel_path, buf.contents)
	return .None, ""
}

// rollback_buffer restores a buffer to a known-good state after a failed
// edit or save, preferring a disk re-read so the buffer matches reality.
rollback_buffer :: proc(e: ^Editor, buf: ^File_Buffer, rel_path: string, original: string) {
	if data, had_bom, derr, _ := read_file_bytes(e, rel_path); derr == .None {
		buf.has_utf8_bom = had_bom
		file_buffer_set_contents(buf, data)
		delete(data, e.allocator)
		buffer_notify_change(e, rel_path, buf.contents)
		return
	}
	file_buffer_set_contents(buf, original)
	buffer_notify_change(e, rel_path, buf.contents)
}

// save writes the buffer contents to disk with the configured line ending
// and encoding. restore_utf8_bom prepends the UTF-8 BOM the disk file
// carried when it was read (the buffer strips it); files that never had
// one pass false and gain nothing. The BOM restore applies to the default
// UTF-8 encoding class only — UTF-16 output always carries its own BOM and
// latin-1 never special-cases a leading U+FEFF.
save :: proc(e: ^Editor, rel_path: string, contents: string, restore_utf8_bom := false) -> (err: Editor_Err, msg: string) {
	abs, perr, pmsg := safe_path(e, rel_path)
	if perr != .None {
		return perr, pmsg
	}
	normalised := normalise_line_endings(e, contents, context.temp_allocator)
	encoding := e.encoding
	if encoding == "" {
		encoding = config.DEFAULT_ENCODING
	}
	bytes, owns_bytes := util.encode_content(encoding, normalised, e.allocator)
	defer if owns_bytes && len(bytes) > 0 {
		delete(bytes, e.allocator)
	}
	if restore_utf8_bom {
		is_latin1 := util.is_latin1_encoding(encoding)
		is16, _ := util.utf16_encoding(encoding)
		// encode_content returns a view for the UTF-8 class, so nothing is
		// freed when bytes is replaced here; the defer above then owns the
		// combined buffer. Content already carrying a BOM keeps exactly one.
		if !is_latin1 && !is16 && !util.has_utf8_bom(bytes) {
			with_bom := make([]u8, 3 + len(bytes), e.allocator)
			with_bom[0] = util.UTF8_BOM_BYTE0
			with_bom[1] = util.UTF8_BOM_BYTE1
			with_bom[2] = util.UTF8_BOM_BYTE2
			copy(with_bom[3:], bytes)
			bytes = with_bom
			owns_bytes = true
		}
	}

	werr, wmsg := e.io.write(e.io.user, abs, bytes)
	if werr != .None {
		if wmsg != "" {
			return werr, strings.concatenate({"write failed: ", rel_path, ": ", wmsg}, context.temp_allocator)
		}
		return werr, strings.concatenate({"write failed: ", rel_path}, context.temp_allocator)
	}
	return .None, ""
}

// normalise_line_endings converts LF content to the target convention.
// A \r\n pair is ONE newline — re-emitted as the target convention, the
// same unit the read side folds — while a lone '\r' is content and
// passes through. Treating the pair as a unit is what makes this the
// read side's exact inverse: buffers may carry raw pairs from inserted
// text (rebuild_lines' sep-2 view), and translating only the '\n' byte
// would write those pairs to disk as \r\r\n. The result (both branches)
// is allocated in `a`: the builder branch returns a view into its
// `a`-backed buffer, so the string's lifetime is `a`'s — callers must
// consume it within that arena's lifetime.
normalise_line_endings :: proc(e: ^Editor, contents: string, a: runtime.Allocator) -> string {
	newline := config.line_ending_newline(e.line_ending)
	if newline == "\n" {
		return strings.clone(contents, a)
	}
	b := strings.builder_make(a)
	i := 0
	for i < len(contents) {
		c := contents[i]
		if c == '\r' && i + 1 < len(contents) && contents[i + 1] == '\n' {
			strings.write_string(&b, newline)
			i += 2
		} else if c == '\n' {
			strings.write_string(&b, newline)
			i += 1
		} else {
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return strings.to_string(b)
}

// read_file_bytes reads and decodes a project file through the IO port
// (the provider polices the size bound), returning LF-normalised contents
// owned by the caller (editor allocator). had_utf8_bom reports a leading
// UTF-8 BOM the default (UTF-8) decode stripped from the contents — a
// file-level marker, not buffer text, so line-0 edits cannot displace it
// and line-1 deletes cannot swallow it; save restores it. UTF-16 decode
// consumes its BOM as the byte-order marker (save always writes one back)
// and latin-1 treats those bytes as content, so both report false.
read_file_bytes :: proc(e: ^Editor, rel_path: string) -> (contents: string, had_utf8_bom: bool, err: Editor_Err, msg: string) {
	abs, perr, pmsg := safe_path(e, rel_path)
	if perr != .None {
		return "", false, perr, pmsg
	}
	data, rerr, rmsg := e.io.read(e.io.user, abs, MAX_FILE_BYTES, e.allocator)
	if rerr != .None {
		return "", false, rerr, rmsg
	}
	// Ownership of `data` transfers to the returned contents on the plain
	// UTF-8 fast path (no BOM, no CRLF); every other path clones into the
	// editor allocator and the read buffer dies at return.
	transferred := false
	defer if !transferred {
		delete(data, e.allocator)
	}
	encoding := e.encoding
	if encoding == "" {
		encoding = config.DEFAULT_ENCODING
	}
	decoded, had_bom, moved := util.decode_content(encoding, data, e.allocator)
	if moved {
		transferred = true
	}
	if strings.contains(decoded, "\r\n") {
		// Fold only complete \r\n pairs; a lone '\r' is content (the save
		// side passes it through), so folding it too would make the
		// buffer drift from the decoded disk on every probe.
		b := strings.builder_make(e.allocator)
		i := 0
		for i < len(decoded) {
			if decoded[i] == '\r' && i + 1 < len(decoded) && decoded[i + 1] == '\n' {
				strings.write_byte(&b, '\n')
				i += 2
			} else {
				strings.write_byte(&b, decoded[i])
				i += 1
			}
		}
		delete(decoded, e.allocator)
		// View into the builder's e.allocator-backed buffer: valid for the
		// editor allocator's lifetime, like every other return here.
		decoded = strings.to_string(b)
	}
	return decoded, had_bom, .None, ""
}

safe_path :: proc(e: ^Editor, rel_path: string) -> (abs: string, err: Editor_Err, msg: string) {
	resolved, perr := safety.pathguard_validate_contained_resolved(e.root_resolved, rel_path, context.temp_allocator)
	if perr.reason != "" {
		return "", .Outside_Root, perr.reason
	}
	return resolved, .None, ""
}

// editor_drop_buffer discards a file's in-memory buffer (the next read
// reloads from disk) — the "revert to on-disk content" operation. It takes
// the per-file lock handle first so in-flight edit/read holders on the same
// file finish before the buffer is destroyed (lock order file-lock →
// e.mu, matching the edit paths).
editor_drop_buffer :: proc(e: ^Editor, rel_path: string) {
	h := file_lock(e, rel_path)
	defer file_release(e, rel_path)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	drop_buffer_locked(e, rel_path)
}

// drop_buffer_locked is the buffer-drop step for callers that already hold
// the per-file lock (the svc write/delete/move paths): the disk write and
// the buffer drop must be ONE serialized step, so those paths share this
// body instead of re-acquiring the lock through editor_drop_buffer (the
// mutex is not recursive).
drop_buffer_locked :: proc(e: ^Editor, rel_path: string) {
	key := platform.path_fold(rel_path, context.temp_allocator)
	sync.mutex_lock(&e.mu)
	buf, ok := e.buffers[key]
	if ok {
		lru_forget(e, buf)
		// The returned stored key is deliberately DISCARDED: it is the
		// buffer's own key clone (see the insert site), and
		// file_buffer_destroy below frees those same bytes through
		// buf.key — freeing the handed-back key here would
		// double-free (a suite bad-free proved it). Unlike the tracker
		// maps, this map's key ownership lives with the value.
		delete_key(&e.buffers, key)
	}
	sync.mutex_unlock(&e.mu)
	if ok {
		// Listeners pair open/close by spelling: close reports the
		// spelling the buffer opened under, which a case-varied drop
		// spelling can differ from.
		buffer_notify_close(e, buf.rel_path)
		file_buffer_destroy(buf)
	}
}

// ---------------------------------------------------------------------------
// Line and content operations
// ---------------------------------------------------------------------------

editor_insert_at_line :: proc(e: ^Editor, rel_path: string, line: int, content: string) -> (err: Editor_Err, msg: string) {
	if line < 0 {
		return .Invalid, "line number must be >= 0"
	}
	return edit_file(e, rel_path, {kind = .Insert, start_line = line, start_col = 0, text = content})
}

// editor_delete_lines removes lines start_line..end_line (0-based,
// inclusive).
editor_delete_lines :: proc(e: ^Editor, rel_path: string, start_line, end_line: int) -> (err: Editor_Err, msg: string) {
	return edit_file(e, rel_path, {
		kind = .Delete,
		start_line = start_line, start_col = 0,
		end_line = end_line + 1, end_col = 0,
	})
}

// editor_replace_lines replaces lines start_line..end_line (0-based,
// inclusive) with new content — delete and insert share one edit scope so
// a failed insert rolls back the delete.
editor_replace_lines :: proc(e: ^Editor, rel_path: string, start_line, end_line: int, content: string) -> (err: Editor_Err, msg: string) {
	// Temp scratch, never delete()d: delete frees through
	// context.allocator, mismatching the temp arena.
	with_trailing := util.ensure_trailing_newline(content, context.temp_allocator)
	return edit_file(e, rel_path, {
		kind = .Delete_Then_Insert,
		start_line = start_line, start_col = 0,
		end_line = end_line + 1, end_col = 0,
		text = with_trailing,
	})
}

// editor_replace_content replaces needle with repl under the replacement
// mode ("literal" or "regex", first or all).
editor_replace_content :: proc(e: ^Editor, rel_path: string, needle, repl, mode: string, allow_multiple: bool) -> (err: Editor_Err, msg: string) {
	return edit_file(e, rel_path, {
		kind = .Replace_Content,
		needle = needle,
		repl = repl,
		mode = mode,
		allow_multiple = allow_multiple,
	})
}

// ---------------------------------------------------------------------------
// Content hash (sha256 hex) for cache keys
// ---------------------------------------------------------------------------

content_hash_hex :: proc(contents: string, a := context.allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)contents)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	enc, _ := hex.encode(digest[:], a)
	return string(enc)
}
