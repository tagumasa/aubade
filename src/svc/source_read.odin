// The one editor-or-disk source read every LSP producer shares. The
// ownership flag and the free path are decided by the SAME predicate here —
// the duplicated inline versions gated the disk fallback on
// `contents == ""`, which flipped the buffer ownership (editor clone
// replaced by arena bytes) while the caller's defer kept freeing through
// the editor's allocator.
package svc

import "core:mem"

import "src:editor"

// read_source_contents resolves the bytes a producer should see for one
// file: a live editor view hides the disk, so the read goes through the
// editor when one exists — the clone (or, with no buffer open, the fresh
// disk snapshot editor_read_file takes itself) belongs to the editor's
// allocator — and only a read ERROR falls back to the direct disk read on
// `arena`. The caller frees `contents` through ed.allocator exactly when
// from_editor is true; the flag IS the ownership.
read_source_contents :: proc(
	ed:   ^editor.Editor,
	rel:  string,
	abs:  string,
	arena: mem.Allocator,
) -> (contents: string, from_editor: bool, read_err: string) {
	if ed != nil {
		read, rerr, _ := editor.editor_read_file(ed, rel)
		if rerr == .None {
			return read, true, ""
		}
	}
	disk, rerr := read_source_file(abs, arena)
	if rerr != "" {
		return "", false, rerr
	}
	return disk, false, ""
}
