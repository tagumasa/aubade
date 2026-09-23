// The svc.file/outline implementation: structural reads of JSON-family
// and YAML files. Without a path it renders the key-tree outline; with a
// jq-style path it returns the value(s) at that path with their line
// range. The parse substrate is the same registry the symbol pipeline
// uses; these grammars carry no symbol captures, so this face is the only
// structural view they get.
package svc

import "core:strings"
import "src:editor"
import "src:platform"
import "src:safety"
import "src:ts"
import "src:util"

// File_Outline_Mode is the outline face's answer vocabulary; the wire
// renders it through FILE_OUTLINE_MODE_NAMES, its one spelling table.
File_Outline_Mode :: enum {
	Outline,  // no path: the key-tree outline is the answer
	Value,    // the plain source slice of the reached node
	Iterated, // one indexed entry per array item
	Keys,     // one line per object key, with its line number
}

FILE_OUTLINE_MODE_NAMES :: []string{"outline", "value", "iterated", "keys"}

file_outline_mode_string :: proc(m: File_Outline_Mode) -> string {
	names := FILE_OUTLINE_MODE_NAMES
	return names[cast(int)m]
}

// file_outline_mode maps a path answer's kind onto the mode vocabulary
// (the kind and mode vocabularies line up one to one; a value outside the
// closed kinds can only arrive through a bad cast and reads as .Value,
// the plain-slice answer).
file_outline_mode :: proc(kind: ts.Structure_Path_Kind) -> File_Outline_Mode {
	switch kind {
	case .Value:
		return .Value
	case .Iterated:
		return .Iterated
	case .Keys:
		return .Keys
	}
	return .Value
}

File_Outline_Result :: struct {
	content: string, // owned by `a`
	mode:    File_Outline_Mode,
	// 0-based line range of the reached node (extraction modes).
	start_line: int,
	end_line:   int,
	// the answer hit the max_chars cap (partial outline / sliced value).
	truncated: bool,
	// sensitive-content prompt heuristic hit (same rule as file_read).
	read_ask: bool,
}

// structure_lang_supported gates the outline face: the JSON family and
// YAML. Canonical grammar names (aliases like yml/geojson already resolve
// onto these).
structure_lang_supported :: proc(lang: string) -> bool {
	return lang == "json" || lang == "json5" || lang == "yaml"
}

