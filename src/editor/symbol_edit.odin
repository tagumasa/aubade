// Symbol-level editing on top of the snapshot buffer: body replacement,
// insert before/after a definition, docstring insert/delete/replace, and
// the cross-file symbol move. Positions come from the caller's freshly
// parsed outline (the Symbol ranges, UTF-16 line/col like the wire); the
// caller also supplies the language names it resolved from the file
// extensions, keeping this package free of the grammar registry.
//
// Odin proc literals do not capture, so multi-step transactions use
// Edit_Job: a plain procedure paired with a `user` pointer to a
// caller-stack job struct — the moral equivalent of a closure over the
// edit scope.
package editor

import "core:strings"
import "core:sync"
import "src:symbol"
import "src:util"

// Move_Mode is symbol_move's mode vocabulary; MOVE_MODE_NAMES is its one
// spelling table (the schema enum hints derive from it).
Move_Mode :: enum {
	Move,
	Copy,
}

MOVE_MODE_NAMES :: []string{"move", "copy"}

// move_mode_parse resolves the mode param: "" is the move default, every
// other spelling must be a table name (the from_string half of the single
// declaration).
move_mode_parse :: proc(param: string) -> (mode: Move_Mode, err: Editor_Err, msg: string) {
	if param == "" {
		return .Move, .None, ""
	}
	names := MOVE_MODE_NAMES
	for m in Move_Mode {
		if names[cast(int)m] == param {
			return m, .None, ""
		}
	}
	return .Move, .Invalid, strings.concatenate({
		"invalid mode \"", param, "\": must be \"",
		names[cast(int)(Move_Mode.Move)], "\" or \"", names[cast(int)(Move_Mode.Copy)], "\"",
	}, context.temp_allocator)
}

// move_mode_string renders one mode spelling from the same table.
move_mode_string :: proc(m: Move_Mode) -> string {
	names := MOVE_MODE_NAMES
	return names[cast(int)m]
}

Edit_Job :: struct {
	apply:   proc(ef: ^Edited_File, user: rawptr) -> (err: Editor_Err, msg: string),
	user: rawptr,
}

// editor_edit_ctx is the multi-step edit transaction: it takes the file
// lock, snapshots the buffer, runs the job against the edited file, and
// on any error rolls the buffer back (single-action callers use
// edit_file).
editor_edit_ctx :: proc(e: ^Editor, rel_path: string, job: Edit_Job) -> (err: Editor_Err, msg: string) {
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

	buf, aerr, amsg := buffer_acquire(e, rel_path)
	if aerr != .None {
		return aerr, amsg
	}
	snapshot := strings.clone(buf.contents, e.allocator)
	defer delete(snapshot, e.allocator)

	ef := Edited_File{buf = buf}
	if ferr, fmsg := job.apply(&ef, job.user); ferr != .None {
		rollback_buffer(e, buf, rel_path, snapshot)
		return ferr, fmsg
	}

	if serr, smmsg := save(e, rel_path, buf.contents, buf.has_utf8_bom); serr != .None {
		rollback_buffer(e, buf, rel_path, snapshot)
		return serr, strings.concatenate({"save edited file: ", smmsg}, context.temp_allocator)
	}
	// The written bytes have no observed stat: drop the reload gate's record
	// so the next read re-probes with a pre-read stat (the single-action
	// edit path does the same; keeping the pre-edit record could pair a
	// future probe with bytes that were never on disk).
	buf.has_disk_stat = false
	buffer_notify_change(e, rel_path, buf.contents)
	return .None, ""
}

// symbol_positions extracts the body range positions (0-based line,
// UTF-16 col) from a symbol whose outline filled its range.
symbol_positions :: proc(s: ^symbol.Symbol) -> (start_line, start_col, end_line, end_col: int, ok: bool) {
	if s == nil || s.range == nil {
		return 0, 0, 0, 0, false
	}
	return int(s.range.start.line), int(s.range.start.character),
		int(s.range.end.line), int(s.range.end.character), true
}

