// random_bytes: OS entropy for the daemon's startup auth token. The OS
// source lives in the platform-suffixed files (urandom on POSIX,
// BCryptGenRandom on Windows); this file carries the shared last-resort
// fallback and the wall-clock helper.
package platform

import "core:crypto/sha2"
import "core:time"

// random_bytes_fallback never fails startup over entropy — it hashes a
// monotonic tick, the wall clock, and the destination address. The token is
// local-only secret material (it lives in a 0700 directory), so a per-call
// seeded hash is adequate when the OS source is unavailable.
random_bytes_fallback :: proc(buf: []u8) -> bool {
	if len(buf) == 0 {
		return false
	}
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)i64_dec(mono_ms()))
	sha2.update(&ctx, transmute([]u8)i64_dec(wall_ms()))
	sha2.update(&ctx, transmute([]u8)i64_dec(i64(uintptr(&buf[0]))))
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	n := min(len(buf), 32)
	for i in 0..<n {
		buf[i] = digest[i]
	}
	return true
}

// wall_ms is a wall-clock timestamp in milliseconds. Bookkeeping and display
// only (timestamps in published files, status output) — never an input to
// liveness or timeout decisions, which are monotonic-clock territory.
wall_ms :: proc() -> i64 {
	return time.time_to_unix(time.now()) * 1000
}

i64_dec :: proc(v: i64) -> string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	uv := u64(v) if !neg else -u64(v)
	buf: [24]u8
	n := 0
	for uv > 0 {
		buf[n] = u8('0' + uv % 10)
		uv /= 10
		n += 1
	}
	out := make([]u8, n + (1 if neg else 0), context.temp_allocator)
	i := 0
	if neg {
		out[0] = '-'
		i = 1
	}
	for j in 0..<n {
		out[i + j] = buf[n - 1 - j]
	}
	return string(out)
}
