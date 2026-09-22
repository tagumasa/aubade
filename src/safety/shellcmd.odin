// Shell command parser: structural analysis that respects quoting, escapes,
// and command separators. Replaces regex-on-raw-string with deterministic
// tokenization that flags constructs the shell would evaluate lexically
// (command substitution, variable expansion, unbalanced quotes).
//
// The parser is deliberately conservative: any construct it cannot fully
// resolve is reported as a warning so callers can refuse the command
// rather than risk a bypass.
package safety

import "core:fmt"
import "core:mem"
import "core:strings"

Shell_Token_Kind :: enum {
	Word,
	Separator,
	Redirect,
	Subshell,
}

Shell_Token :: struct {
	kind:     Shell_Token_Kind,
	value:    string, // resolved value (quotes/escapes processed)
	raw:      string, // original substring
	quoted:   bool,
	quote_ch: byte, // quote character: '"' '\'' or 0
}

Shell_Command :: struct {
	tokens:     [dynamic]Shell_Token,
	executable: string, // resolved first word, empty if not determinable
	args:       [dynamic]string,
}

// parse_shell_command performs structural analysis of a shell command
// string. It splits on unquoted separators, resolves quoting and escapes,
// and flags constructs that prevent deterministic evaluation.
parse_shell_command :: proc(input: string, a: mem.Allocator) -> (commands: [dynamic]Shell_Command, warnings: [dynamic]string) {
	tokens, w := shell_tokenize(input, a)

	current := Shell_Command{
		tokens = make([dynamic]Shell_Token, 0, 8, a),
		args = make([dynamic]string, 0, 4, a),
	}
	flush :: proc(cur: ^Shell_Command, cmds: ^[dynamic]Shell_Command, alloc: mem.Allocator) {
		if len(cur.tokens) == 0 {
			return
		}
		// extract_exec_and_args returns a-owned clones; taking them directly
		// keeps a single owner (a second clone pass orphaned the first).
		cur.executable, cur.args = extract_exec_and_args(cur.tokens[:], alloc)
		append(cmds, cur^)
		// The stored copy owns the old backings; truncating in place would
		// alias them again, so hand `cur` fresh arrays for the next command.
		cur^ = Shell_Command{
			tokens = make([dynamic]Shell_Token, 0, 8, alloc),
			args = make([dynamic]string, 0, 4, alloc),
		}
	}

	cmds := make([dynamic]Shell_Command, 0, 4, a)
	for tok in tokens {
		if tok.kind == .Separator {
			flush(&current, &cmds, a)
			continue
		}
		append(&current.tokens, tok)
	}
	flush(&current, &cmds, a)

	commands = cmds
	warnings = w
	return
}

// normalize_shell_command returns the fully-normalized representation of a
// shell command string. Used for block-pattern matching so patterns see
// what the shell will actually execute.
normalize_shell_command :: proc(input: string, a: mem.Allocator) -> string {
	tokens, _ := shell_tokenize(input, a)
	if len(tokens) == 0 {
		return ""
	}
	parts := make([dynamic]string, 0, len(tokens), a)
	for tok in tokens {
		append(&parts, strings.clone(tok.value, a))
	}
	defer delete(parts)
	return strings.join(parts[:], " ", a)
}

shell_tokenize :: proc(input: string, a: mem.Allocator) -> (tokens: [dynamic]Shell_Token, warnings: [dynamic]string) {
	p := _Shell_Parser{
		s        = input,
		tokens   = make([dynamic]Shell_Token, 0, 16, a),
		warnings = make([dynamic]string, 0, 4, a),
		allocator = a,
	}
	for p.pos < len(p.s) {
		ch := p.s[p.pos]
		if ch == ' ' || ch == '\t' || ch == '\n' {
			p.pos += 1
			continue
		}
		if ch == '#' {
			break
		}
		if shell_try_separator(&p) {
			continue
		}
		if shell_try_redirect(&p) {
			continue
		}
		if ch == '(' {
			shell_consume_subshell(&p)
			continue
		}
		if ch == ')' {
			// A stray closer at word start: parse_word treats it as a
			// boundary and cannot consume it, so the tokenizer must skip
			// it here or loop forever (the shell would reject the line;
			// we only need to keep scanning).
			p.pos += 1
			continue
		}
		shell_parse_word(&p)
	}
	tokens = p.tokens
	warnings = p.warnings
	return
}

_Shell_Parser :: struct {
	s:         string,
	pos:       int,
	tokens:    [dynamic]Shell_Token,
	warnings:  [dynamic]string,
	allocator: mem.Allocator,
}

