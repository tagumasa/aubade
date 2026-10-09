// Tests for util.hash64_words (the word-block FNV-1a fingerprint): pinned
// goldens, determinism, seed sensitivity, single-bit input flips, and
// prefix-length distinctness through the byte tail.
package tests

import "core:testing"

import "src:util"

HASH_TEST_FIXTURE :: "aubade-hash-probe"

@(test)
hash64_words_goldens :: proc(t: ^testing.T) {
	// The values pin the algorithm: nothing hashed with this function is
	// persisted, so a deliberate algorithm change updates them in the
	// same commit.
	testing.expect_value(
		t,
		util.hash64_words(HASH_TEST_FIXTURE, util.HASH64_FNV_OFFSET),
		u64(0x2c13e9469ae87e6d),
	)
	testing.expect_value(
		t,
		util.hash64_words("", util.HASH64_FNV_OFFSET),
		u64(0xf52a15e9a9b5e89b),
	)
}

@(test)
hash64_words_determinism_and_seed :: proc(t: ^testing.T) {
	h0 := util.hash64_words(HASH_TEST_FIXTURE, util.HASH64_FNV_OFFSET)
	testing.expect_value(
		t,
		util.hash64_words(HASH_TEST_FIXTURE, util.HASH64_FNV_OFFSET),
		h0,
	)
	testing.expect(t, util.hash64_words(HASH_TEST_FIXTURE, 0) != h0)
}

@(test)
hash64_words_input_bit_flips :: proc(t: ^testing.T) {
	s := "0123456789abcdefghijklmnopqrstuv" // 32 bytes
	buf: [32]u8
	for i in 0..<len(s) {
		buf[i] = s[i]
	}
	base := util.hash64_words(string(buf[:]), util.HASH64_FNV_OFFSET)
	masks := [8]u8{1, 2, 4, 8, 16, 32, 64, 128}
	for i in 0..<len(buf) {
		for m in masks {
			buf[i] = buf[i] ~ m
			flipped := util.hash64_words(
				string(buf[:]),
				util.HASH64_FNV_OFFSET,
			)
			buf[i] = buf[i] ~ m
			testing.expectf(t, flipped != base, "byte %d mask %d left the hash unchanged", i, m)
		}
	}
}

@(test)
hash64_words_prefix_lengths_distinct :: proc(t: ^testing.T) {
	s := "aubade-hash-probe" // 17 bytes: two words plus a one-byte tail
	seen: [18]u64
	for l in 0..<len(seen) {
		seen[l] = util.hash64_words(s[:l], util.HASH64_FNV_OFFSET)
	}
	for a in 0..<len(seen) {
		for b in a + 1..<len(seen) {
			testing.expectf(
				t,
				seen[a] != seen[b],
				"prefix lengths %d and %d collide",
				a,
				b,
			)
		}
	}
}
