// The manager owns the running language servers of one project root:
// start-on-demand with restart-after-death, a failure cooldown, idle
// reclamation, status enumeration, and staged teardown. Long operations
// (spawn, initialize, stop) run outside the manager mutex; the mutex
// guards only the tables plus the per-language "starting" marker that
// serializes concurrent starts of the same language.
package langserver

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsproc"
import "src:lsp"
import "src:platform"
import "src:symbol"
import "src:util"

MANAGER_IDLE_TIMEOUT_MS     :: i64(600_000) // 10 min without use → stop
MANAGER_IDLE_TICK_MS        :: i64(60_000)
MANAGER_IDLE_SLICE_MS       :: i64(25) // shutdown latency bound for the monitor
MANAGER_RESTART_COOLDOWN_MS :: i64(30_000)
MANAGER_STOP_GRACE_MS       :: i64(5_000)
MANAGER_MEMORY_LIMIT_MB     :: 2048
MANAGER_EAGER_SYNC          :: 3 // eager starts awaited synchronously
MANAGER_ENSURE_SLICE_MS     :: i64(25)
MANAGER_MAX_START_ATTEMPTS  :: 1 // one start per ensure call — no live loops
// Hard cap on waiting for another thread's start: the start itself is
// bounded by the handshake deadline, so a park past this means the
// starter is stuck — the waiter reports a timeout instead of parking
// forever.
MANAGER_ENSURE_PARK_MAX_MS :: i64(60_000)

// Server is one running language-server instance: the lsp client over
// its connection, the process when the factory spawned one, and the
// threads the factory started. A fake factory (tests) supplies client
// and conn only. Owned by the manager's allocator.
Server :: struct {
	language_id: string,
	entry:       ^Entry, // borrowed from the registry (outlives the manager)
	// owned absolute workspace folder paths; [0] is the primary root.
	// Nil for in-process fakes that never went through the factory.
	folders:     []string,
	client:      ^lsp.Client,
	conn:        ^jsonrpc.Conn,
	child:       ^lsproc.Proc, // nil for in-process fakes
	reader:      ^thread.Thread, // stdio read loop; nil when host-owned
	stderr_pump: ^thread.Thread,
	inflight:    i64, // outstanding client hand-outs; destroy waits for zero
	allocator:   mem.Allocator,
}

// Factory_Create_Proc assembles and initializes one Server. `a` is the
// SERVER-LIFETIME allocator (the manager's), not a request arena; argv,
// env, and the folders are views the create call may clone as it sees
// fit. folders carries at least one workspace folder; folders[0] is the
// primary root (process working directory, rootUri, URI-resolution
// base). The returned Server is fully initialized (handshake done).
Factory_Create_Proc :: proc(
	user:            rawptr,
	entry:           ^Entry,
	argv:            []string,
	env:             []string,
	folders:         []Workspace_Folder,
	memory_limit_mb: int,
	clock:           ^platform.Clock,
	a:               mem.Allocator,
	token:           ^platform.Cancel_Token,
) -> (s: ^Server, err: platform.Err)

Factory :: struct {
	user:   rawptr,
	create: Factory_Create_Proc,
}

Status_Row :: struct {
	id:      string, // owned by the caller's allocator
	running: bool,
	// folders/root describe the running server's workspace: the folder
	// count and the primary folder path. Zero/empty when not running.
	folders: int,
	root:    string, // owned by the caller's allocator
}

// Running_Client is one alive server as manager_running_clients reports it.
Running_Client :: struct {
	language_id: string,
	client:      ^lsp.Client,
}

Manager :: struct {
	reg:              ^Registry,
	root:             string, // owned
	root_uri:         string, // owned
	clock:            ^platform.Clock,
	allocator:        mem.Allocator,
	factory:          Factory,

	// Configuration: project-supplied settings, installed at init and
	// swapped wholesale by the config/project-transition setters
	// (manager_set_allow/_overrides/_options/_seeds).
	allow:            []string, // owned project language allowlist; empty = detect-based
	// owned: language id → explicit argv from project config (argv[0] is
	// the command). An explicit argv wins over the entry's command, its
	// dynamic resolver, and its runtime checks; nil = none configured.
	overrides:        map[string][]string,
	// owned: language id → serialized JSON object text from project
	// config, merged over the entry's static init options at the
	// initialize handshake (user top-level keys win). Nil = none
	// configured.
	options:          map[string]string,
	// Eager start: spawn every allowed language at manager_start_eager,
	// which walks the registry on eager_thread (bottom of the struct).
	eager:            bool,
	// owned: extra workspace folders (already validated as contained in
	// the project root by the caller) that multi-root scans announce
	// ahead of the discovered marker directories. Nil = none configured.
	seeds:            []string,
	// Idle sweep tuning (init-time constants): the idle_thread's reap
	// threshold and poll interval.
	idle_timeout_ms:  i64,
	idle_interval_ms: i64,

	// Runtime state, guarded by mu.
	mu:               sync.Mutex,
	// Table-key ownership: every key that outlives the call which inserted
	// it must be owned by the manager's allocator. `servers` borrows each
	// live server's language_id (factory-cloned into m.allocator) — every
	// retire path delete_keys the entry BEFORE server_destroy frees those
	// bytes, and a restart deletes before inserting so the stored key is
	// always the live server's. `last_fail_ms` and `last_use_ms` clone on
	// first insert (mark_failure / last_use_note) because their entries
	// outlive servers, and the clones are freed when the tables are
	// cleared (manager_reset's cooldown wipe, manager_destroy). Lookups
	// may use any content-equal string, but inserting under a caller's
	// string (an RPC request arena, say) leaves a key that rots once that
	// request ends — every later keyed lookup misses and every keyed
	// delete_key silently fails, which once turned manager_reset's retire
	// loop into an unbounded allocate-and-destroy spin. `starting` is
	// exempt: its markers are inserted and deleted within the same
	// manager_ensure call.
	starting:         map[string]bool,
	cond:             sync.Cond, // broadcast when a starting marker clears
	servers:          map[string]^Server,
	retiring:         [dynamic]^Server, // unlinked; destroyed once inflight reaches zero
	last_fail_ms:     map[string]i64,
	last_use_ms:      map[string]i64,
	is_stopped:       bool,
	// Destroy-time cancellation (nil = none): latched by manager_destroy
	// so the idle and eager threads observe the same token as the
	// teardown ladder — the reaper's sweep and the eager walk's in-flight
	// start shorten at their next checkpoint. Guarded by mutex.
	cancel:           ^platform.Cancel_Token,
	trace_lsp:        bool, // frame tracing for servers started from here on

	// Worker threads, stopped and joined by the destroy ladder
	// (manager_stop_idle / manager_stop_eager).
	idle_thread:      ^thread.Thread,
	idle_args:        Idle_Args,
	// started by manager_start_eager — only when the eager config bool
	// (above, in the configuration section) is set.
	eager_thread:     ^thread.Thread,
	eager_args:       Eager_Args,
}

