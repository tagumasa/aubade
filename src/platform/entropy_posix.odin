#+build linux, darwin

// random_bytes (POSIX): /dev/urandom, falling back to the shared hash mix.
package platform

import "core:os"

random_bytes :: proc(buf: []u8) -> bool {
	f, err := os.open("/dev/urandom", {.Read}, os.Permissions{.Read_User})
	if err == nil {
		n, rerr := os.read(f, buf)
		os.close(f)
		if rerr == nil && n == len(buf) {
			return true
		}
	}
	return random_bytes_fallback(buf)
}
