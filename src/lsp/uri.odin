// file-URI handling on the client side: decoding server-reported URIs into
// paths, and enriching symbol locations with absolute/relative paths
// resolved against the client's workspace root. Outgoing URIs are built by
// symbol.file_uri (the single encoder — the root URI published at
// initialize and every per-file URI go through it, so both sides of a
// round trip agree on the form).
package lsp

import "core:strings"

import "src:platform"
import "src:symbol"
import "src:util"

// uri_to_path decodes a file:// URI into a filesystem path, percent
// escapes included (allocated in `a`). Non-file schemes report !ok —
// callers treat those as unresolvable rather than guessing.
uri_to_path :: proc(uri: string, a := context.allocator) -> (path: string, ok: bool) {
	prefix :: "file://"
	if !strings.has_prefix(uri, prefix) {
		return "", false
	}
	rest := uri[len(prefix):]
	out := make([dynamic]u8, 0, len(rest), a)
	i := 0
	for i < len(rest) {
		c := rest[i]
		if c == '%' && i + 2 < len(rest) {
			hi := util.hex_digit_value(rest[i + 1])
			lo := util.hex_digit_value(rest[i + 2])
			if hi >= 0 && lo >= 0 {
				append(&out, u8(hi * 16 + lo))
				i += 3
				continue
			}
		}
		append(&out, c)
		i += 1
	}
	when ODIN_OS == .Windows {
		// "file:///C:/x" carries a slash before the drive letter; the
		// platform path form has none.
		if len(out) >= 3 && out[0] == '/' && is_ascii_letter(out[1]) && out[2] == ':' {
			for j := 0; j < len(out) - 1; j += 1 {
				out[j] = out[j + 1]
			}
			resize(&out, len(out) - 1)
		} else if len(out) > 0 && out[0] != '/' {
			// The authority form (file://server/share/x): the host sits
			// before the first path slash — a UNC share, which only this
			// platform grounds. The path keeps forward slashes, mirroring
			// the drive form above (Win32 accepts both separators, and
			// the root-prefix compares normalize anyway).
			resize(&out, len(out) + 2)
			for j := len(out) - 1; j >= 2; j -= 1 {
				out[j] = out[j - 2]
			}
			out[0] = '/'
			out[1] = '/'
		}
	} else {
		// A non-empty authority is the UNC form; there is no share to
		// resolve it against here, so report it unresolvable rather than
		// return a relative-looking path that happens to decode. The one
		// sanctioned exception is the local machine: RFC 8089 reads a
		// "localhost" authority exactly as if no authority were present
		// (hosts compare case-insensitively), so its path decodes like a
		// plain local one.
		if len(out) > 0 && out[0] != '/' {
			authority_end := 0
			for authority_end < len(out) && out[authority_end] != '/' {
				authority_end += 1
			}
			if authority_end == len(out) || !strings.equal_fold(string(out[:authority_end]), "localhost") {
				delete(out)
				return "", false
			}
			for j := authority_end; j < len(out); j += 1 {
				out[j - authority_end] = out[j]
			}
			resize(&out, len(out) - authority_end)
		}
	}
	if len(out) == 0 {
		delete(out)
		return "", false
	}
	return string(out[:]), true
}

is_ascii_letter :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// rel_path_for_root strips the workspace-root prefix from an absolute path
// (allocated views; the caller clones). The prefix compare carries the
// filesystem's case sensitivity and both '/' and '\' count as the
// separator (decoded URIs use '/', platform roots may use '\'). Empty
// when the path is outside the root.
rel_path_for_root :: proc(root, abs_path: string) -> string {
	if root == "" {
		return ""
	}
	if rel, ok := platform.strip_root_prefix(abs_path, root); ok {
		return rel
	}
	return ""
}

// location_enrich fills a location's abs_path/rel_path from its file URI
// and the client's workspace root (strings cloned into `a`). Locations
// already carrying an absolute path, and non-file URIs, are left alone.
location_enrich :: proc(cl: ^Client, loc: ^symbol.Location, a := context.allocator) {
	if loc.abs_path != "" {
		return
	}
	path, ok := uri_to_path(loc.uri, a)
	if !ok {
		return
	}
	loc.abs_path = path
	if rel := rel_path_for_root(cl.root_abs, path); rel != "" {
		loc.rel_path = strings.clone(rel, a)
	}
}