@(private)
shell_try_separator :: proc(p: ^_Shell_Parser) -> bool {
	rest := p.s[p.pos:]
	a := p.allocator
	switch {
	case strings.has_prefix(rest, "&&"):
		append(&p.tokens, Shell_Token{kind = .Separator, raw = strings.clone("&&", a), value = strings.clone("&&", a)})
		p.pos += 2
		return true
	case strings.has_prefix(rest, "||"):
		append(&p.tokens, Shell_Token{kind = .Separator, raw = strings.clone("||", a), value = strings.clone("||", a)})
		p.pos += 2
		return true
	case rest[0] == '|':
		append(&p.tokens, Shell_Token{kind = .Separator, raw = strings.clone("|", a), value = strings.clone("|", a)})
		p.pos += 1
		return true
	case rest[0] == ';':
		append(&p.tokens, Shell_Token{kind = .Separator, raw = strings.clone(";", a), value = strings.clone(";", a)})
		p.pos += 1
		return true
	case rest[0] == '&':
		if len(rest) > 1 && rest[1] == '>' {
			return false // &> handled as redirect
		}
		append(&p.tokens, Shell_Token{kind = .Separator, raw = strings.clone("&", a), value = strings.clone("&", a)})
		p.pos += 1
		return true
	}
	return false
}

@(private)
shell_try_redirect :: proc(p: ^_Shell_Parser) -> bool {
	rest := p.s[p.pos:]
	a := p.allocator
	// Longest-first within each prefix family: a first-prefix-wins scan
	// with "2>" before "2>>" would shadow the fd-append forms into dead
	// entries and mis-tokenize them as two redirects.
	ops := []string{"2>>", "1>>", "<<", ">>", ">&", "&>", "2>", "1>"}
	for op in ops {
		if strings.has_prefix(rest, op) {
			append(&p.tokens, Shell_Token{kind = .Redirect, raw = strings.clone(op, a), value = strings.clone(op, a)})
			p.pos += len(op)
			return true
		}
	}
	if rest[0] == '>' || rest[0] == '<' {
		b: [1]u8 = {rest[0]}
		s := strings.clone(string(b[:]), a)
		append(&p.tokens, Shell_Token{kind = .Redirect, raw = strings.clone(s, a), value = s})
		p.pos += 1
		return true
	}
	return false
}

@(private)
shell_consume_subshell :: proc(p: ^_Shell_Parser) {
	a := p.allocator
	append(&p.warnings, strings.clone("subshell construct '(..)' prevents deterministic evaluation", a))
	append(&p.tokens, Shell_Token{kind = .Subshell, raw = strings.clone("(", a), value = strings.clone("(", a)})
	p.pos += 1
	depth := 1
	start := p.pos
	for p.pos < len(p.s) && depth > 0 {
		switch p.s[p.pos] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		}
		p.pos += 1
	}
	if depth > 0 {
		append(&p.warnings, strings.clone("unbalanced parentheses in subshell", a))
	}
	body := strings.clone(p.s[start:p.pos], a)
	append(&p.tokens, Shell_Token{kind = .Word, value = strings.clone(body, a), raw = body})
}