// manager_init prepares the manager. Nothing is spawned until an ensure
// call or manager_start_eager; the registry must outlive the manager.
manager_init :: proc(
	m: ^Manager,
	reg: ^Registry,
	root: string,
	clock: ^platform.Clock,
	factory: Factory,
	allow: []string,
	eager: bool,
	a := context.allocator,
) {
	m^ = {
		reg       = reg,
		root      = strings.clone(root, a),
		root_uri  = symbol.file_uri(root, a),
		clock     = clock,
		allocator = a,
		factory   = factory,
		allow     = clone_strings(allow, a),
		eager     = eager,
	}
	m.starting = make(map[string]bool, 4, a)
	m.servers = make(map[string]^Server, 4, a)
	m.options = make(map[string]string, 4, a)
	m.retiring = make([dynamic]^Server, 0, 4, a)
	m.last_fail_ms = make(map[string]i64, 4, a)
	m.last_use_ms = make(map[string]i64, 4, a)
	m.idle_timeout_ms = MANAGER_IDLE_TIMEOUT_MS
	m.idle_interval_ms = MANAGER_IDLE_TICK_MS
}

// manager_destroy stops everything and frees the manager's owned state.
// Idempotent. The stop flag latches and the token lands on m.cancel
// BEFORE the thread joins below: the eager walk skips its remaining
// languages and aborts its in-flight start, and the reaper's in-flight
// sweep shortens, instead of the joins waiting out the full walk and
// every graceful teardown budget. (manager_stop_all re-latches the flag
// for its own reset path.)
manager_destroy :: proc(m: ^Manager, token: ^platform.Cancel_Token = nil) {
	sync.mutex_lock(&m.mu)
	// The idempotency latch: the reset at the bottom zeroes the struct
	// (allocator included), and nothing but that reset ever does — a nil
	// reg marks an already-destroyed manager. The early return keeps the
	// second call from manager_reset's cooldown map make, which would
	// allocate through the zeroed allocator.
	already := m.reg == nil
	m.is_stopped = true
	m.cancel = token
	sync.mutex_unlock(&m.mu)
	if already {
		return
	}
	manager_stop_idle(m)
	manager_stop_eager(m)
	manager_stop_all(m, token)
	// Final teardown backstop: a retiring server still holding a hand-out
	// is destroyed regardless — the children (and their in-flight calls)
	// have drained by now, so this closes the book rather than races.
	for s in m.retiring {
		server_destroy(s, token)
	}
	delete(m.retiring)
	delete(m.starting)
	delete(m.servers)
	// The cooldown and last-use keys are manager-owned clones (see
	// Manager); the servers' ids were freed by server_destroy above.
	free_owned_string_keys(&m.last_fail_ms, m.allocator)
	free_owned_string_keys(&m.last_use_ms, m.allocator)
	delete(m.root, m.allocator)
	delete(m.root_uri, m.allocator)
	free_strings(m.allow, m.allocator)
	free_strings(m.seeds, m.allocator)
	free_string_array_map(m.overrides, m.allocator)
	free_string_map(m.options, m.allocator)
	// Reset like every sibling destroyer: the freed members must not stay
	// dangling for straggling readers. The is_stopped flag and cancel
	// token outlive the reset on purpose: a factory create that raced
	// this destroy checks them after the create returns
	// (start_language, manager_restart) and must still find the manager
	// dead — a plain zeroing resurrects it as alive-with-empty-tables,
	// and the insert that follows lands in a zero-value map through the
	// wrong allocator.
	m^ = {}
	m.is_stopped = true
	m.cancel = token
}

// manager_set_seeds installs the extra workspace folders for multi-root
// scans (already validated as contained in the project root by the
// caller), cloning them into the manager's allocator; the swap pattern
// matches the overrides. Running servers keep the folder set they were
// started with until a restart re-scans.
manager_set_seeds :: proc(m: ^Manager, seeds: []string) {
	sync.mutex_lock(&m.mu)
	old := m.seeds
	m.seeds = clone_strings(seeds, m.allocator)
	sync.mutex_unlock(&m.mu)
	if old != nil {
		free_strings(old, m.allocator)
	}
}

// manager_seeds copies the configured seeds onto `arena` under the
// manager mutex — one critical section with the read, because a swap
// frees the old slice the moment the lock drops.
manager_seeds :: proc(m: ^Manager, arena: mem.Allocator) -> []string {
	sync.mutex_lock(&m.mu)
	seeds := clone_strings(m.seeds, arena)
	sync.mutex_unlock(&m.mu)
	return seeds
}

// manager_set_overrides installs explicit per-language argv overrides
// (argv[0] = command), cloning them into the manager's allocator. The
// previous overrides are freed after the swap; a concurrent start clones
// under the same mutex, so it sees either the old or the new map intact.
// Running servers keep the argv they were started with.
manager_set_overrides :: proc(m: ^Manager, overrides: map[string][]string) {
	sync.mutex_lock(&m.mu)
	old := m.overrides
	m.overrides = clone_string_array_map(overrides, m.allocator)
	sync.mutex_unlock(&m.mu)
	free_string_array_map(old, m.allocator)
}

// manager_set_options installs per-language initialization options
// (serialized JSON object text), cloning them into the manager's
// allocator; the swap pattern matches the overrides. Running servers
// keep the options they were started with until a restart re-merges.
manager_set_options :: proc(m: ^Manager, options: map[string]string) {
	sync.mutex_lock(&m.mu)
	old := m.options
	m.options = clone_string_map(options, m.allocator)
	sync.mutex_unlock(&m.mu)
	free_string_map(old, m.allocator)
}