// separated_by_empty_line reports whether a definition of this kind is
// typically separated from its neighbours by an empty line.
separated_by_empty_line :: proc(s: ^symbol.Symbol) -> bool {
	if s == nil {
		return false
	}
	#partial switch s.kind {
	case .Function, .Method, .Class, .Interface, .Struct:
		return true
	}
	return false
}

count_leading_newlines :: proc(text: string) -> int {
	count := 0
	for c in text {
		if c == '\n' {
			count += 1
		} else if c == '\r' {
			continue
		} else {
			break
		}
	}
	return count
}

count_trailing_newlines :: proc(text: string) -> int {
	count := 0
	for i := len(text) - 1; i >= 0; i -= 1 {
		c := text[i]
		if c == '\n' {
			count += 1
		} else if c == '\r' {
			continue
		} else {
			break
		}
	}
	return count
}

// ---------------------------------------------------------------------------
// replace_body
// ---------------------------------------------------------------------------

Replace_Body_Job :: struct {
	sl, sc, el, ec: int,
	body:           string, // normalised, borrowed for the call's duration
}

replace_body_step :: proc(ef: ^Edited_File, user: rawptr) -> (err: Editor_Err, msg: string) {
	job := cast(^Replace_Body_Job)user
	body := job.body
	// Re-indent continuation lines under the definition's indent when the
	// body starts indented and spans lines. The buffer is already
	// LF-normalised (the read side folds pairs; split_lf strips any \r an
	// LSP-supplied edit reintroduced), so the lines come straight off it —
	// no full-file re-encode per replace.
	if job.sc > 0 && strings.contains(body, "\n") {
		file_lines := split_lf(ef.buf.contents, context.temp_allocator)
		if job.sl < len(file_lines) {
			line_content := file_lines[job.sl]
			byte_col := util.utf16_col_to_byte_offset(line_content, job.sc)
			if byte_col > 0 {
				indent := line_content[:byte_col]
				body_lines := split_lf(body, context.temp_allocator)
				for i := 1; i < len(body_lines); i += 1 {
					if !strings.has_prefix(body_lines[i], indent) {
						body_lines[i] = strings.concatenate({indent, body_lines[i]}, context.temp_allocator)
					}
				}
				body, _ = strings.join(body_lines[:], "\n", context.temp_allocator)
			}
		}
	}
	if derr, dmsg := edited_delete_between(ef, job.sl, job.sc, job.el, job.ec); derr != .None {
		return derr, strings.concatenate({"delete old body: ", dmsg}, context.temp_allocator)
	}
	if ierr, imsg := edited_insert_text(ef, job.sl, job.sc, body); ierr != .None {
		return ierr, strings.concatenate({"insert new body: ", imsg}, context.temp_allocator)
	}
	return .None, ""
}

// editor_symbol_replace_body swaps the symbol's full range content for
// `body`.
editor_symbol_replace_body :: proc(e: ^Editor, rel_path: string, s: ^symbol.Symbol, body: string) -> (err: Editor_Err, msg: string) {
	sl, sc, el, ec, ok := symbol_positions(s)
	if !ok {
		return .Position, "body start position not available"
	}
	trimmed := strings.trim_space(body)
	normalised := normalise_line_endings(e, trimmed, context.temp_allocator)
	job := Replace_Body_Job{sl = sl, sc = sc, el = el, ec = ec, body = normalised}
	return editor_edit_ctx(e, rel_path, {apply = replace_body_step, user = &job})
}

// ---------------------------------------------------------------------------
// insert before/after
// ---------------------------------------------------------------------------

