#+build windows

// random_bytes (Windows): BCryptGenRandom with the system-preferred RNG,
// falling back to the shared hash mix.
package platform

import "core:sys/windows"

// No algorithm handle is needed with this flag.
BCRYPT_USE_SYSTEM_PREFERRED_RNG :: windows.ULONG(0x2)

random_bytes :: proc(buf: []u8) -> bool {
	if len(buf) > 0 && windows.BCryptGenRandom(nil, cast([^]u8)&buf[0], u32(len(buf)), BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0 {
		return true
	}
	return random_bytes_fallback(buf)
}