// clone_options_json copies the language's serialized options text onto
// `a` under the manager mutex — one critical section with the read,
// because a swap frees the old map the moment the lock drops (the
// clone_override_argv rule). "" when none are configured.
clone_options_json :: proc(m: ^Manager, language_id: string, a: mem.Allocator) -> string {
	sync.mutex_lock(&m.mu)
	out: string = ""
	if v, found := m.options[language_id]; found {
		out = strings.clone(v, a)
	}
	sync.mutex_unlock(&m.mu)
	return out
}

// clone_override_argv copies the language's override argv onto `arena`
// under the manager mutex — one critical section with the read, because a
// swap frees the old map the moment the lock drops.
clone_override_argv :: proc(m: ^Manager, language_id: string, arena: mem.Allocator) -> []string {
	sync.mutex_lock(&m.mu)
	argv, found := m.overrides[language_id]
	out: []string = nil
	if found {
		out = clone_strings(argv, arena)
	}
	sync.mutex_unlock(&m.mu)
	return out
}

// manager_set_trace turns LSP frame tracing on for servers started from
// here on; a running server keeps its setting until a restart picks it
// up (the connection's trace hook is write-once before its threads start).
manager_set_trace :: proc(m: ^Manager, on: bool) {
	sync.mutex_lock(&m.mu)
	m.trace_lsp = on
	sync.mutex_unlock(&m.mu)
}

manager_trace_enabled :: proc(m: ^Manager) -> bool {
	sync.mutex_lock(&m.mu)
	on := m.trace_lsp
	sync.mutex_unlock(&m.mu)
	return on
}

// manager_ensure returns a live client for the language, starting or
// restarting as needed. A dead server is never waited on inside a single
// call: it is replaced here so the NEXT call recovers
// (restart-after-death), at most one start happens per call, and a
// failed start arms the cooldown so a broken toolchain cannot become a
// fork bomb.
manager_ensure :: proc(
	m: ^Manager,
	language_id: string,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token = nil,
) -> (^lsp.Client, platform.Err) {
	attempts := 0
	park_deadline := platform.clock_now(m.clock) + MANAGER_ENSURE_PARK_MAX_MS
	for {
		sync.mutex_lock(&m.mu)
		if m.is_stopped {
			sync.mutex_unlock(&m.mu)
			return nil, platform.Err(.Terminated)
		}
		s := m.servers[language_id]
		if s != nil && server_alive(s) {
			last_use_note(m, language_id, platform.clock_now(m.clock))
			s.inflight += 1 // hand-out pin; dropped by manager_release
			client := s.client
			sync.mutex_unlock(&m.mu)
			return client, nil
		}
		if s != nil && !server_alive(s) {
			// Drop the corpse from the table; teardown runs outside the
			// lock (deferred while a hand-out is still in flight) and the
			// loop retries the start path.
			delete_key(&m.servers, language_id)
			append(&m.retiring, s)
			sync.cond_broadcast(&m.cond)
			sync.mutex_unlock(&m.mu)
			manager_sweep_retiring(m, token)
			continue
		}
		if m.starting[language_id] {
			// Another thread is bringing the server up — wait in slices
			// so cancellation and shutdown take effect promptly. The park
			// is deadline-capped even without a token: a start is bounded
			// by the handshake clock, and no caller may wait on it
			// forever (the buffer-sync paths used to arrive here with a
			// nil token under an editor file lock).
			if token != nil {
				if _, fired := platform.token_check(token); fired {
					sync.mutex_unlock(&m.mu)
					return nil, platform.Err(.Cancelled)
				}
			}
			if platform.clock_now(m.clock) >= park_deadline {
				sync.mutex_unlock(&m.mu)
				return nil, platform.Wrapped{
					kind = .Timeout,
					msg  = "timed out waiting for a concurrent language-server start",
				}
			}
			// Real-time cond slice by design: the
			// start marker it waits on clears from another thread, so
			// only the slice length bounds wake latency.
			sync.cond_wait_with_timeout(
				&m.cond, &m.mu, time.Duration(MANAGER_ENSURE_SLICE_MS * 1_000_000),
			)
			sync.mutex_unlock(&m.mu)
			continue
		}
		if attempts >= MANAGER_MAX_START_ATTEMPTS {
			sync.mutex_unlock(&m.mu)
			return nil, platform.Wrapped{
				kind = .Terminated,
				msg  = "language server exited immediately after start",
			}
		}
		attempts += 1
		m.starting[language_id] = true
		sync.mutex_unlock(&m.mu)

		err := start_language(m, language_id, arena, token)

		sync.mutex_lock(&m.mu)
		delete_key(&m.starting, language_id)
		sync.cond_broadcast(&m.cond)
		sync.mutex_unlock(&m.mu)
		if err != nil {
			return nil, err
		}
	}
}

