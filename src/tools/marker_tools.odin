// The three non-callable capability markers (kept non-callable by
// design). They register like any tool so a config can include them by
// name, carry no params, never edit, and answer the fixed text "marker".
// The prompt templates consume their MARKER names (ToolMarkerSymbolicRead
// &c.) through the available_markers set, which the render paths fill
// from the folded tool list via marker_name_for.
package tools

import "core:sort"

marker_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	return text_result(ctx, "marker")
}

marker_symbolic_read :: Tool_Desc{
	name        = "marker_symbolic_read",
	title       = "Symbolic read marker",
	description = "Marker: symbolic code reading capability",
	can_edit    = false,
	optional    = true,
	category    = .Marker,
	params      = nil,
	apply       = marker_apply,
}

marker_can_edit :: Tool_Desc{
	name        = "marker_can_edit",
	title       = "Can edit marker",
	description = "Marker: file editing capability",
	can_edit    = false,
	optional    = true,
	category    = .Marker,
	params      = nil,
	apply       = marker_apply,
}

marker_symbolic_edit :: Tool_Desc{
	name        = "marker_symbolic_edit",
	title       = "Symbolic edit marker",
	description = "Marker: symbolic code editing capability",
	can_edit    = false,
	optional    = true,
	category    = .Marker,
	params      = nil,
	apply       = marker_apply,
}

// The marker tools' prompt-marker names, one row per marker: the marker
// vocabulary the prompt templates test against. Rows reference their
// tool by Tool_ID, so a rename follows the registry and a new marker is
// one row here plus its Tool_Desc.
MARKER_ROWS :: []struct{
	id:     Tool_ID,
	marker: string,
}{
	{.Marker_Symbolic_Read, "ToolMarkerSymbolicRead"},
	{.Marker_Can_Edit,      "ToolMarkerCanEdit"},
	{.Marker_Symbolic_Edit, "ToolMarkerSymbolicEdit"},
}

// marker_name_for maps a marker tool's wire name to its marker name (""
// for every non-marker tool).
marker_name_for :: proc(tool_name: string) -> string {
	table := TOOLS
	for row in MARKER_ROWS {
		if table[int(row.id)].name == tool_name {
			return row.marker
		}
	}
	return ""
}

// visible_names materializes the folded visibility into the sorted tool
// names and, among them, the MARKER names the prompt templates test for.
// Both render paths (the session's initialize instructions and the
// hostless `prompt render`) share this so the exposed-set shape cannot
// drift between hosts.
visible_names :: proc(vis: Visibility, a := context.allocator) -> (names: []string, markers: []string) {
	// Materialize the constant table before indexing (the compiler
	// rejects variable indexing straight into constant data).
	table := TOOLS
	unsorted := make([dynamic]string, 0, len(table), context.temp_allocator)
	marker_dyn := make([dynamic]string, 0, 3, context.temp_allocator)
	for idx in 0..<len(table) {
		if cast(Tool_ID)idx in vis {
			append(&unsorted, table[idx].name)
			if m := marker_name_for(table[idx].name); m != "" {
				append(&marker_dyn, m)
			}
		}
	}
	sort.quick_sort(unsorted[:])
	names = make([]string, len(unsorted), a)
	copy(names, unsorted[:])
	markers = make([]string, len(marker_dyn), a)
	copy(markers, marker_dyn[:])
	delete(unsorted)
	delete(marker_dyn)
	return names, markers
}
