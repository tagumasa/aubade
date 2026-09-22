// Index-side name matching: the one implementation of the symbol_find
// matching rule (exact by default, `*` glob for discovery), shared by the
// daemon's chain verification over index rows and the workspace/symbol
// top-up filter so every answer source applies the same semantics. The
// forest-side Name_Path_Matcher stays exact-only — glob discovery is an
// index-tool feature, not an edit-resolution one.
package symbol

import "core:strings"

// name_component_matches compares one name-path component. Without a `*` in
// the pattern it is an exact comparison folding ASCII case (mirroring the
// store's COLLATE NOCASE); with one it is a `*`-only glob where every other
// byte — including `?`, `%`, and `_` — matches literally. On the index path
// `*` is always a wildcard; names cannot contain it.
name_component_matches :: proc(pattern, actual: string) -> bool {
	if strings.contains(pattern, "*") {
		return glob_ascii_fold_match(pattern, actual)
	}
	if len(pattern) != len(actual) {
		return false
	}
	for i := 0; i < len(pattern); i += 1 {
		if fold_ascii(pattern[i]) != fold_ascii(actual[i]) {
			return false
		}
	}
	return true
}

// glob_ascii_fold_match matches `s` against a `*`-only glob `pat` with ASCII
// case folding. Iterative with a single backtracking star (the classic
// two-pointer form), so a pathological many-star pattern stays linear-ish
// and never recurses.
glob_ascii_fold_match :: proc(pat, s: string) -> bool {
	pi := 0
	si := 0
	star := -1
	mark := 0
	for si < len(s) {
		if pi < len(pat) && pat[pi] == '*' {
			star = pi
			pi += 1
			mark = si
		} else if pi < len(pat) && fold_ascii(pat[pi]) == fold_ascii(s[si]) {
			pi += 1
			si += 1
		} else if star >= 0 {
			pi = star + 1
			mark += 1
			si = mark
		} else {
			return false
		}
	}
	for pi < len(pat) && pat[pi] == '*' {
		pi += 1
	}
	return pi == len(pat)
}

fold_ascii :: proc(b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + ('a' - 'A')
	}
	return b
}

// index_topup_row_matches applies the index matching rule to one
// workspace/symbol row: the innermost component must match the row's name,
// and a two-segment relative pattern additionally matches the container. An
// anchored pattern or one deeper than two segments cannot be verified from
// SymbolInformation's single container level, so no top-up row qualifies at
// all — the index itself (chain-verified against L0 rows) remains the only
// answer source for those forms.
index_topup_row_matches :: proc(comps: []string, anchored: bool, name, container: string) -> bool {
	if anchored || len(comps) > 2 {
		return false
	}
	if !name_component_matches(comps[len(comps)-1], name) {
		return false
	}
	if len(comps) == 2 {
		return name_component_matches(comps[0], container)
	}
	return true
}
