// endpoint.json: the daemon's discovery + auth publication — {pid, port,
// started_at, token}. Written once at startup, atomically (tmp+rename), and
// removed by the owning daemon's cleanup after its resources are released;
// children only ever read it. started_at is wall-clock bookkeeping for
// status display — liveness decisions never read it.
package daemon

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "src:jsonutil"
import "src:platform"
import "src:util"

TOKEN_BYTES :: 16 // published as 32 hex characters

Endpoint_Info :: struct {
	pid:           int,
	port:          int,
	started_at_ms: i64,
	token:         string, // read_endpoint clones it into the caller's allocator
}

// gen_token draws the per-daemon auth token (svc.hello checks it).
gen_token :: proc(a := context.allocator) -> (string, bool) {
	buf: [TOKEN_BYTES]u8
	if !platform.random_bytes(buf[:]) {
		return "", false
	}
	hex := "0123456789abcdef"
	out := make([]u8, TOKEN_BYTES * 2, a)
	for i in 0..<TOKEN_BYTES {
		out[i * 2]     = hex[buf[i] >> 4]
		out[i * 2 + 1] = hex[buf[i] & 0xF]
	}
	return string(out), true
}

// read_endpoint parses the publication. A missing, truncated, or malformed
// file reads as "not up" so callers fall back to the spawn race.
read_endpoint :: proc(path: string, a := context.allocator) -> (info: Endpoint_Info, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(data) == 0 {
		return {}, false
	}
	// Depth/encoding guard: a corrupt publication reads as "not up"
	// (the spawn-race fallback), never a parser crash.
	if !util.json_sanity_ok(data) {
		return {}, false
	}
	value, perr := json.parse_bytes(data, spec = .JSON, parse_integers = true, allocator = a)
	if perr != nil || value == nil {
		return {}, false
	}
	info, ok = endpoint_from_value(value, a)
	json.destroy_value(value, a)
	return info, ok
}

endpoint_from_value :: proc(value: json.Value, a := context.allocator) -> (Endpoint_Info, bool) {
	info: Endpoint_Info

	pid_v, pid_ok := jsonutil.obj_get(value, "pid")
	port_v, port_ok := jsonutil.obj_get(value, "port")
	token_v, token_ok := jsonutil.obj_get(value, "token")
	if !pid_ok || !port_ok || !token_ok {
		return {}, false
	}
	#partial switch x in pid_v {
	case json.Integer:
		info.pid = int(x)
	case:
		return {}, false
	}
	#partial switch x in port_v {
	case json.Integer:
		if x <= 0 || x > 65535 {
			return {}, false
		}
		info.port = int(x)
	case:
		return {}, false
	}
	#partial switch x in token_v {
	case json.String:
		if len(string(x)) == 0 {
			return {}, false
		}
		info.token = strings.clone(string(x), a)
	case:
		return {}, false
	}
	if v, found := jsonutil.obj_get(value, "started_at"); found {
		#partial switch x in v {
		case json.Integer:
			info.started_at_ms = x
		case:
		}
	}
	return info, true
}

// write_endpoint publishes the info atomically: readers see either the
// previous complete file or the new one, never a torn write, and the
// publication survives a crash (data fsync, rename, directory fsync). The
// sole call site (daemon startup, under the spawn lock) is a single writer,
// which is what atomic_write's stable temp name requires.
write_endpoint :: proc(path: string, info: Endpoint_Info) -> bool {
	// NOTE: fmt.aprintf treats '{' as a format directive; braces stay out of
	// the format string.
	body := strings.concatenate(
		{
			"{",
			fmt.aprintf("\"pid\": %d, \"port\": %d, \"started_at\": %d", info.pid, info.port, info.started_at_ms, allocator = context.temp_allocator),
			", \"token\": \"",
			info.token,
			"\"}",
		},
		context.temp_allocator,
	)
	return platform.atomic_write(path, transmute([]u8)body, {.Read_User, .Write_User}) == nil
}