// editor_symbol_insert_after appends `body` directly below the symbol,
// normalising surrounding empty lines.
editor_symbol_insert_after :: proc(e: ^Editor, rel_path: string, s: ^symbol.Symbol, body: string) -> (err: Editor_Err, msg: string) {
	if s.has_body && s.body == s.name {
		return .Invalid_Symbol, strings.concatenate({
			"cannot insert after this symbol (not a function, class or method): ",
			s.name, ". Consider using insert_before_symbol instead",
		}, context.temp_allocator)
	}

	_, _, el, _, ok := symbol_positions(s)
	if !ok {
		return .Position, "body end position not available"
	}

	text := body
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"}, context.temp_allocator)
	}
	original_leading := count_leading_newlines(text)
	text = strings.trim_left(text, "\r\n")
	min_empty := 0
	if separated_by_empty_line(s) {
		min_empty = 1
	}
	num_leading := max(min_empty, original_leading)
	if num_leading > 0 {
		prefix := strings.repeat("\n", num_leading, context.temp_allocator)
		text = strings.concatenate({prefix, text}, context.temp_allocator)
	}
	text = strings.trim_right(text, "\r\n")
	text = strings.concatenate({text, "\n"}, context.temp_allocator)

	action := Edit_Action{kind = .Insert, start_line = el + 1, start_col = 0, text = text}
	return edit_file(e, rel_path, action)
}

// editor_symbol_insert_before prepends `body` directly above the symbol.
editor_symbol_insert_before :: proc(e: ^Editor, rel_path: string, s: ^symbol.Symbol, body: string) -> (err: Editor_Err, msg: string) {
	sl, _, _, _, ok := symbol_positions(s)
	if !ok {
		return .Position, "body start position not available"
	}

	original_trailing := count_trailing_newlines(body) - 1
	if original_trailing < 0 {
		original_trailing = 0
	}
	text := strings.trim_right(body, " \t\r\n")
	text = strings.concatenate({text, "\n"}, context.temp_allocator)

	min_trailing := 0
	if separated_by_empty_line(s) {
		min_trailing = 1
	}
	num_trailing := max(min_trailing, original_trailing)
	if num_trailing > 0 {
		suffix := strings.repeat("\n", num_trailing, context.temp_allocator)
		text = strings.concatenate({text, suffix}, context.temp_allocator)
	}

	action := Edit_Action{kind = .Insert, start_line = sl, start_col = 0, text = text}
	return edit_file(e, rel_path, action)
}

// ---------------------------------------------------------------------------
// docstring ops
// ---------------------------------------------------------------------------

// find_comment_line resolves the first line of the docstring/comment
// block above the definition line (the definition line itself when
// nothing sits above).
find_comment_line :: proc(contents: string, def_line: int, lang: string) -> int {
	pattern, _ := comment_pattern_for_language(lang)
	return find_comment_start(contents, def_line, pattern)
}

Delete_Docstring_Job :: struct {
	sl:  int,
	lang: string,
}

delete_docstring_step :: proc(ef: ^Edited_File, user: rawptr) -> (err: Editor_Err, msg: string) {
	job := cast(^Delete_Docstring_Job)user
	comment_line := find_comment_line(ef.buf.contents, job.sl, job.lang)
	if comment_line >= job.sl {
		return .None, ""
	}
	return edited_delete_between(ef, comment_line, 0, job.sl, 0)
}

// editor_symbol_insert_docstring inserts a comment block immediately
// above the definition line.
// The docstring tools write comment text verbatim, so text carrying no
// comment marker would not be a comment at all once written — the shared
// refusal message.
DOCSTRING_UNMARKED_MSG :: "comment text is written verbatim and carries no comment marker for this file (include the language's marker, e.g. // or #)"

editor_symbol_insert_docstring :: proc(e: ^Editor, rel_path: string, s: ^symbol.Symbol, lang: string, comment: string) -> (err: Editor_Err, msg: string) {
	sl, _, _, _, ok := symbol_positions(s)
	if !ok {
		return .Position, "body start position not available"
	}
	if strings.trim_space(comment) == "" {
		return .None, ""
	}
	if !comment_text_marked(comment, lang) {
		return .Invalid, DOCSTRING_UNMARKED_MSG
	}
	text := comment
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"}, context.temp_allocator)
	}
	action := Edit_Action{kind = .Insert, start_line = sl, start_col = 0, text = text}
	return edit_file(e, rel_path, action)
}

// editor_symbol_delete_docstring removes any docstring or comment block
// immediately preceding the definition, leaving the symbol intact.
editor_symbol_delete_docstring :: proc(e: ^Editor, rel_path: string, s: ^symbol.Symbol, lang: string) -> (err: Editor_Err, msg: string) {
	sl, _, _, _, ok := symbol_positions(s)
	if !ok {
		return .Position, "body start position not available"
	}
	job := Delete_Docstring_Job{sl = sl, lang = lang}
	return editor_edit_ctx(e, rel_path, {apply = delete_docstring_step, user = &job})
}

