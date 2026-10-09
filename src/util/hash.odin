// 64-bit string fingerprint: FNV-1a folded one round per 8-byte
// little-endian word (a byte tail folds bytewise), closed by a
// splitmix-style final mix. Outputs are in-process fingerprints only —
// nothing hashed with this function is persisted or crosses a process
// boundary, so the exact values may change with the algorithm.
package util

HASH64_FNV_OFFSET :: u64(0xcbf29ce484222325)
HASH64_FNV_PRIME :: u64(0x100000001b3)

hash64_words :: proc(s: string, seed: u64) -> u64 {
	h := seed
	n := len(s)
	i := 0
	for i + 8 <= n {
		lo := u64(s[i]) |
			(u64(s[i + 1]) << 8) |
			(u64(s[i + 2]) << 16) |
			(u64(s[i + 3]) << 24)
		hi := u64(s[i + 4]) |
			(u64(s[i + 5]) << 8) |
			(u64(s[i + 6]) << 16) |
			(u64(s[i + 7]) << 24)
		h = (h ~ (lo | (hi << 32))) * HASH64_FNV_PRIME
		i += 8
	}
	for i < n {
		h = (h ~ u64(s[i])) * HASH64_FNV_PRIME
		i += 1
	}
	h = h ~ (h >> 30)
	h = h * 0xbf58476d1ce4e5b9
	h = h ~ (h >> 27)
	h = h * 0x94d049bb133111eb
	h = h ~ (h >> 31)
	return h
}
