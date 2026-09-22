// fold_visibility: the single visibility engine. Hosts (the MCP child
// and hostless consumers like prompt render) fold their config stack's
// inclusion layers over the capability-satisfiable base; nobody
// re-implements the check inline. Layer semantics: a fixed_tools layer
// replaces the whole set, otherwise
// included_optional_tools add and excluded_tools remove; unknown names
// (and capability-unsatisfiable ones) warn and skip; the read_only strip
// runs last. Optional tools sit outside the base until a layer includes
// them.
package tools

import "core:fmt"

// Visibility_Layer is one config level's inclusion declaration (the
// adapter shape of config.Tool_Inclusion; hosts convert their stack
// entries so the fold stays free of the config package).
Visibility_Layer :: struct {
	excluded:          []string,
	included_optional: []string,
	fixed:             []string,
}

// Fold_Warnings collects the warn-and-skip notices; the caller owns the
// list and the strings (allocated through the fold's `a`, freed with the
// same allocator — nil drops the notices).
Fold_Warnings :: ^[dynamic]string

fold_visibility :: proc(
	available: bit_set[Cap],
	read_only: bool,
	layers: []Visibility_Layer,
	warnings: Fold_Warnings,
	a := context.allocator,
) -> Visibility {
	table := TOOLS
	set: Visibility
	for i in 0..<len(table) {
		tid := cast(Tool_ID)i
		if table[i].optional {
			continue // outside the base until a layer includes them
		}
		if visible(tid, available) {
			set |= {tid}
		}
	}

	for layer in layers {
		if len(layer.fixed) > 0 {
			// Fixed mode replaces the set outright; names that do not
			// resolve (or need unavailable capabilities) warn and drop.
			replacement: Visibility
			for name in layer.fixed {
				tid, ok := fold_by_name(name, available, warnings, "fixed_tools", a)
				if ok {
					replacement |= {tid}
				}
			}
			set = replacement
			continue
		}
		for name in layer.included_optional {
			tid, ok := fold_by_name(name, available, warnings, "included_optional_tools", a)
			if ok {
				set |= {tid}
			}
		}
		for name in layer.excluded {
			tid, ok := fold_by_name(name, available, warnings, "excluded_tools", a)
			if ok {
				set = set - {tid}
			}
		}
	}

	if read_only {
		for i in 0..<len(table) {
			if table[i].can_edit {
				set = set - {cast(Tool_ID)i}
			}
		}
	}
	return set
}

// fold_by_name resolves one declared tool name; unknown or
// capability-unsatisfiable names warn and report not-ok.
fold_by_name :: proc(name: string, available: bit_set[Cap], warnings: Fold_Warnings, list_name: string, a := context.allocator) -> (Tool_ID, bool) {
	tid, found := find_by_name(name)
	if !found {
		fold_warn(warnings, fmt.aprintf("unknown tool name in %s, skipping: %s", list_name, name, allocator = a))
		return tid, false
	}
	if !visible(tid, available) {
		fold_warn(warnings, fmt.aprintf("tool not available in this session, skipping: %s", name, allocator = a))
		return tid, false
	}
	return tid, true
}

fold_warn :: proc(warnings: Fold_Warnings, msg: string) {
	if warnings != nil {
		append(warnings, msg)
	}
}