Replace_Docstring_Job :: struct {
	sl:     int,
	lang:   string,
	comment: string,
}

replace_docstring_step :: proc(ef: ^Edited_File, user: rawptr) -> (err: Editor_Err, msg: string) {
	job := cast(^Replace_Docstring_Job)user
	comment_line := find_comment_line(ef.buf.contents, job.sl, job.lang)
	if comment_line < job.sl {
		if derr, dmsg := edited_delete_between(ef, comment_line, 0, job.sl, 0); derr != .None {
			return derr, dmsg
		}
	} else {
		comment_line = job.sl
	}
	if strings.trim_space(job.comment) == "" {
		return .None, ""
	}
	text := job.comment
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"}, context.temp_allocator)
	}
	return edited_insert_text(ef, comment_line, 0, text)
}

// editor_symbol_replace_docstring swaps the preceding comment block for
// `comment` (an empty comment only deletes).
editor_symbol_replace_docstring :: proc(e: ^Editor, rel_path: string, s: ^symbol.Symbol, lang: string, comment: string) -> (err: Editor_Err, msg: string) {
	sl, _, _, _, ok := symbol_positions(s)
	if !ok {
		return .Position, "body start position not available"
	}
	if strings.trim_space(comment) != "" && !comment_text_marked(comment, lang) {
		return .Invalid, DOCSTRING_UNMARKED_MSG
	}
	job := Replace_Docstring_Job{sl = sl, lang = lang, comment = comment}
	return editor_edit_ctx(e, rel_path, {apply = replace_docstring_step, user = &job})
}

// ---------------------------------------------------------------------------
// Symbol move
// ---------------------------------------------------------------------------

Delete_Symbol_Job :: struct {
	start_line, start_col: int,
	end_line, end_col:     int,
	with_comments:         bool,
	lang:                  string,
}

delete_symbol_step :: proc(ef: ^Edited_File, user: rawptr) -> (err: Editor_Err, msg: string) {
	job := cast(^Delete_Symbol_Job)user
	start_line, start_col := job.start_line, job.start_col
	if job.with_comments {
		comment_line := find_comment_line(ef.buf.contents, start_line, job.lang)
		if comment_line < start_line {
			start_line, start_col = comment_line, 0
		}
	}
	if derr, dmsg := edited_delete_between(ef, start_line, start_col, job.end_line, job.end_col); derr != .None {
		return derr, dmsg
	}
	if start_col != 0 {
		// A partial-line delete (an indented member) has no whole-line
		// seam to collapse.
		return .None, ""
	}
	// The plain form stops at the body's end column, leaving the body's
	// trailing newline behind as one blank line of residue; the comment
	// form deletes whole lines and contributes none.
	residue := 1
	if job.with_comments {
		residue = 0
	}
	return edited_collapse_blank_run(ef, start_line, residue)
}

// editor_symbol_delete removes the symbol's definition; with_comments also
// removes an immediately preceding docstring/comment block. The plain form
// deletes the exact body range (the trailing newline stays),
// the comment form deletes whole lines through the line after the body.
editor_symbol_delete :: proc(e: ^Editor, rel_path: string, s: ^symbol.Symbol, include_comments: bool, lang: string) -> (err: Editor_Err, msg: string) {
	sl, sc, el, ec, ok := symbol_positions(s)
	if !ok {
		return .Position, "body positions not available"
	}
	if include_comments {
		// Line-granular: [comment_line, body_end+1) so the removed block
		// leaves no dangling blank line.
		el, ec = el+1, 0
	}
	job := Delete_Symbol_Job{
		start_line = sl, start_col = sc,
		end_line = el, end_col = ec,
		with_comments = include_comments,
		lang = lang,
	}
	return editor_edit_ctx(e, rel_path, {apply = delete_symbol_step, user = &job})
}

