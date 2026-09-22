// Comment detection and text-block hygiene for the editor: language
// comment patterns, the upward docstring scan, brace/indentation
// validation for extracted blocks, re-indentation, and bounded line
// extraction. All pure string logic over normalised (LF) content.
package editor

import "core:strings"
import "src:util"

Comment_Pattern :: struct {
	// Every language family uses exactly one line-comment marker, so the
	// marker is a plain string (a slice field would drag constant-slice
	// scrambling and frame-borrow problems into every return).
	line_comment: string,
	block_start:  string,
	block_end:    string,
}

// comment_pattern_for_language returns the comment syntax for a language
// id: the comment field of the LANGUAGE_PROPS row (language_props.odin
// carries the decisions, and the table test in tests/editor_test.odin
// fails when a registry language lacks one). Python docstrings live
// inside the body and are never scanned for upward — only line comments
// and block comments above a definition are detected.
comment_pattern_for_language :: proc(lang: string) -> (pat: Comment_Pattern, listed: bool) {
	props, ok := language_props(lang)
	return props.comment, ok
}

// comment_text_marked reports whether a comment-block text actually reads
// as comments in the language: some line starts with the line-comment
// marker, or a block-comment opener appears. The docstring tools write
// comment text verbatim and refuse unmarked text — a bare line would not
// be a comment at all once written, and the upward scan (which recognizes
// only markers) could never find or remove it again.
comment_text_marked :: proc(text: string, lang: string) -> bool {
	pat, _ := comment_pattern_for_language(lang)
	if pat.line_comment != "" {
		for line in split_lf(text) {
			if strings.has_prefix(strings.trim_space(line), pat.line_comment) {
				return true
			}
		}
	}
	return pat.block_start != "" && strings.contains(text, pat.block_start)
}

// find_comment_start scans upward from def_line (0-based) to find where the
// docstring or comment block preceding the definition begins. Returns the
// 0-based line of the first comment line (def_line when no comment sits
// above). Handles line comments, block comments, and blank lines between
// the comment and the definition; a blank line above the comment block
// ends the attachment, so a banner comment separated from the docstring
// stays with the file.
find_comment_start :: proc(file_content: string, def_line: int, pattern: Comment_Pattern) -> int {
	lines := split_lf(file_content, context.temp_allocator)
	if def_line <= 0 || def_line >= len(lines) {
		return def_line
	}

	i := def_line - 1
	seen_comment := false
	for i >= 0 {
		trimmed := strings.trim_space(lines[i])

		if trimmed == "" {
			// Blanks between the definition and its comment block attach the
			// block; a blank ABOVE an already-seen comment run detaches
			// whatever sits further up (a section banner stays behind).
			if seen_comment {
				break
			}
			i -= 1
			continue
		}
		if is_line_comment(trimmed, pattern) {
			seen_comment = true
			i -= 1
			continue
		}
		if pattern.block_end != "" && strings.contains(trimmed, pattern.block_end) {
			start := find_block_comment_start(lines, i, pattern)
			i = start - 1
			seen_comment = true
			continue
		}
		break
	}

	comment_start := i + 1
	for comment_start < def_line && strings.trim_space(lines[comment_start]) == "" {
		comment_start += 1
	}
	if comment_start >= def_line {
		return def_line
	}
	if comment_start > 0 && is_symbol_definition(lines[comment_start - 1]) {
		return def_line
	}
	return comment_start
}

is_line_comment :: proc(trimmed: string, pattern: Comment_Pattern) -> bool {
	return pattern.line_comment != "" && strings.has_prefix(trimmed, pattern.line_comment)
}

find_block_comment_start :: proc(lines: []string, end_line_idx: int, pattern: Comment_Pattern) -> int {
	for i := end_line_idx; i >= 0; i -= 1 {
		trimmed := strings.trim_space(lines[i])
		if strings.contains(trimmed, pattern.block_start) {
			return i
		}
	}
	return end_line_idx
}

DEFINITION_KEYWORDS :: []string{
	"func ", "func(",
	"def ", "def(",
	"function ", "function(",
	"class ", "class(",
	"pub fn ", "pub fn(",
	"pub async fn ",
	"fn ", "fn(",
	"impl ",
	"type ", "type(",
	"interface ", "interface{",
	"struct ", "struct{",
	"enum ", "enum(",
	"const ", "const(",
	"var ", "var(",
	"module ",
	"async def ", "async def(",
	"async function ", "async function(",
	"static ", "static(",
	"private ", "private(",
	"protected ", "protected(",
	"public ", "public(",
	"internal ", "internal(",
}

is_symbol_definition :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	for kw in DEFINITION_KEYWORDS {
		if strings.has_prefix(trimmed, kw) {
			return true
		}
	}
	return false
}

// validate_brace_balance checks that an extracted block has balanced braces
// for brace languages or consistent indentation for indentation languages.
// .None when the block passes.
validate_brace_balance :: proc(text: string, lang: string) -> (err: Editor_Err, msg: string) {
	props, _ := language_props(lang)
	if props.indent_significant {
		return validate_indentation(text)
	}
	return validate_braces(text, props.comment)
}

