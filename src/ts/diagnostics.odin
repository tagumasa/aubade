// Syntax diagnostics over a parsed tree: one flat, position-ascending
// entry per ERROR node and per MISSING node. This is the syntax-only
// face — the damage a parse can prove — not a semantic checker.
//
// The walk visits every node. The cheap C error flag (node_has_error)
// cannot drive it: the flag is cost-based and a missing leaf carries no
// error cost, so a subtree damaged only by an inserted missing token
// reads as clean — pruning flag-clean subtrees would drop MISSING
// diagnostics. For callers that only need the ERROR signal,
// node_has_error(tree_root_node(tree)) stays the cheap predicate (the
// same flag Outline_Report.tree_has_error reports); it just cannot see
// MISSING nodes.
package ts

// Diagnostic_Kind closes the damage vocabulary: an ERROR node is source
// the parser could not fit into the grammar; a MISSING node is required
// syntax the parser inserted as absent. Missing leaves are zero-length,
// so a Missing diagnostic's start_byte equals its end_byte (the padding
// before the insertion point shifts both together).
Diagnostic_Kind :: enum {
	Error,
	Missing,
}

// Messages are fixed constants — one per kind, never formatted, never
// allocated per diagnostic — so a Diagnostic is a value record owning no
// memory and diagnostics_destroy releases only the array backing.
DIAG_MESSAGE_ERROR :: "Syntax error"
DIAG_MESSAGE_MISSING :: "Required syntax is missing"

// DIAGNOSTICS_MAX is the consumers' bound on a diagnostics answer, enforced
// by the serving face (the daemon's svc.doc/diagnostics): a source past it
// answers its first DIAGNOSTICS_MAX entries with an explicit truncated
// flag, never a silent cut. The walk itself is bounded by the parsed node
// count — at most one entry per node, and the caller gates the source
// size — so the bound caps the wire answer and the consumer's squiggle
// count, not walk safety.
DIAGNOSTICS_MAX :: 512

Diagnostic :: struct {
	start_byte: u32,
	end_byte:   u32,
	kind:       Diagnostic_Kind,
	message:    string, // one of the DIAG_MESSAGE_* constants
}

// diagnostics_tree walks a parsed tree and returns its diagnostics in
// ascending start-byte order. Ties keep the container first: emission is
// a pre-order walk, and a parent's span starts at or before its first
// child's — the same start-asc/end-desc order the outline candidates
// sort into. Results are allocated in `a` and owned by the caller:
// request arenas free_all them, other allocators use
// diagnostics_destroy. Zero diagnostics come back as nil.
diagnostics_tree :: proc(tree: Tree, a := context.allocator) -> []Diagnostic {
	if tree == nil {
		return nil
	}
	root := tree_root_node(tree)
	if node_is_null(root) {
		return nil
	}
	return diagnostics_walk(root, a)
}

// diagnostics_walk is iterative with an explicit stack, like the other
// walks in this package: pathological sources nest deeply enough that
// recursion overflows the thread stack. The walk is a bounded CPU pass
// over one tree (no blocking waits), so it carries no cancellation
// checkpoints. Children iterate as ALL children (node_child, not
// node_named_child): a missing token is often an anonymous symbol (a
// `}`, a `;`) that named-child iteration would never reach.
diagnostics_walk :: proc(root: Node, a := context.allocator) -> []Diagnostic {
	dyn := make([dynamic]Diagnostic, 0, 8, a)
	stack := make([dynamic]Node, 0, 16, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		cur := stack[len(stack) - 1]
		pop(&stack)
		if node_is_null(cur) {
			continue
		}
		// A node is never both: a missing leaf carries the expected
		// token's symbol, not the error symbol.
		if node_is_error(cur) {
			append_diagnostic(&dyn, node_start_byte(cur), node_end_byte(cur), .Error)
		} else if node_is_missing(cur) {
			append_diagnostic(&dyn, node_start_byte(cur), node_end_byte(cur), .Missing)
		}
		count := node_child_count(cur)
		// Push in reverse so pops visit children in source order.
		for i := int(count) - 1; i >= 0; i -= 1 {
			append(&stack, node_child(cur, u32(i)))
		}
	}
	if len(dyn) == 0 {
		// Zero diagnostics report as nil — the clean case carries no
		// allocation behind it. The dynamic carries its own allocator.
		delete(dyn)
		return nil
	}
	return dyn[:]
}

// append_diagnostic emits one entry unless an identical one is already
// present. An unplaceable token makes tree-sitter stack an outer ERROR on
// an inner ERROR with the same extent; both describe the same damage, and
// emitting both would draw one squiggle per copy at the consumer.
// Nested-but-different spans stay — a wrapping ERROR region is its own
// information. The output is start-ascending, so duplicates can only sit
// inside the tail group of entries sharing the candidate's start byte.
append_diagnostic :: proc(dyn: ^[dynamic]Diagnostic, start_byte, end_byte: u32, kind: Diagnostic_Kind) {
	for i := len(dyn) - 1; i >= 0; i -= 1 {
		if dyn[i].start_byte != start_byte {
			break
		}
		if dyn[i].end_byte == end_byte && dyn[i].kind == kind {
			return
		}
	}
	append(dyn, Diagnostic{
		start_byte = start_byte,
		end_byte   = end_byte,
		kind       = kind,
		message    = kind == .Error ? DIAG_MESSAGE_ERROR : DIAG_MESSAGE_MISSING,
	})
}

// diagnostics_destroy frees an array built by diagnostics_tree for
// allocators that need explicit deletes (request arenas skip this —
// free_all covers it). Diagnostics own no memory; only the backing is
// released. Pass the allocator that produced the array (the default
// matches diagnostics_tree's own default).
diagnostics_destroy :: proc(diags: []Diagnostic, a := context.allocator) {
	if diags != nil {
		delete(diags, a)
	}
}