detect_line_indent :: proc(content: string, line_num: int) -> string {
	lines := split_lf(content, context.temp_allocator)
	if line_num < 0 || line_num >= len(lines) {
		return ""
	}
	line := lines[line_num]
	for i := 0; i < len(line); i += 1 {
		if line[i] != ' ' && line[i] != '\t' {
			return line[:i]
		}
	}
	return line
}

is_same_family :: proc(a, b: string) -> bool {
	pa, _ := language_props(a)
	pb, _ := language_props(b)
	return pa.family == pb.family
}

// extract_with_comments pulls the symbol lines plus any preceding comment
// block, validating the extracted block's brace balance (indentation for
// syntax-significant languages).
extract_with_comments :: proc(
	contents: string,
	s: ^symbol.Symbol,
	lang: string,
) -> (extracted: string, comment_start: int, body_end_line: int, err: Editor_Err, msg: string) {
	sl, _, el, _, ok := symbol_positions(s)
	if !ok {
		return "", 0, 0, .Position, "body start position not available"
	}
	comment_start = find_comment_line(contents, sl, lang)
	block, xerr, xmsg := extract_lines(contents, comment_start, el)
	if xerr != .None {
		return "", 0, 0, xerr, xmsg
	}
	if berr, bmsg := validate_brace_balance(block, lang); berr != .None {
		return "", 0, 0, berr, bmsg
	}
	return block, comment_start, el, .None, ""
}

Move_Job :: struct {
	insert_first: bool,
	insert_line:   int,
	text:          string,
	del_start:     int,
	del_end:       int,
}

move_step :: proc(ef: ^Edited_File, user: rawptr) -> (err: Editor_Err, msg: string) {
	job := cast(^Move_Job)user
	if job.insert_first {
		if ierr, imsg := edited_insert_text(ef, job.insert_line, 0, job.text); ierr != .None {
			return ierr, strings.concatenate({"insert at target: ", imsg}, context.temp_allocator)
		}
		if derr, dmsg := edited_delete_between(ef, job.del_start, 0, job.del_end, 0); derr != .None {
			return derr, strings.concatenate({"delete from source: ", dmsg}, context.temp_allocator)
		}
		return edited_collapse_blank_run(ef, job.del_start, 0)
	}
	if derr, dmsg := edited_delete_between(ef, job.del_start, 0, job.del_end, 0); derr != .None {
		return derr, strings.concatenate({"delete from source: ", dmsg}, context.temp_allocator)
	}
	if cerr, cmsg := edited_collapse_blank_run(ef, job.del_start, 0); cerr != .None {
		return cerr, strings.concatenate({"collapse source seam: ", cmsg}, context.temp_allocator)
	}
	return edited_insert_text(ef, job.insert_line, 0, job.text)
}

// Collapse_Job runs the seam collapse as its own edit job — the
// cross-file move deletes through the generic action path and needs the
// same blank-run cleanup on the vacated source site afterwards.
Collapse_Job :: struct {
	seam:    int,
	residue: int,
}

collapse_seam_step :: proc(ef: ^Edited_File, user: rawptr) -> (err: Editor_Err, msg: string) {
	job := cast(^Collapse_Job)user
	return edited_collapse_blank_run(ef, job.seam, job.residue)
}

