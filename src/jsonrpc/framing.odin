// Message framing for the JSON-RPC faces: Content-Length headers (the
// child<->parent RPC and the LSP client) and newline-delimited JSON (the
// MCP stdio face — the MCP specification delimits stdio messages by
// newlines and forbids embedded ones). Reader and Writer are
// function-pointer abstractions so real fds, in-memory pipes, and test
// fakes all use the same path.
package jsonrpc

import "core:fmt"
import "core:mem"
import "src:util"

Read_Err :: enum {
	None,
	Eof,       // orderly end of stream
	Closed,    // local close
	Framing,   // malformed header block
	Too_Large, // Content-Length above the connection-class cap
	Io,
}

DEFAULT_MAX_FRAME :: 64 * 1024 * 1024 // child MCP / LSP: 64 MiB; parent RPC uses 32 MiB
RPC_MAX_FRAME     :: 32 * 1024 * 1024

// Rx_Buf is an explicit byte accumulator (length <= capacity, data owned
// by the Reader).
Rx_Buf :: struct {
	data: []u8,
	n:    int,
}

// rx_reserve grows through the caller-supplied allocator: the Reader runs
// on host threads whose context allocator differs from the one that owns
// the buffer.
rx_reserve :: proc(b: ^Rx_Buf, want: int, a: mem.Allocator) {
	if want <= len(b.data) {
		return
	}
	grown := make([]u8, max(want, len(b.data) * 2), a)
	if b.n > 0 {
		mem.copy_non_overlapping(&grown[0], &b.data[0], b.n)
	}
	if b.data != nil {
		delete(b.data, a)
	}
	b.data = grown
}

rx_reset :: proc(b: ^Rx_Buf) {
	b.n = 0
}

rx_consume :: proc(b: ^Rx_Buf, count: int) {
	rest := b.n - count
	if rest > 0 {
		// Source and destination overlap inside the same buffer; copy (not
		// copy_non_overlapping) has the move semantics this needs.
		mem.copy(&b.data[0], &b.data[count], rest)
	}
	b.n = rest
}

Framing :: enum {
	Header,  // Content-Length headers: internal RPC, LSP
	Newline, // newline-delimited JSON: MCP stdio
}

Reader :: struct {
	read_fn:         proc(data: rawptr, buf: []u8) -> (int, Read_Err),
	data:            rawptr,
	max_frame_bytes: int,
	framing:         Framing,
	buf:             Rx_Buf,
	allocator:       mem.Allocator,
}

reader_init :: proc(r: ^Reader, read_fn: proc(data: rawptr, buf: []u8) -> (int, Read_Err), data: rawptr, max_frame_bytes: int, a := context.allocator) {
	r^ = {
		read_fn         = read_fn,
		data            = data,
		max_frame_bytes = max_frame_bytes,
		framing         = .Header,
		allocator       = a,
	}
}

// reader_init_ndjson prepares the MCP stdio framing: one message per
// line (a trailing CR is tolerated; embedded newlines are the sender's
// spec violation and end the frame early).
reader_init_ndjson :: proc(r: ^Reader, read_fn: proc(data: rawptr, buf: []u8) -> (int, Read_Err), data: rawptr, max_frame_bytes: int, a := context.allocator) {
	reader_init(r, read_fn, data, max_frame_bytes, a)
	r.framing = .Newline
}

reader_destroy :: proc(r: ^Reader) {
	if r.buf.data != nil {
		delete(r.buf.data, r.allocator)
	}
	r^ = {}
}

// fill reads at least one more byte into the buffer (growing as needed).
fill :: proc(r: ^Reader) -> Read_Err {
	rx_reserve(&r.buf, r.buf.n + 512, r.allocator)
	n, err := r.read_fn(r.data, r.buf.data[r.buf.n:])
	if n > 0 {
		r.buf.n += n
		return .None
	}
	// A read_fn reports zero bytes only together with an error; a
	// progress-less success would spin every read loop forever, so it
	// folds into .Io — the same guard write_all applies to the write side.
	if err == .None {
		return .Io
	}
	return err
}

// read_frame returns the next complete body, allocated from `a`. Whatever
// follows the frame stays buffered for the next call.
read_frame :: proc(r: ^Reader, a: mem.Allocator) -> (body: []u8, err: Read_Err) {
	if r.framing == .Newline {
		return read_line_frame(r, a)
	}
	header_end := 0
	content_length := -1

	for {
		he, cl, ok := try_parse_header(r.buf.data[:r.buf.n])
		if ok == 1 {
			header_end = he
			content_length = cl
			break
		}
		if ok == -1 {
			rx_reset(&r.buf)
			return nil, .Framing
		}
		// A peer that never sends the header separator must hit the frame
		// cap, not grow the buffer unbounded (same gate as the newline
		// framing below).
		if r.buf.n > r.max_frame_bytes {
			rx_reset(&r.buf)
			return nil, .Too_Large
		}
		if ferr := fill(r); ferr != .None {
			if ferr == .Eof && r.buf.n == 0 {
				return nil, .Eof
			}
			return nil, ferr
		}
	}

	if content_length > r.max_frame_bytes {
		rx_reset(&r.buf)
		return nil, .Too_Large
	}
	total := header_end + content_length
	for r.buf.n < total {
		rx_reserve(&r.buf, max(r.buf.n + 512, total), r.allocator)
		n, rerr := r.read_fn(r.data, r.buf.data[r.buf.n:total])
		if n > 0 {
			r.buf.n += n
			continue
		}
		if rerr != .None {
			return nil, rerr
		}
		// Same progress-less guard as fill: zero bytes with no error
		// would spin this loop forever.
		return nil, .Io
	}

	body = make([]u8, content_length, a)
	if content_length > 0 {
		mem.copy_non_overlapping(&body[0], &r.buf.data[header_end], content_length)
	}
	rx_consume(&r.buf, total)
	return body, .None
}