@(private)
shell_parse_word :: proc(p: ^_Shell_Parser) {
	a := p.allocator
	value_buf := make([dynamic]u8, 0, 32, a)
	raw_buf := make([dynamic]u8, 0, 32, a)
	defer delete(value_buf)
	defer delete(raw_buf)
	quoted := false
	quote_ch: byte = 0

	push_buf :: proc(buf: ^[dynamic]u8, src: string, n: int) {
		for i in 0 ..< n {
			append(buf, src[i])
		}
	}

	// skip_backtick consumes a `...` command substitution — through the
	// closing backtick when balanced — warns, and keeps its literal text
	// in the raw token only (the substitution's output is not knowable
	// without running the command).
	skip_backtick :: proc(p: ^_Shell_Parser, raw_buf: ^[dynamic]u8, warning: string, a: mem.Allocator) {
		append(&p.warnings, strings.clone(warning, a))
		start := p.pos
		p.pos += 1
		for p.pos < len(p.s) && p.s[p.pos] != '`' {
			p.pos += 1
		}
		if p.pos < len(p.s) {
			p.pos += 1
		}
		push_buf(raw_buf, p.s[start:p.pos], p.pos - start)
	}

	for p.pos < len(p.s) {
		ch := p.s[p.pos]
		// Word boundary.
		if ch == ' ' || ch == '\t' || ch == '\n' ||
		   ch == ';' || ch == '|' || ch == '&' ||
		   ch == '(' || ch == ')' ||
		   ch == '>' || ch == '<' {
			break
		}

		// cmd.exe escape (Windows host only): outside double quotes a
		// caret consumes itself and takes the next byte literally into
		// the word — `de^l` executes as `del`, and `^"` is a literal
		// quote byte, not an opener. The value this parser resolves is
		// what block patterns match, so it must carry the executed
		// spelling, never the mangled one. Inside double quotes cmd keeps
		// the caret literal (the dq scan below appends it verbatim);
		// POSIX sh has no equivalent escape, so other builds keep the
		// caret a plain byte.
		when ODIN_OS == .Windows {
			if ch == '^' {
				append(&raw_buf, ch)
				p.pos += 1
				if p.pos < len(p.s) {
					next := p.s[p.pos]
					append(&value_buf, next)
					append(&raw_buf, next)
					p.pos += 1
				}
				continue
			}
		}

		// Single quote: literal until closing.
		if ch == '\'' {
			quoted = true
			quote_ch = '\''
			append(&raw_buf, ch)
			p.pos += 1
			if p.pos >= len(p.s) {
				append(&p.warnings, strings.clone("unbalanced single quote in command", a))
				break
			}
			scan := p.pos
			for scan < len(p.s) && p.s[scan] != '\'' {
				append(&value_buf, p.s[scan])
				append(&raw_buf, p.s[scan])
				scan += 1
			}
			p.pos = scan
			if p.pos >= len(p.s) {
				append(&p.warnings, strings.clone("unbalanced single quote in command", a))
				break
			}
			append(&raw_buf, '\'')
			p.pos += 1
			continue
		}

		// Double quote: variable expansion and command substitution flagged.
		if ch == '"' {
			quoted = true
			quote_ch = '"'
			append(&raw_buf, ch)
			p.pos += 1
			if p.pos >= len(p.s) {
				append(&p.warnings, strings.clone("unbalanced double quote in command", a))
				break
			}
			dq_break := false
			for !dq_break && p.pos < len(p.s) {
				c2 := p.s[p.pos]
				if c2 == '"' {
					append(&raw_buf, c2)
					p.pos += 1
					dq_break = true
					break
				}
				if c2 == '\\' && p.pos + 1 < len(p.s) {
					next := p.s[p.pos + 1]
					if next == '$' || next == '`' || next == '"' || next == '\\' || next == '\n' {
						append(&value_buf, next)
						append(&raw_buf, c2)
						append(&raw_buf, next)
						p.pos += 2
						continue
					}
					append(&value_buf, c2)
					append(&raw_buf, c2)
					p.pos += 1
					continue
				}
				if c2 == '$' {
					exp_start := p.pos
					n := shell_try_variable_expansion(p)
					if n > 0 {
						append(&p.warnings, strings.clone("variable expansion inside double quotes prevents deterministic evaluation", a))
						// The helper already advanced p.pos past the construct;
						// keep its literal text in the token.
						push_buf(&value_buf, p.s[exp_start:p.pos], p.pos - exp_start)
						push_buf(&raw_buf, p.s[exp_start:p.pos], p.pos - exp_start)
						continue
					}
					append(&value_buf, c2)
					append(&raw_buf, c2)
					p.pos += 1
					continue
				}
				if c2 == '`' {
					skip_backtick(p, &raw_buf, "backtick command substitution inside double quotes", a)
					continue
				}
				append(&value_buf, c2)
				append(&raw_buf, c2)
				p.pos += 1
			}
			if !dq_break {
				append(&p.warnings, strings.clone("unbalanced double quote in command", a))
				break
			}
			continue
		}

		// Windows variable expansion %VAR%.
		if ch == '%' && p.pos + 2 < len(p.s) {
			next := p.s[p.pos + 1]
			if (next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z') || next == '_' {
				scan := p.pos + 2
				end := -1
				for scan < len(p.s) {
					if p.s[scan] == '%' {
						end = scan
						break
					}
					scan += 1
				}
				if end >= 0 {
					slice := strings.clone(p.s[p.pos: end + 1], a)
					append(&p.warnings, fmt.tprintf("Windows variable expansion %s prevents deterministic evaluation", slice))
					push_buf(&value_buf, p.s[p.pos:end + 1], end + 1 - p.pos)
					push_buf(&raw_buf, p.s[p.pos:end + 1], end + 1 - p.pos)
					p.pos = end + 1
					continue
				}
			}
		}

		// Backslash: POSIX escape, or literal path separator on Windows
		// (paths like C:\Windows would lose every \W otherwise — the
		// reference keeps it literal there for the same reason).
		if ch == '\\' && p.pos + 1 < len(p.s) {
			when ODIN_OS == .Windows {
				append(&value_buf, '\\')
				append(&raw_buf, '\\')
				p.pos += 1
				continue
			} else {
				next := p.s[p.pos + 1]
				append(&value_buf, next)
				append(&raw_buf, '\\')
				append(&raw_buf, next)
				p.pos += 2
				continue
			}
		}

		// Dollar: variable expansion, command substitution, or literal.
		if ch == '$' {
			exp_start := p.pos
			n := shell_try_variable_expansion(p)
			if n > 0 {
				append(&p.warnings, strings.clone("variable expansion prevents deterministic evaluation of executable or arguments", a))
				push_buf(&value_buf, p.s[exp_start:p.pos], p.pos - exp_start)
				push_buf(&raw_buf, p.s[exp_start:p.pos], p.pos - exp_start)
				continue
			}
			if p.pos + 1 < len(p.s) && p.s[p.pos + 1] == '(' {
				append(&p.warnings, strings.clone("command substitution $(..) prevents deterministic evaluation", a))
				start := p.pos
				depth := 0
				for p.pos < len(p.s) {
					if p.s[p.pos] == '(' {
						depth += 1
					} else if p.s[p.pos] == ')' {
						depth -= 1
						if depth == 0 {
							p.pos += 1
							break
						}
					}
					p.pos += 1
				}
				push_buf(&raw_buf, p.s[start:p.pos], p.pos - start)
				continue
			}
			append(&value_buf, ch)
			append(&raw_buf, ch)
			p.pos += 1
			continue
		}

		// Backtick substitution outside quotes.
		if ch == '`' {
			skip_backtick(p, &raw_buf, "backtick command substitution prevents deterministic evaluation", a)
			continue
		}

		// Brace expansion {a,b,c} flagged.
		if ch == '{' {
			scan := p.pos
			end := -1
			for scan < len(p.s) {
				if p.s[scan] == '}' {
					end = scan
					break
				}
				scan += 1
			}
			if end > p.pos {
				region := p.s[p.pos:end]
				has_comma := false
				for r in region {
					if r == ',' {
						has_comma = true
						break
					}
				}
				if has_comma {
					append(&p.warnings, strings.clone("brace expansion prevents deterministic evaluation", a))
				}
			}
		}

		append(&value_buf, ch)
		append(&raw_buf, ch)
		p.pos += 1
	}

	v := strings.clone(string(value_buf[:]), a)
	r := strings.clone(string(raw_buf[:]), a)
	append(&p.tokens, Shell_Token{kind = .Word, value = v, raw = r, quoted = quoted, quote_ch = quote_ch})
}