// editor_symbol_move moves or copies `s` (with its preceding comments)
// into the target file at the given anchor: `position` is "end" or a
// name path already resolved to `target` (nil only allowed for "end").
// `source_contents`/`target_contents` are buffer-aware reads the caller
// took (they die with the caller's allocator). Returns the operation
// summary and error strings through the temp allocator. The mode arrives
// parsed (Move_Mode): the wire spelling is resolved once, by the svc
// boundary, through move_mode_parse.
editor_symbol_move :: proc(
	e: ^Editor,
	name_path: string,
	s: ^symbol.Symbol,
	source_rel: string,
	source_lang: string,
	source_contents: string,
	target_rel: string,
	target_lang: string,
	target_contents: string,
	target: ^symbol.Symbol,
	position: string,
	mode: Move_Mode,
) -> (summary: string, err: Editor_Err, msg: string) {

	if len(s.children) > 0 {
		return "", .Invalid_Symbol, strings.concatenate({
			"symbol \"", name_path, "\" has children (e.g. class with methods); move_symbol only supports leaf symbols",
		}, context.temp_allocator)
	}

	extracted, comment_start, body_end, xerr, xmsg := extract_with_comments(source_contents, s, source_lang)
	if xerr != .None {
		return "", xerr, strings.concatenate({"extract symbol: ", xmsg}, context.temp_allocator)
	}

	source_indent := detect_line_indent(source_contents, comment_start)

	lines := split_lf(target_contents, context.temp_allocator)
	insert_line := 0
	target_indent := ""
	if position == "end" {
		last_non_empty := len(lines) - 1
		for last_non_empty >= 0 && strings.trim_space(lines[last_non_empty]) == "" {
			last_non_empty -= 1
		}
		insert_line = last_non_empty + 1
	} else {
		if target == nil || target.range == nil {
			return "", .Position, "get target end position: body end position not available"
		}
		insert_line = int(target.range.end.line) + 1
		target_indent = detect_line_indent(target_contents, insert_line)
	}

	if source_lang == target_lang || is_same_family(source_lang, target_lang) {
		extracted = adjust_indentation(extracted, source_indent, target_indent)
	}

	if !strings.has_prefix(extracted, "\n") {
		extracted = strings.concatenate({"\n", extracted}, context.temp_allocator)
	}
	// A target without a trailing newline has no phantom final line: the
	// insertion lands at the end of content, where the separator newline
	// above only terminates the last line — one more keeps the moved
	// block's one-blank-line separation.
	if insert_line == len(lines) {
		extracted = strings.concatenate({"\n", extracted}, context.temp_allocator)
	}
	if !strings.has_suffix(extracted, "\n") {
		extracted = strings.concatenate({extracted, "\n"}, context.temp_allocator)
	}

	// Case-insensitive: the filesystems that matter are; a case-divergent
	// spelling of one file must still take the intra-file path.
	if strings.equal_fold(source_rel, target_rel) {
		if insert_line >= comment_start && insert_line <= body_end {
			return "", .Invalid, strings.concatenate({
				"cannot move symbol \"", name_path, "\" into its own body range",
			}, context.temp_allocator)
		}
		job := Move_Job{
			insert_first = insert_line > body_end,
			insert_line  = insert_line,
			text         = extracted,
			del_start    = comment_start,
			del_end      = body_end + 1,
		}
		if werr, wmsg := editor_edit_ctx(e, target_rel, {apply = move_step, user = &job}); werr != .None {
			return "", werr, wmsg
		}
	} else {
		// Cross-file move is two per-file transactions by design (each
		// atomic with rollback): a failed source
		// delete after a successful insert leaves the symbol in both files,
		// as the error below reports.
		insert := Edit_Action{kind = .Insert, start_line = insert_line, start_col = 0, text = extracted}
		if werr, wmsg := edit_file(e, target_rel, insert); werr != .None {
			return "", werr, strings.concatenate({"insert into target: ", wmsg}, context.temp_allocator)
		}
		if mode == .Move {
			del := Edit_Action{kind = .Delete, start_line = comment_start, start_col = 0, end_line = body_end + 1, end_col = 0}
			if derr, dmsg := edit_file(e, source_rel, del); derr != .None {
				return "", derr, strings.concatenate({"delete from source (symbol exists in both files): ", dmsg}, context.temp_allocator)
			}
			// The vacated source seam collapses like an in-file delete. The
			// delete already succeeded, so the cosmetic pass cannot fail
			// the move — its error, if any, is dropped.
			cjob := Collapse_Job{seam = comment_start, residue = 0}
			_, _ = editor_edit_ctx(e, source_rel, {apply = collapse_seam_step, user = &cjob})
		}
	}

	verb := "moved"
	if mode == .Copy {
		verb = "copied"
	}
	return strings.concatenate({
		"Successfully ", verb, " symbol \"", name_path, "\" from ", source_rel, " to ", target_rel,
	}, context.temp_allocator), .None, ""
}