// read_line_frame is the newline-delimited read: the body is one line
// without its terminator; a trailing CR is stripped.
read_line_frame :: proc(r: ^Reader, a: mem.Allocator) -> (body: []u8, err: Read_Err) {
	for {
		nl := find_newline(r.buf.data[:r.buf.n])
		if nl >= 0 {
			end := nl
			if end > 0 && r.buf.data[end - 1] == '\r' {
				end -= 1
			}
			if end > r.max_frame_bytes {
				rx_reset(&r.buf)
				return nil, .Too_Large
			}
			body = make([]u8, end, a)
			if end > 0 {
				mem.copy_non_overlapping(&body[0], &r.buf.data[0], end)
			}
			rx_consume(&r.buf, nl + 1)
			return body, .None
		}
		if r.buf.n > r.max_frame_bytes {
			rx_reset(&r.buf)
			return nil, .Too_Large
		}
		if ferr := fill(r); ferr != .None {
			if ferr == .Eof && r.buf.n == 0 {
				return nil, .Eof
			}
			// A partial line at EOF is not a message.
			return nil, ferr
		}
	}
}

find_newline :: proc(buf: []u8) -> int {
	for i := 0; i < len(buf); i += 1 {
		if buf[i] == '\n' {
			return i
		}
	}
	return -1
}

// try_parse_header returns (header_end, content_length, 1) when a full
// header block with a valid Content-Length is buffered, (0, 0, 0) when more
// bytes are needed, and (_, _, -1) on a malformed header block.
try_parse_header :: proc(buf: []u8) -> (header_end: int, content_length: int, ok: int) {
	sep := find_sub_str(buf, HEADER_SEP)
	if sep < 0 {
		return 0, 0, 0
	}
	header_end = sep + len(HEADER_SEP)

	headers := buf[:sep]
	content_length = -1
	line_start := 0
	for i := 0; i <= len(headers); i += 1 {
		if i == len(headers) || headers[i] == '\n' {
			line := headers[line_start:i]
			if len(line) > 0 && line[len(line) - 1] == '\r' {
				line = line[:len(line) - 1]
			}
			if len(line) > 0 {
				colon := find_sub_str(line, COLON_SEP)
				if colon <= 0 {
					return 0, 0, -1
				}
				value := trim_space(string(line[colon + 1:]))
				if util.ascii_equal_ci(trim_space(string(line[:colon])), "content-length") {
					n, valid := parse_decimal(value)
					if !valid {
						return 0, 0, -1
					}
					if content_length != -1 {
						return 0, 0, -1 // duplicate header
					}
					content_length = n
				}
			}
			line_start = i + 1
		}
	}
	if content_length < 0 {
		return 0, 0, -1
	}
	return header_end, content_length, 1
}

HEADER_SEP :: string("\r\n\r\n")
COLON_SEP :: string(":")

find_sub_str :: proc(haystack: []u8, needle: string) -> int {
	if len(needle) == 0 || len(haystack) < len(needle) {
		return -1
	}
	for i := 0; i + len(needle) <= len(haystack); i += 1 {
		match := true
		for j := 0; j < len(needle); j += 1 {
			if haystack[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

trim_space :: proc(s: string) -> string {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') {
		start += 1
	}
	end := len(s)
	for end > start && (s[end - 1] == ' ' || s[end - 1] == '\t') {
		end -= 1
	}
	return s[start:end]
}

parse_decimal :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n := 0
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		// Bound before the multiply: 20-digit inputs would overflow i64,
		// wrap negative, and slip past the post-multiply check.
		if n > (1 << 40) / 10 {
			return 0, false
		}
		n = n * 10 + int(c - '0')
		if n > 1 << 40 {
			return 0, false
		}
	}
	return n, true
}

// ---------------------------------------------------------------------------

Writer :: struct {
	write_fn: proc(data: rawptr, buf: []u8) -> (int, Read_Err),
	data:     rawptr,
	framing:  Framing,
}

writer_init :: proc(w: ^Writer, write_fn: proc(data: rawptr, buf: []u8) -> (int, Read_Err), data: rawptr) {
	w^ = {
		write_fn = write_fn,
		data     = data,
		framing  = .Header,
	}
}

// writer_init_ndjson prepares the MCP stdio writer: the body followed by
// one newline (the serializer emits single-line JSON).
writer_init_ndjson :: proc(w: ^Writer, write_fn: proc(data: rawptr, buf: []u8) -> (int, Read_Err), data: rawptr) {
	writer_init(w, write_fn, data)
	w.framing = .Newline
}

write_frame :: proc(w: ^Writer, body: []u8) -> Read_Err {
	if w.framing == .Newline {
		if err := write_all(w, body); err != .None {
			return err
		}
		nl := []u8{'\n'}
		return write_all(w, nl)
	}
	// The label (16) plus a 19-digit i64 plus the separator (4) fit forty
	// bytes — the header needs no allocator at all.
	hdr_buf: [40]u8
	header := fmt.bprintf(hdr_buf[:], "Content-Length: %d\r\n\r\n", len(body))
	if err := write_all(w, transmute([]u8)header); err != .None {
		return err
	}
	if len(body) > 0 {
		return write_all(w, body)
	}
	return .None
}

write_all :: proc(w: ^Writer, data: []u8) -> Read_Err {
	sent := 0
	for sent < len(data) {
		n, err := w.write_fn(w.data, data[sent:])
		if n > 0 {
			sent += n
		}
		if err != .None {
			return err
		}
		if n <= 0 {
			return .Io
		}
	}
	return .None
}