// shell_try_variable_expansion reads a $VAR or ${VAR} construct starting at
// p.pos. Returns the number of bytes consumed (1 for a literal '$'). On every
// non-zero return p.pos is left just past the construct — callers must not
// advance it again.
@(private)
shell_try_variable_expansion :: proc(p: ^_Shell_Parser) -> int {
	if p.pos >= len(p.s) || p.s[p.pos] != '$' {
		return 0
	}
	if p.pos + 1 < len(p.s) && p.s[p.pos + 1] == '(' {
		return 0
	}
	start := p.pos

	if p.pos + 1 < len(p.s) && p.s[p.pos + 1] == '{' {
		scan := p.pos
		end := -1
		for scan < len(p.s) {
			if p.s[scan] == '}' {
				end = scan
				break
			}
			scan += 1
		}
		if end < 0 {
			consumed := len(p.s) - start
			p.pos = len(p.s)
			return consumed
		}
		consumed := end + 1 - start
		p.pos = end + 1
		return consumed
	}

	p.pos += 1
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' {
			p.pos += 1
		} else {
			break
		}
	}
	consumed := p.pos - start
	if consumed <= 1 {
		p.pos = start + 1
		return 1
	}
	return consumed
}

@(private)
extract_exec_and_args :: proc(tokens: []Shell_Token, a: mem.Allocator) -> (executable: string, args: [dynamic]string) {
	// Grow from the caller's allocator: append to a nil [dynamic] would
	// allocate from context.allocator and strand the backing.
	args = make([dynamic]string, 0, 4, a)
	skip_next := false
	for i := 0; i < len(tokens); i += 1 {
		if skip_next {
			skip_next = false
			continue
		}
		tok := tokens[i]
		if tok.kind == .Redirect {
			if i + 1 < len(tokens) && tokens[i + 1].kind == .Word {
				skip_next = true
			}
			continue
		}
		if tok.kind == .Word {
			if executable == "" {
				executable = strings.clone(tok.value, a)
			} else {
				append(&args, strings.clone(tok.value, a))
			}
		}
	}
	return
}