// start_language performs the start while the "starting" marker is
// held: cooldown gate, entry resolution, runtime check, argv/env
// assembly, factory call.
start_language :: proc(
	m: ^Manager,
	language_id: string,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> platform.Err {
	now := platform.clock_now(m.clock)
	// Presence (not > 0) carries "has failed": a virtual clock's epoch
	// is zero, so a timestamp of 0 is a legitimate failure time. The map
	// read takes the mutex: mark_failure inserts and manager_reset frees
	// the map under it, and an unlocked read races both.
	sync.mutex_lock(&m.mu)
	last, failed := m.last_fail_ms[language_id]
	sync.mutex_unlock(&m.mu)
	if failed && now - last < MANAGER_RESTART_COOLDOWN_MS {
		return platform.Wrapped{
			kind = .Retryable,
			msg  = "language server failed recently; retrying after the cooldown",
		}
	}

	e := registry_find(m.reg, language_id)
	if e == nil {
		return platform.Err(.NotFound)
	}
	argv, argv_err := resolve_start_argv(m, e, arena)
	if argv_err != nil {
		mark_failure(m, language_id)
		return argv_err
	}
	folders := start_workspace(m, e, arena)
	env := build_server_env(m.reg, e, arena)

	s, err := m.factory.create(
		m.factory.user, e, argv, env, folders, memory_limit_for(e), m.clock, m.allocator, token,
	)
	if err != nil {
		mark_failure(m, language_id)
		return err
	}
	sync.mutex_lock(&m.mu)
	// The factory create ran without the mutex and may span seconds (spawn
	// + handshake); a reset/destroy that fired inside that window has
	// drained and deleted m.servers, and inserting would resurrect the
	// deleted map through the wrong allocator and strand a live server.
	// The finished server is destroyed instead, outside the mutex, with
	// the manager's cancel token (the one the destroy path itself rides).
	if m.is_stopped {
		cancel := m.cancel
		sync.mutex_unlock(&m.mu)
		server_destroy(s, cancel)
		return platform.Err(.Cancelled)
	}
	// Keyed by the server's own language_id clone (see Manager): the
	// param views the caller's memory and would rot in place.
	m.servers[s.language_id] = s
	last_use_note(m, s.language_id, platform.clock_now(m.clock))
	sync.mutex_unlock(&m.mu)
	return nil
}

// start_workspace resolves one start's workspace folders: the project
// root alone, or — for a multi-root entry with root markers — the
// marker scan seeded with the configured extras. A single detected root
// (the ordinary one-repository project) yields exactly the project-root
// folder the pre-multi-root code announced. Views owned by `arena`; the
// factory clones what the server keeps.
start_workspace :: proc(m: ^Manager, e: ^Entry, arena: mem.Allocator) -> []Workspace_Folder {
	paths: []string
	if e.multi_root && len(e.root_markers) > 0 {
		paths = scan_language_roots(m.root, e.root_markers, manager_seeds(m, arena), arena)
	} else {
		single := [1]string{m.root}
		paths = clone_strings(single[:], arena)
	}
	folders := make([]Workspace_Folder, len(paths), arena)
	for i in 0..<len(paths) {
		folders[i] = {
			path = paths[i],
			uri  = symbol.file_uri(paths[i], arena),
			name = path_basename(paths[i]),
		}
	}
	return folders
}

mark_failure :: proc(m: ^Manager, language_id: string) {
	sync.mutex_lock(&m.mu)
	// A destroy that raced a still-running start zeroes the manager (the
	// allocator included) after freeing its tables; recording a failure on
	// a dead manager would clone through a zeroed allocator. The flag is
	// latched before the tables die and survives the reset, so checking it
	// here closes the argv-error and create-failure windows the success
	// path already guards (start_language's is_stopped check).
	if m.is_stopped {
		sync.mutex_unlock(&m.mu)
		return
	}
	if _, ok := m.last_fail_ms[language_id]; !ok {
		// First insert owns the key (a failure can be recorded with no
		// server alive to borrow an id from); later failures only update
		// the value through the content match.
		m.last_fail_ms[strings.clone(language_id, m.allocator)] = platform.clock_now(m.clock)
	} else {
		m.last_fail_ms[language_id] = platform.clock_now(m.clock)
	}
	sync.mutex_unlock(&m.mu)
}

// last_use_note records a use under a manager-owned key: the first note
// for a language clones its id, later notes only update the value. Never
// key this table with a server's own id bytes — they die with the server
// and would rot the entry (see Manager). Caller holds m.mu.
last_use_note :: proc(m: ^Manager, id: string, now: i64) {
	if _, ok := m.last_use_ms[id]; !ok {
		m.last_use_ms[strings.clone(id, m.allocator)] = now
	} else {
		m.last_use_ms[id] = now
	}
}

// resolve_start_argv produces the argv for starting `e`'s language: an
// explicit override when one is configured, otherwise the entry's own
// runtime check and resolver. The override wins over both — the config
// named exactly what to run, and the custom-path case is precisely "the
// binary is not on PATH", which the entry's own PATH probes would reject —
// so only the override's argv[0] must resolve (PATH or direct path).
resolve_start_argv :: proc(
	m: ^Manager,
	e: ^Entry,
	arena: mem.Allocator,
) -> ([]string, platform.Err) {
	if override_argv := clone_override_argv(m, e.id, arena); len(override_argv) > 0 {
		if !platform.binary_available(override_argv[0]) {
			return nil, platform.Wrapped{
				kind = .NotFound,
				msg = strings.concatenate(
					{
						"configured language server command for \"",
						e.id,
						"\" is not installed or not executable: ",
						override_argv[0],
					},
					arena,
				),
			}
		}
		return override_argv, nil
	}
	if err := run_check_runtime(m.reg, e, m.root, arena); err != nil {
		return nil, err
	}
	return resolve_argv(m.reg, e, arena)
}

// manager_client_for_file returns the running server whose entry covers
// the file's extension (highest priority first). It starts nothing.
manager_client_for_file :: proc(m: ^Manager, path: string) -> (^lsp.Client, bool) {
	ext := path_extension(path)
	sync.mutex_lock(&m.mu)
	best: ^Server = nil
	for _, s in m.servers {
		if server_alive(s) && entry_matches_extension(s.entry, ext) {
			if best == nil || s.entry.priority > best.entry.priority {
				best = s
			}
		}
	}
	client: ^lsp.Client = nil
	if best != nil {
		last_use_note(m, best.language_id, platform.clock_now(m.clock))
		best.inflight += 1 // hand-out pin; dropped by manager_release
		client = best.client
	}
	sync.mutex_unlock(&m.mu)
	return client, client != nil
}

// manager_running_clients snapshots the running servers as (language id,
// client) pairs. It starts nothing; the result is an owned dynamic array
// carrying `a` (the caller deletes it) and the clients stay owned by the
// manager (the same borrow manager_client_for_file hands out — a stop
// racing a caller is the established lifecycle).
manager_running_clients :: proc(m: ^Manager, a := context.allocator) -> [dynamic]Running_Client {
	sync.mutex_lock(&m.mu)
	out := make([dynamic]Running_Client, 0, len(m.servers), a)
	for _, s in m.servers {
		if server_alive(s) {
			s.inflight += 1 // hand-out pin; dropped by manager_release
			append(&out, Running_Client{language_id = s.language_id, client = s.client})
		}
	}
	sync.mutex_unlock(&m.mu)
	return out
}

// manager_release drops one client hand-out (from manager_ensure,
// manager_client_for_file, or manager_running_clients). Keyed by the
// client pointer, so a restart that already swapped the language's
// server decrements the right — possibly retired — one.
manager_release :: proc(m: ^Manager, client: ^lsp.Client) {
	if client == nil {
		return
	}
	sync.mutex_lock(&m.mu)
	if s, found := server_holding_client_locked(m, client); found {
		s.inflight -= 1
		last_use_note(m, s.language_id, platform.clock_now(m.clock))
	}
	sync.mutex_unlock(&m.mu)
	manager_sweep_retiring(m)
}

@(private)
server_holding_client_locked :: proc(m: ^Manager, client: ^lsp.Client) -> (^Server, bool) {
	for _, s in m.servers {
		if s.client == client {
			return s, true
		}
	}
	for s in m.retiring {
		if s.client == client {
			return s, true
		}
	}
	return nil, false
}

// manager_sweep_retiring destroys retired servers whose last hand-out has
// returned. Every retire path and manager_release call it, so a server is
// never freed while a caller still holds its client. The optional token is
// the cancellation checkpoint of the stop path: each destroy skips its
// graceful waits when the token is already fired.
manager_sweep_retiring :: proc(m: ^Manager, token: ^platform.Cancel_Token = nil) {
	victims := make([dynamic]^Server, 0, len(m.retiring), context.temp_allocator)
	defer delete(victims)
	sync.mutex_lock(&m.mu)
	for i := 0; i < len(m.retiring); {
		if m.retiring[i].inflight <= 0 {
			append(&victims, m.retiring[i])
			m.retiring[i] = m.retiring[len(m.retiring) - 1]
			pop(&m.retiring)
		} else {
			i += 1
		}
	}
	sync.mutex_unlock(&m.mu)
	for s in victims {
		server_destroy(s, token)
	}
}

// manager_retiring_count surfaces the teardown invariant (servers parked
// for an in-flight hand-out) for tests and status displays.
manager_retiring_count :: proc(m: ^Manager) -> int {
	sync.mutex_lock(&m.mu)
	n := len(m.retiring)
	sync.mutex_unlock(&m.mu)
	return n
}

// manager_start brings one language's server up without taking a client.
// manager_ensure pins the client it hands out; start has no hand-out, so
// the pin drops here — a leaked pin holds inflight above zero forever, and
// the retiring sweep's inflight gate then skips this server on every later
// stop or restart, stranding a live process behind a "stopped"/"restarted"
// answer.
manager_start :: proc(
	m: ^Manager,
	language_id: string,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	client, err := manager_ensure(m, language_id, arena, token)
	if err != nil {
		return err
	}
	manager_release(m, client)
	return nil
}

// manager_stop removes and tears down one server (the stop tool);
// stopping an unknown language is a NotFound.
manager_stop :: proc(m: ^Manager, language_id: string, token: ^platform.Cancel_Token = nil) -> platform.Err {
	sync.mutex_lock(&m.mu)
	if m.is_stopped {
		sync.mutex_unlock(&m.mu)
		return platform.Err(.Terminated)
	}
	s := m.servers[language_id]
	if s == nil {
		sync.mutex_unlock(&m.mu)
		return platform.Err(.NotFound)
	}
	delete_key(&m.servers, language_id)
	append(&m.retiring, s)
	sync.cond_broadcast(&m.cond)
	sync.mutex_unlock(&m.mu)
	manager_sweep_retiring(m, token)
	return nil
}

// manager_restart builds the replacement first, swaps it in, then stops
// the old server — callers never observe a window with no server once
// the swap happened, and a failed build leaves the old one untouched.
manager_restart :: proc(
	m: ^Manager,
	language_id: string,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	e := registry_find(m.reg, language_id)
	if e == nil {
		return platform.Err(.NotFound)
	}
	argv, argv_err := resolve_start_argv(m, e, arena)
	if argv_err != nil {
		return argv_err
	}
	folders := start_workspace(m, e, arena)
	env := build_server_env(m.reg, e, arena)
	fresh, err := m.factory.create(
		m.factory.user, e, argv, env, folders, memory_limit_for(e), m.clock, m.allocator, token,
	)
	if err != nil {
		return err
	}
	sync.mutex_lock(&m.mu)
	// The factory create ran without the mutex and may span seconds; the
	// same hazard start_language guards after its create: a destroy/reset
	// that fired inside the window has drained and deleted m.servers, and
	// inserting would resurrect the deleted map through the wrong
	// allocator and strand the live replacement. The finished server is
	// destroyed instead, outside the mutex, with the manager's cancel
	// token.
	if m.is_stopped {
		cancel := m.cancel
		sync.mutex_unlock(&m.mu)
		server_destroy(fresh, cancel)
		return platform.Err(.Cancelled)
	}
	old := m.servers[fresh.language_id]
	// Delete before insert: assigning onto an existing key replaces only
	// the value, leaving the OLD key bytes stored — and those die with the
	// retired server. Removing the entry first makes the stored key the
	// replacement's own clone (see Manager).
	if old != nil {
		delete_key(&m.servers, fresh.language_id)
	}
	m.servers[fresh.language_id] = fresh
	last_use_note(m, fresh.language_id, platform.clock_now(m.clock))
	if old != nil {
		append(&m.retiring, old)
	}
	sync.cond_broadcast(&m.cond)
	sync.mutex_unlock(&m.mu)
	manager_sweep_retiring(m, token)
	return nil
}

// manager_stop_all tears every server down (daemon shutdown). The
// servers leave the table first so late getters fail fast.
// manager_reset stops every running server WITHOUT shutting the manager
// down — the cold reset behind the argumentless langserver_restart and
// the settings reload. Each language rebuilds its server on its next
// use. The failure cooldowns are cleared too: they are history from the
// old configuration, and a cold reset that still refuses starts for 30
// seconds would defeat its own "rebuild on next use" contract. Returns
// how many servers were stopped.
manager_reset :: proc(m: ^Manager, token: ^platform.Cancel_Token = nil) -> int {
	stopped_count := 0
	for {
		sync.mutex_lock(&m.mu)
		victim: ^Server = nil
		for _, s in m.servers {
			victim = s
			break
		}
		if victim != nil {
			delete_key(&m.servers, victim.language_id)
			append(&m.retiring, victim)
		}
		sync.mutex_unlock(&m.mu)
		if victim == nil {
			break
		}
		stopped_count += 1
		manager_sweep_retiring(m, token)
	}
	sync.mutex_lock(&m.mu)
	old_fail := m.last_fail_ms
	m.last_fail_ms = make(map[string]i64, 4, m.allocator)
	sync.mutex_unlock(&m.mu)
	// The cooldown keys are manager-owned clones (see Manager) — free them
	// with the table, not just the table itself.
	for k in old_fail {
		delete(k, m.allocator)
	}
	delete(old_fail)
	return stopped_count
}

// manager_stop_all is the shutdown path (manager_destroy): it latches the
// is_stopped flag — every later ensure refuses with Terminated — and drains
// the running servers.
manager_stop_all :: proc(m: ^Manager, token: ^platform.Cancel_Token = nil) {
	sync.mutex_lock(&m.mu)
	m.is_stopped = true
	sync.mutex_unlock(&m.mu)
	_ = manager_reset(m, token)
}

// manager_set_allow installs a new language allowlist (status listing and
// eager gating), cloning it into the manager's allocator; the previous
// list is freed after the swap.
manager_set_allow :: proc(m: ^Manager, allow: []string) {
	sync.mutex_lock(&m.mu)
	old := m.allow
	m.allow = clone_strings(allow, m.allocator)
	sync.mutex_unlock(&m.mu)
	free_strings(old, m.allocator)
}

// manager_allow_snapshot clones the allowlist under the mutex onto temp:
// set_allow frees the old slice after a swap, so every reader must walk
// its own copy instead of the live field. manager_allow_configured is the
// bool form for callers that only branch on "an allowlist is set".
manager_allow_snapshot :: proc(m: ^Manager) -> []string {
	return manager_allow_snapshot_on(m, context.temp_allocator)
}

// manager_allow_snapshot_on is the allocator-explicit form for walkers
// that free_all the temp allocator per iteration (the eager thread): a
// snapshot bound to an allocator nobody resets mid-walk.
manager_allow_snapshot_on :: proc(m: ^Manager, a: mem.Allocator) -> []string {
	sync.mutex_lock(&m.mu)
	ids := clone_strings(m.allow, a)
	sync.mutex_unlock(&m.mu)
	return ids
}

manager_allow_configured :: proc(m: ^Manager) -> bool {
	sync.mutex_lock(&m.mu)
	set := len(m.allow) > 0
	sync.mutex_unlock(&m.mu)
	return set
}

// manager_status lists the configured languages (allowlist when set,
// otherwise every non-experimental entry) plus any on-demand running
// extras, each with its running flag. Rows (and their strings) are
// owned by `a`.
manager_status :: proc(m: ^Manager, a := context.allocator) -> []Status_Row {
	// ids hold views of registry/server-owned strings (stable); the rows
	// clone them into the caller's allocator.
	ids := make([dynamic]string, 0, 16, context.temp_allocator)
	seen := make(map[string]bool, 16, context.temp_allocator)
	defer delete(seen)
	allow := manager_allow_snapshot(m)
	if len(allow) > 0 {
		for id in allow {
			if !seen[id] && registry_find(m.reg, id) != nil {
				seen[id] = true
				append(&ids, id)
			}
		}
	} else {
		for e in registry_non_experimental(m.reg, context.temp_allocator) {
			if !seen[e.id] {
				seen[e.id] = true
				append(&ids, e.id)
			}
		}
	}
	sync.mutex_lock(&m.mu)
	for _, s in m.servers {
		if !seen[s.language_id] {
			seen[s.language_id] = true
			append(&ids, s.language_id)
		}
	}
	rows := make([dynamic]Status_Row, 0, len(ids), a)
	for id in ids {
		s := m.servers[id]
		row := Status_Row{id = strings.clone(id, a), running = s != nil && server_alive(s)}
		if s != nil {
			row.folders = len(s.folders)
			if len(s.folders) > 0 {
				row.root = strings.clone(s.folders[0], a)
			}
		}
		append(&rows, row)
	}
	sync.mutex_unlock(&m.mu)
	return rows[:]
}

// manager_config_note returns the entry's degradation note when the
// capability it describes is unconfigured: none of its config_note_files
// exists at the server's primary workspace folder (the first announced
// folder of a running server; the manager root otherwise) AND none of
// its config_note_option_keys is present in the language's user
// initialization options. "" when the entry carries no note or the
// capability is configured. The note is cloned into `a`; the joined
// probe paths and the options parse live on the temp allocator.
manager_config_note :: proc(m: ^Manager, id: string, first_folder: string, a := context.allocator) -> string {
	e := registry_find(m.reg, id)
	if e == nil || e.config_note == "" {
		return ""
	}
	if len(e.config_note_files) > 0 {
		base := first_folder
		if base == "" {
			base = m.root
		}
		if base != "" {
			for f in e.config_note_files {
				path, jerr := filepath.join({base, f}, context.temp_allocator)
				// A decision on a path checks the error: an unbuildable
				// path means the file's presence cannot be established,
				// so this candidate is skipped rather than silently
				// read as "file absent".
				if jerr != nil {
					continue
				}
				if path != "" && os.exists(path) {
					return ""
				}
			}
		}
	}
	if len(e.config_note_option_keys) > 0 {
		user_json := clone_options_json(m, id, context.temp_allocator)
		if user_json != "" {
			user, perr := json.parse_string(user_json, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
			if perr == nil {
				for k in e.config_note_option_keys {
					if _, ok := jsonutil.obj_get(user, k); ok {
						return ""
					}
				}
			}
		}
	}
	return strings.clone(e.config_note, a)
}

// --- eager start ---------------------------------------------------------------

// manager_start_eager starts the allowed languages: the first few
// synchronously (bounded wait), the remainder on a background thread
// joined at destroy. No-op when eager mode is off.
manager_start_eager :: proc(m: ^Manager, token: ^platform.Cancel_Token = nil) {
	if !m.eager {
		return
	}
	ids := manager_allow_snapshot(m)
	if len(ids) == 0 {
		return
	}
	arena := context.temp_allocator
	sync_count := 0
	for id in ids {
		if sync_count >= MANAGER_EAGER_SYNC {
			break
		}
		// The running pre-check shares the mutex with the server map
		// (an already-running language must not consume the sync budget);
		// manager_start re-checks under the same lock anyway.
		sync.mutex_lock(&m.mu)
		running := m.servers[id] != nil
		sync.mutex_unlock(&m.mu)
		if running {
			continue
		}
		err := manager_start(m, id, arena, token)
		if err == nil {
			sync_count += 1
		}
	}
	if sync_count < MANAGER_EAGER_SYNC {
		return // nothing left to background
	}
	sync.mutex_lock(&m.mu)
	if m.eager_thread != nil || m.is_stopped {
		sync.mutex_unlock(&m.mu)
		return
	}
	m.eager_args = {m = m}
	saved_allocator := context.allocator
	defer context.allocator = saved_allocator
	context.allocator = m.allocator // the thread handle outlives this call's frame
	m.eager_thread = thread.create_and_start_with_data(
		&m.eager_args, eager_thread_main, self_cleanup = false, name = "langserver-eager",
	)
	sync.mutex_unlock(&m.mu)
}

Eager_Args :: struct {
	m: ^Manager,
}

manager_stop_eager :: proc(m: ^Manager) {
	sync.mutex_lock(&m.mu)
	t := m.eager_thread
	m.eager_thread = nil
	sync.mutex_unlock(&m.mu)
	if t != nil {
		thread.join(t)
		free(t, m.allocator)
	}
}

eager_thread_main :: proc(data: rawptr) {
	ea := cast(^Eager_Args)data
	m := ea.m
	// The thread walks its own snapshot: a later reload's set_allow frees
	// the old slice, and this thread is joined only at destroy. The
	// snapshot lives on the manager's allocator — the per-start
	// free_all(temp) below would strip a temp-backed slice's bytes out
	// from under the loop's next iteration.
	ids := manager_allow_snapshot_on(m, m.allocator)
	defer free_strings(ids, m.allocator)
	arena := context.temp_allocator
	for id in ids {
		sync.mutex_lock(&m.mu)
		stopped := m.is_stopped
		cancel := m.cancel
		running := m.servers[id] != nil
		sync.mutex_unlock(&m.mu)
		if stopped || running {
			continue
		}
		// The cancel token (set by manager_destroy) rides every start, so
		// an in-flight spawn+handshake aborts at its checkpoints instead
		// of running to its timeout while destroy waits on the join.
		_ = manager_start(m, id, arena, cancel)
		// Per-start temp reset: the spawn/handshake scratch must not
		// accumulate for the thread's life (the pass is bounded, but the
		// thread lives until destroy).
		free_all(context.temp_allocator)
	}
}

// --- idle monitor ------------------------------------------------------------

manager_start_idle :: proc(m: ^Manager) {
	sync.mutex_lock(&m.mu)
	if m.idle_thread != nil || m.is_stopped {
		sync.mutex_unlock(&m.mu)
		return
	}
	m.idle_args = {m = m}
	saved_allocator := context.allocator
	defer context.allocator = saved_allocator
	context.allocator = m.allocator // the thread handle outlives this call's frame
	m.idle_thread = thread.create_and_start_with_data(
		&m.idle_args, idle_thread_main, self_cleanup = false, name = "langserver-idle",
	)
	sync.mutex_unlock(&m.mu)
}

// The monitor exits on the is_stopped latch itself (no dedicated stop flag):
// stop_idle only wakes the parked slice with a broadcast. Callers latch
// is_stopped first — manager_destroy does so at entry, before this join.
manager_stop_idle :: proc(m: ^Manager) {
	sync.mutex_lock(&m.mu)
	t := m.idle_thread
	m.idle_thread = nil
	if t != nil {
		sync.cond_broadcast(&m.cond)
	}
	sync.mutex_unlock(&m.mu)
	if t != nil {
		thread.join(t)
		free(t, m.allocator)
	}
}

Idle_Args :: struct {
	m: ^Manager,
}

// The monitor parks in short real-time cond slices (not clock_wait):
// a stop must wake it by broadcast — a virtual clock parked in
// clock_wait only releases on an advance nobody will make during
// teardown. Tick arithmetic still reads the injected clock, so virtual
// time drives the reaping cadence in tests.
idle_thread_main :: proc(data: rawptr) {
	ia := cast(^Idle_Args)data
	m := ia.m
	last_tick := platform.clock_now(m.clock)
	for {
		sync.mutex_lock(&m.mu)
		if m.is_stopped {
			sync.mutex_unlock(&m.mu)
			break
		}
		cancel := m.cancel
		// Real-time cond slices by design: tick
		// arithmetic reads the injected clock; the parks bound stop
		// latency only.
		sync.cond_wait_with_timeout(
			&m.cond, &m.mu, time.Duration(MANAGER_IDLE_SLICE_MS * 1_000_000),
		)
		sync.mutex_unlock(&m.mu)
		now := platform.clock_now(m.clock)
		if now - last_tick < m.idle_interval_ms {
			continue
		}
		last_tick = now
		manager_reap_idle(m, now, cancel)
		// Per-reap temp reset (the dispatch threads' idiom): server
		// teardown scratch — shutdown request bodies, pid text, ps output —
		// must not accumulate for this thread's life.
		free_all(context.temp_allocator)
	}
}

// manager_reap_idle stops servers whose last use is older than the idle
// timeout. Removal happens under the lock; teardown outside it. The token
// is the reaper's cancellation checkpoint: a destroy already in flight
// shortens each teardown at its next graceful-wait boundary.
manager_reap_idle :: proc(m: ^Manager, now: i64, token: ^platform.Cancel_Token = nil) {
	for {
		sync.mutex_lock(&m.mu)
		victim: ^Server = nil
		for _, s in m.servers {
			last, used := m.last_use_ms[s.language_id]
			if used && now - last >= m.idle_timeout_ms {
				victim = s
				break
			}
		}
		if victim != nil {
			delete_key(&m.servers, victim.language_id)
			append(&m.retiring, victim)
			sync.cond_broadcast(&m.cond)
		}
		sync.mutex_unlock(&m.mu)
		if victim == nil {
			return
		}
		manager_sweep_retiring(m, token)
	}
}

// --- shared helpers ----------------------------------------------------------

// server_alive reports whether the server can still serve requests: a
// spawned process must not have exited, and the connection must be open
// (in-process fakes die by connection close).
server_alive :: proc(s: ^Server) -> bool {
	if s.child != nil {
		gone, _ := lsproc.lsproc_exited(s.child)
		if gone {
			return false
		}
	}
	if s.conn != nil && jsonrpc.conn_is_closed(s.conn) {
		return false
	}
	return true
}

// server_destroy tears one server down in the staged order: wire
// shutdown, process stop and destroy (closing the pipes), then the
// connection close (stopping the outbound writer — safe to stop without
// joining here: the kill above already turned any write wedged in the
// full stdin pipe into EPIPE, so conn_destroy's join cannot hang), reader
// and stderr joins, the client, the connection, and the node itself. Safe
// for fake servers (proc and threads nil) and for half-built ones (the
// factory's failure path destroys before the client exists). When the
// child refuses to die, everything from the pipes on is abandoned to
// process exit instead of joined — an unkillable child would hang the
// joins (and, at shutdown, the whole daemon) forever.
server_destroy :: proc(s: ^Server, token: ^platform.Cancel_Token = nil) {
	if s.child != nil {
		// Cancellation shortens the ladder: a fired token skips the LSP
		// shutdown round trip (a 15 s request budget) and hands lsproc_stop
		// the token, whose staged graces each exit at the next check.
		cancelled := false
		if token != nil {
			if _, fired := platform.token_check(token); fired {
				cancelled = true
			}
		}
		if s.client != nil && !cancelled {
			// The token also covers a cancel firing mid-round-trip: the
			// request's parked wait exits at its next slice.
			_, _, _ = lsp.client_shutdown(s.client, context.temp_allocator, token)
		}
		_ = lsproc.lsproc_stop(s.child, MANAGER_STOP_GRACE_MS, token)
		if !lsproc.lsproc_destroy(s.child) { // closes the pipes → reader hits EOF
			util.log_warning(strings.concatenate({
				"langserver: process for ", s.language_id,
				" refused to die; abandoning server teardown to process exit",
			}, context.temp_allocator))
			return
		}
	}
	if s.conn != nil {
		jsonrpc.conn_close(s.conn)
	}
	if s.reader != nil {
		thread.join(s.reader)
		free(s.reader, s.allocator)
	}
	if s.stderr_pump != nil {
		thread.join(s.stderr_pump)
		free(s.stderr_pump, s.allocator)
	}
	if s.client != nil {
		lsp.client_destroy(s.client)
		free(s.client, s.allocator)
	}
	if s.conn != nil {
		jsonrpc.conn_destroy(s.conn)
		free(s.conn, s.allocator)
	}
	free_strings(s.folders, s.allocator)
	delete(s.language_id, s.allocator)
	free(s, s.allocator)
}

// run_check_runtime dispatches to the entry's check or the default.
run_check_runtime :: proc(reg: ^Registry, e: ^Entry, root: string, arena: mem.Allocator) -> platform.Err {
	if e.check_runtime != nil {
		return e.check_runtime(reg, root, arena)
	}
	return default_check_runtime(e, arena)
}

// resolve_argv prefers the entry's dynamic resolution and falls back to
// the static command+args (argv views entry-owned strings — the registry
// outlives every server).
resolve_argv :: proc(reg: ^Registry, e: ^Entry, arena: mem.Allocator) -> ([]string, platform.Err) {
	if e.resolve_command != nil {
		argv, err := e.resolve_command(reg, arena)
		if err != nil {
			return nil, err
		}
		if len(argv) > 0 {
			return argv, nil
		}
	}
	if e.command == "" {
		return nil, platform.Err(.NotFound)
	}
	out := make([]string, 1 + len(e.args), arena)
	out[0] = e.command
	for arg, i in e.args {
		out[1 + i] = arg
	}
	return out, nil
}

// memory_limit_for maps the entry's limit to the process containment
// value: positive passes through, zero takes the default, negative
// disables containment.
memory_limit_for :: proc(e: ^Entry) -> int {
	if e.memory_limit_mb > 0 {
		return e.memory_limit_mb
	}
	if e.memory_limit_mb < 0 {
		return 0
	}
	return MANAGER_MEMORY_LIMIT_MB
}

// build_server_env assembles the server environment: the current
// environment, the entry's overrides, and the resolved extra PATH
// directories prepended (deduplicated against the existing PATH).
build_server_env :: proc(reg: ^Registry, e: ^Entry, arena: mem.Allocator) -> []string {
	base_in, err := os.environ(arena)
	env := make([dynamic]string, 0, len(base_in) + len(e.env) + 2, arena)
	if err == nil {
		append(&env, ..base_in)
	}

	// PATH handling: prepend extra dirs not already present.
	path_value := ""
	path_idx := -1
	for v, i in env {
		if env_key_is(v, "PATH") {
			path_value = env_value_of(v, "PATH")
			path_idx = i
			break
		}
	}
	if e.extra_path_dirs != nil {
		dirs := e.extra_path_dirs(reg, arena)
		if len(dirs) > 0 {
			parts := make([dynamic]string, 0, len(dirs) + 1, arena)
			for d in dirs {
				if !path_contains_dir(path_value, d) {
					append(&parts, d)
				}
			}
			if len(parts) > 0 {
				if path_value != "" {
					append(&parts, path_value)
				}
				joined := strings.join(parts[:], platform.PATH_LIST_SEP, arena) or_else ""
				if joined != "" {
					combined := strings.concatenate({"PATH=", joined}, arena)
					if path_idx >= 0 {
						env[path_idx] = combined
					} else {
						append(&env, combined)
					}
				}
			}
		}
	}
	for v in e.env {
		apply_env_var(&env, v, arena)
	}
	return env[:]
}

// apply_env_var merges one variable into the assembled environment,
// replacing an existing key in place or appending when absent.
apply_env_var :: proc(env: ^[dynamic]string, v: Env_Var, arena: mem.Allocator) {
	for i in 0..<len(env^) {
		if env_key_is(env^[i], v.key) {
			env^[i] = strings.concatenate({v.key, "=", v.value}, arena)
			return
		}
	}
	append(env, strings.concatenate({v.key, "=", v.value}, arena))
}

env_key_is :: proc(entry_var: string, key: string) -> bool {
	if len(entry_var) <= len(key) {
		return false
	}
	return strings.equal_fold(entry_var[:len(key)], key) && entry_var[len(key)] == '='
}

env_value_of :: proc(entry_var: string, key: string) -> string {
	if !env_key_is(entry_var, key) {
		return ""
	}
	return entry_var[len(key) + 1:]
}

	path_contains_dir :: proc(path_value: string, dir: string) -> bool {
	if path_value == "" || dir == "" {
		return false
	}
	for part in strings.split(path_value, platform.PATH_LIST_SEP, context.temp_allocator) {
		// Directory identity carries the filesystem's case sensitivity —
		// PATH entries fold case on Windows, stay distinct on Linux.
		if platform.path_equal(part, dir) {
			return true
		}
	}
	return false
}
