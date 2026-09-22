// The project-create stdin reader: line splitting (CRLF included) and
// the hard line budget beyond which the reader stops growing and reports
// overflow instead of ballooning on a piped firehose.
package tests

import "core:testing"

import "src:cli"

@(test)
cli_reader_take_line_splits :: proc(t: ^testing.T) {
	buf := make([dynamic]u8, 0, 16, context.allocator)
	defer delete(buf)
	payload: string = "y\r\nno\nrest"
	append(&buf, ..transmute([]u8)payload)

	r := cli.Line_Reader{buf = buf}
	line, found := cli.reader_take_line(&r)
	testing.expectf(t, found && line == "y", "first line: found=%v line=%q", found, line)
	if found {
		delete(line, context.allocator)
	}
	line, found = cli.reader_take_line(&r)
	testing.expectf(t, found && line == "no", "second line: found=%v line=%q", found, line)
	if found {
		delete(line, context.allocator)
	}
	line, found = cli.reader_take_line(&r)
	testing.expectf(t, !found, "no third line before more input: found=%v", found)

	// At eof the unterminated remainder becomes the final line; an empty
	// buffer at eof reports nothing (the caller treats it as "").
	r.eof = true
	line, found = cli.reader_take_line(&r)
	testing.expectf(t, found && line == "rest", "eof remainder: found=%v line=%q", found, line)
	if found {
		delete(line, context.allocator)
	}
	line, found = cli.reader_take_line(&r)
	testing.expectf(t, !found, "empty at eof: found=%v", found)
}

@(test)
cli_reader_budget_boundary :: proc(t: ^testing.T) {
	buf := make([dynamic]u8, 0, cli.LINE_INPUT_LIMIT, context.allocator)
	defer delete(buf)
	r := cli.Line_Reader{buf = buf}

	resize(&r.buf, cli.LINE_INPUT_LIMIT - 1)
	testing.expect(t, !cli.reader_over_budget(&r), "one byte under the budget still reads")
	resize(&r.buf, cli.LINE_INPUT_LIMIT)
	testing.expect(t, cli.reader_over_budget(&r), "at the budget with no newline the reader refuses to grow")
}