// validate_braces counts braces outside string/char literals and outside
// comments. Comments carry quotes freely ("don't", the "end" marker), so a
// comment-blind scan mis-toggles the literal states and either rejects a
// balanced block or silently skips the count — the extracted block includes
// the symbol's docstring, whose apostrophes are ordinary prose.
validate_braces :: proc(text: string, pat: Comment_Pattern) -> (err: Editor_Err, msg: string) {
	depth := 0
	in_str := false
	str_delim := u8(0)
	in_char := false
	in_line_comment := false
	in_block_comment := false

	for i := 0; i < len(text); i += 1 {
		ch := text[i]

		if in_line_comment {
			if ch == '\n' {
				in_line_comment = false
			}
			continue
		}
		if in_block_comment {
			// An unterminated block comment runs to the end of the block:
			// conservative (the count stops early) rather than letting the
			// comment tail toggle literal states.
			if strings.has_prefix(text[i:], pat.block_end) {
				in_block_comment = false
				i += len(pat.block_end) - 1
			}
			continue
		}
		if in_str {
			if str_delim != '`' && ch == '\\' && i + 1 < len(text) {
				i += 1
				continue
			}
			if ch == str_delim {
				in_str = false
			}
			continue
		}
		if in_char {
			if ch == '\\' && i + 1 < len(text) {
				i += 1
				continue
			}
			if ch == '\'' {
				in_char = false
			}
			continue
		}

		// Comment starts are tested only in the neutral state, after the
		// literal states above: a "//" inside a string stays string content,
		// and a quote inside a comment stays comment text.
		if pat.line_comment != "" && strings.has_prefix(text[i:], pat.line_comment) {
			in_line_comment = true
			i += len(pat.line_comment) - 1
			continue
		}
		if pat.block_start != "" && strings.has_prefix(text[i:], pat.block_start) {
			in_block_comment = true
			i += len(pat.block_start) - 1
			continue
		}

		switch ch {
		case '"':
			in_str = true
			str_delim = '"'
		case '\'':
			// A digit before the quote is a numeric literal suffix, not a
			// character literal.
			if !is_digit_byte(text, i) {
				in_char = true
			}
		case '`':
			in_str = true
			str_delim = '`'
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth < 0 {
				return .Invalid, "unbalanced braces: extra closing brace"
			}
		case:
		}
	}

	if depth != 0 {
		return .Invalid, "unbalanced braces: unclosed opening brace(s)"
	}
	return .None, ""
}

is_digit_byte :: proc(text: string, idx: int) -> bool {
	return idx > 0 && text[idx - 1] >= '0' && text[idx - 1] <= '9'
}

validate_indentation :: proc(text: string) -> (err: Editor_Err, msg: string) {
	lines := split_lf(text, context.temp_allocator)
	block_uses_tabs := false
	block_uses_spaces := false

	for i in 0..<len(lines) {
		line := lines[i]
		if strings.trim_space(line) == "" {
			continue
		}
		trimmed := strings.trim_left(line, " \t")
		indent := line[:len(line) - len(trimmed)]
		has_tab := strings.contains_rune(indent, '\t')
		has_space := strings.contains_rune(indent, ' ')
		if has_tab && has_space {
			return .Invalid, "mixed tabs and spaces in indentation"
		}
		if has_tab {
			block_uses_tabs = true
		}
		if has_space {
			block_uses_spaces = true
		}
	}
	if block_uses_tabs && block_uses_spaces {
		return .Invalid, "inconsistent indentation: some lines use tabs and others use spaces"
	}
	return .None, ""
}

// adjust_indentation re-indents an extracted block so its base
// indentation matches the target context (scratch in, scratch out — the
// caller clones what it keeps).
adjust_indentation :: proc(text, source_indent, target_indent: string) -> string {
	if source_indent == target_indent {
		return text
	}

	detected := util.detect_indent(text)
	if detected == "" && source_indent == "" {
		if target_indent == "" {
			return text
		}
		lines := split_lf(text, context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		for i in 0..<len(lines) {
			if i > 0 {
				strings.write_byte(&b, '\n')
			}
			if strings.trim_space(lines[i]) == "" {
				continue
			}
			strings.write_string(&b, target_indent)
			strings.write_string(&b, lines[i])
		}
		return strings.to_string(b)
	}
	if detected == "" {
		detected = source_indent
	}

	lines := split_lf(text, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for i in 0..<len(lines) {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		if strings.trim_space(lines[i]) == "" {
			continue
		}
		strings.write_string(&b, target_indent)
		if strings.has_prefix(lines[i], detected) {
			strings.write_string(&b, lines[i][len(detected):])
		} else {
			strings.write_string(&b, lines[i])
		}
	}
	return strings.to_string(b)
}

// extract_lines extracts lines start_line..end_line (0-based, inclusive).
// Carriage returns are stripped so the result is LF-terminated regardless
// of the source convention.
extract_lines :: proc(file_content: string, start_line, end_line: int) -> (text: string, err: Editor_Err, msg: string) {
	lines := split_lf(file_content, context.temp_allocator)
	if start_line < 0 || end_line < 0 {
		return "", .Position, "extract_lines: negative line index"
	}
	if end_line >= len(lines) {
		return "", .Position, "extract_lines: end line exceeds file bounds"
	}
	if start_line > end_line {
		return "", .Position, "extract_lines: start line > end line"
	}
	b := strings.builder_make(context.temp_allocator)
	for i in start_line..=end_line {
		if i > start_line {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, lines[i])
	}
	return strings.to_string(b), .None, ""
}

// split_lf splits content into LF lines (CRLF endings lose the \r).
split_lf :: proc(content: string, a := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 32, a)
	start := 0
	for i := 0; i <= len(content); i += 1 {
		if i < len(content) && content[i] != '\n' {
			continue
		}
		line := content[start:i]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		append(&out, line)
		start = i + 1
	}
	return out[:]
}
