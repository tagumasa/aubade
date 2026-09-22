// JSONC reader: aubade's config files are JSON with // and /* */ comments
// and tolerant trailing commas (the same superset the client-config editor
// deals with). strip_jsonc removes both — string literals are protected —
// and core:encoding/json parses the cleaned bytes with the same settings
// endpoint.json and jsonrpc use (parse_integers = true; leaving it off
// silently turns every integer into a float).
package config

import "core:encoding/json"
import "core:fmt"
import "src:platform"
import "src:util"

// strip_jsonc returns a comment-free copy of `data`. With the default
// lenient mode it also drops trailing commas (the tolerated superset
// aubade's own config files use); with strict_commas the commas pass
// through verbatim so a strict JSON parse can judge them — the shape
// client-config write gates need, where comments are fine (those clients
// read JSONC) but a stray comma is a broken file. Newlines inside comments
// are preserved so error positions keep their line numbers. ok == false
// means an unterminated block comment.
strip_jsonc :: proc(data: []u8, strict_commas: bool = false, a := context.allocator) -> (out: []u8, ok: bool) {
	buf := make([dynamic]u8, 0, len(data), a)

	in_string     := false
	escaped       := false
	pending_comma := false

	i := 0
	for i < len(data) {
		c := data[i]

		if in_string {
			append(&buf, c)
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			i += 1
			continue
		}

		switch c {
		case '"':
			flush_pending(&buf, &pending_comma)
			append(&buf, c)
			in_string = true
		case '/':
			if i + 1 < len(data) && data[i + 1] == '/' {
				// Line comment: skip to the newline (the newline itself is
				// emitted by the main loop as ordinary whitespace).
				i += 2
				for i < len(data) && data[i] != '\n' {
					i += 1
				}
				continue
			} else if i + 1 < len(data) && data[i + 1] == '*' {
				// Block comment: skip to */, keeping inner newlines and
				// emitting one space so adjacent tokens stay apart
				// (`1/**/2` must not become `12`).
				i += 2
				closed := false
				for i < len(data) {
					if data[i] == '*' && i + 1 < len(data) && data[i + 1] == '/' {
						i += 2
						closed = true
						break
					}
					if data[i] == '\n' {
						append(&buf, '\n')
					}
					i += 1
				}
				if !closed {
					return buf[:], false
				}
				append(&buf, ' ')
				continue
			} else {
				flush_pending(&buf, &pending_comma)
				append(&buf, c)
			}
		case ',':
			if strict_commas {
				// Emit verbatim: a strict parser must see every comma,
				// wherever it sits, to judge it (pending is never set in
				// this mode, so nothing is held back or dropped).
				append(&buf, c)
			} else {
				// Held back so a trailing comma before } or ] can be
				// dropped; flushed by the next ordinary byte or quote.
				pending_comma = true
			}
		case '}', ']':
			if !strict_commas {
				pending_comma = false // a trailing comma is dropped, not emitted
			}
			append(&buf, c)
		case ' ', '\t', '\n', '\r':
			// Whitespace must not flush a pending comma, or
			// `["a" , \n]` would keep its trailing comma.
			append(&buf, c)
		case:
			flush_pending(&buf, &pending_comma)
			append(&buf, c)
		}
		i += 1
	}
	// A pending comma at EOF is dropped; the parser rejects the residue.
	return buf[:], true
}

flush_pending :: proc(buf: ^[dynamic]u8, pending: ^bool) {
	if pending^ {
		append(buf, ',')
		pending^ = false
	}
}

// jsonc_parse strips JSONC syntax and parses the result. The returned value
// tree is allocated from `a` — release it with json.destroy_value(value, a)
// unless `a` is an arena freed wholesale.
jsonc_parse :: proc(data: []u8, a := context.allocator) -> (value: json.Value, err: platform.Err) {
	clean, ok := strip_jsonc(data, false, a)
	if !ok {
		return nil, platform.Wrapped{
			kind = .Invalid,
			msg  = "unterminated block comment",
		}
	}
	// Depth/encoding guard: the core parser stack-exhausts on deep
	// nesting instead of erroring — a config file must fail with a typed
	// error, not crash the process (see util.json_sanity_ok).
	if !util.json_sanity_ok(clean) {
		return nil, platform.Wrapped{
			kind = .Invalid,
			msg  = "malformed JSON after comment stripping",
		}
	}
	// Parse through the public Parser (what parse_bytes drives for the
	// JSON spec) so a failure can report WHERE: the returned Error enum
	// carries no position, the parser's tokenizer does (at or just past
	// the offending token). strip_jsonc keeps newlines, so the line/column
	// address the user's original file. The parser carries its own
	// allocator — the caller's context is never rewritten.
	p := json.make_parser(clean, spec = .JSON, parse_integers = true, allocator = a)
	parsed, perr := json.parse_value(&p)
	if perr != nil {
		return nil, platform.Wrapped{
			kind = .Invalid,
			// The message rides the parse allocator like every other
			// config error — it outlives this call, so scratch would
			// dangle it at the caller's next reset.
			msg = fmt.aprintf(
				"malformed JSON after comment stripping: %v at line %d, column %d (offset %d)",
				perr, p.tok.pos.line, p.tok.pos.column, p.tok.pos.offset,
				allocator = a,
			),
		}
	}
	return parsed, nil
}
