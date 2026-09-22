package platform

import "core:os"

Write_Port :: proc(user: rawptr, data: []u8) -> (n: int, err: Err)

// write_all_with drives write_fn until every byte of data is written. A
// port that reports n <= 0 with no error is a stall and fails as .Internal.
write_all_with :: proc(user: rawptr, data: []u8, write_fn: Write_Port) -> Err {
	sent := 0
	for sent < len(data) {
		n, err := write_fn(user, data[sent:])
		if n > 0 {
			sent += n
		}
		if err != nil {
			return err
		}
		if n <= 0 {
			return .Internal
		}
	}
	return nil
}

file_write_port :: proc(user: rawptr, data: []u8) -> (int, Err) {
	f := cast(^os.File)user
	n, werr := os.write(f, data)
	if werr != nil {
		return n, .Internal
	}
	return n, nil
}

// write_all persists the whole buffer or fails: the count that a write can
// report alongside an error is a partial delivery, and callers must not
// mistake it for a complete file. An empty buffer is an immediate success.
write_all :: proc(f: ^os.File, data: []u8) -> Err {
	return write_all_with(f, data, file_write_port)
}