file_outline :: proc(
	ed: ^editor.Editor,
	deny: ^safety.Deny_List,
	rel_path: string,
	path: string,
	max_chars: int,
	a := context.allocator,
) -> (res: File_Outline_Result, err: platform.Err) {
	// The sensitive-path gate runs before anything is opened (the shared
	// single-file gate, same as file_read): deny globs and the
	// system-location check both judge a symlink by its target. nil deny
	// (tests, hostless callers) skips.
	if derr, denied := sensitive_path_denied(ed, deny, rel_path, a); denied {
		return {}, derr
	}

	rel := normalize_rel(rel_path, context.temp_allocator)
	if rel == "" {
		return {}, wrapped_err(.Invalid, "file outline: empty relative path", a)
	}
	abs, perr := safety.pathguard_validate_contained(ed.project_root, rel, context.temp_allocator)
	if perr.reason != "" {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({"file outline: invalid path: ", perr.reason}, context.temp_allocator),
			a,
		)
	}
	kind, size, sok := util.stat_kind_size(abs, context.temp_allocator)
	if !sok {
		return {}, wrapped_err(
			.NotFound,
			strings.concatenate({"relative path does not exist: ", rel}, context.temp_allocator),
			a,
		)
	}
	if kind == .Directory {
		return {}, wrapped_err(.Invalid, "file outline: path is a directory", a)
	}
	// Detect before the size gate: a large strict-JSON file answers through
	// the streaming scanner instead of failing the tree budget.
	idx, ok := ts.registry_detect(rel_base(rel))
	// Materialize the registry locally before indexing (the compiler
	// rejects variable indexing straight into constant data).
	table := ts.GRAMMARS
	lang := ""
	if ok {
		lang = table[idx].name
	}

	if size > MAX_SOURCE_FILE_BYTES {
		// The tree-free mirror of the face below: a parse tree costs
		// roughly 25x its source bytes, so a multi-megabyte model or a
		// JSONL log must not become one — the streaming walk answers the
		// same outline and path queries with O(depth) state. JSONL
		// (several top-level values) answers as a record sequence. The
		// editor's document bound still applies.
		if ok && lang == "json" {
			if size > editor.MAX_FILE_BYTES {
				msg := strings.concatenate({
					"file outline: file is too large (", util.int_to_dec(int(size), context.temp_allocator),
					" bytes); maximum is ", util.int_to_dec(editor.MAX_FILE_BYTES, context.temp_allocator),
					" bytes: ", rel,
				}, context.temp_allocator)
				return {}, wrapped_err(.Invalid, msg, a)
			}
			contents, rerr, _ := editor.editor_read_file(ed, rel)
			if rerr != .None {
				return {}, wrapped_err(
					.NotFound,
					strings.concatenate({"file outline: unreadable: ", rel}, a),
					a,
				)
			}
			defer delete(contents, ed.allocator)
			res.read_ask = safety.is_read_ask(rel)

			if path == "" {
				text, truncated, oerr := ts.structure_stream_outline(
					contents, {max_chars = max_chars}, a,
				)
				if oerr != "" {
					return {}, wrapped_err(
						.Invalid,
						strings.concatenate({"file outline: ", oerr, ": ", rel}, a),
						a,
					)
				}
				return {
					content = text,
					mode = .Outline,
					truncated = truncated,
					read_ask = res.read_ask,
				}, nil
			}
			pres, perrs := ts.structure_stream_resolve_path(contents, path, max_chars, a)
			if perrs != "" {
				return {}, wrapped_err(
					.Invalid,
					strings.concatenate({rel, ": ", perrs}, a),
					a,
				)
			}
			return {
				content = pres.content,
				mode = file_outline_mode(pres.kind),
				start_line = pres.start_line,
				end_line = pres.end_line,
				truncated = pres.truncated,
				read_ask = res.read_ask,
			}, nil
		}
		msg := strings.concatenate({
			"file outline: file is too large (", util.int_to_dec(int(size), context.temp_allocator),
			" bytes); maximum is ", util.int_to_dec(MAX_SOURCE_FILE_BYTES, context.temp_allocator),
			" bytes: ", rel,
		}, context.temp_allocator)
		return {}, wrapped_err(.Invalid, msg, a)
	}

	if !ok {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({
				"file outline: unsupported file type: ", rel,
				"; structured reads serve .json/.jsonc/.json5/.yaml/.yml — use file_read",
			}, a),
			a,
		)
	}
	if !structure_lang_supported(lang) {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({
				"file outline: unsupported file type: ", rel, " (detected ", lang, ")",
				"; structured reads serve .json/.jsonc/.json5/.yaml/.yml — use file_read",
			}, a),
			a,
		)
	}

	// The editor's view when it holds one, else the disk read — the same
	// bytes the edit tools transact against (BOM-stripped, decoded).
	contents, rerr, _ := editor.editor_read_file(ed, rel)
	if rerr != .None {
		return {}, wrapped_err(
			.NotFound,
			strings.concatenate({"file outline: unreadable: ", rel}, a),
			a,
		)
	}
	defer delete(contents, ed.allocator)

	// The gate above used the stat size; the read may have seen a file
	// grown since. Re-check the bytes actually read so the tree budget (a
	// parse tree costs roughly 25x its source) cannot be ballooned by
	// growth past the gate.
	if len(contents) > MAX_SOURCE_FILE_BYTES {
		msg := strings.concatenate({
			"file outline: file is too large (", util.int_to_dec(len(contents), context.temp_allocator),
			" bytes); maximum is ", util.int_to_dec(MAX_SOURCE_FILE_BYTES, context.temp_allocator),
			" bytes: ", rel,
		}, context.temp_allocator)
		return {}, wrapped_err(.Invalid, msg, a)
	}

	res.read_ask = safety.is_read_ask(rel)

	pr, perr2 := ts.parse(contents, lang)
	if perr2 != "" {
		return {}, wrapped_err(
			.Internal,
			strings.concatenate({"file outline: ", perr2, ": ", rel}, a),
			a,
		)
	}
	defer ts.parse_release(&pr)
	root := ts.parse_root(&pr)
	if ts.node_is_null(root) {
		return {}, wrapped_err(.Internal, "file outline: empty parse tree", a)
	}
	if row := ts.structure_error_row(root); row >= 0 {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({
				"file outline: parse error near line ", util.int_to_dec(row, context.temp_allocator),
				": ", rel,
			}, a),
			a,
		)
	}

	if path == "" {
		text, truncated := ts.structure_outline(root, contents, {max_chars = max_chars}, a)
		return {
			content = text,
			mode = .Outline,
			truncated = truncated,
			read_ask = res.read_ask,
		}, nil
	}

	pres, perrs := ts.structure_resolve_path(root, contents, path, max_chars, a)
	if perrs != "" {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({rel, ": ", perrs}, a),
			a,
		)
	}
	return {
		content = pres.content,
		mode = file_outline_mode(pres.kind),
		start_line = pres.start_line,
		end_line = pres.end_line,
		truncated = pres.truncated,
		read_ask = res.read_ask,
	}, nil
}
