// Visibility-table tests for the single fold engine: capability base,
// optional inclusion, exclusion, fixed-set replacement, the read_only
// strip, and the warn-and-skip rules for unknown and unsatisfiable
// names. visibility_set (no layers) must agree with the empty fold.
package tests

import "core:mem"
import "core:strings"
import "core:testing"
import "src:tools"

@(test)
fold_base_and_visibility_set_agree :: proc(t: ^testing.T) {
	with_all := tools.visibility_set({.Project, .Svc, .Editor, .Shell})
	fold_all := tools.fold_visibility({.Project, .Svc, .Editor, .Shell}, false, nil, nil)
	testing.expect_value(t, fold_all, with_all)

	// The config-less set covers every non-optional tool whose needs are
	// met; the onboarding tools ride along without capabilities.
	testing.expect(t, tools.Tool_ID.Onboarding_Check in with_all)
	testing.expect(t, tools.Tool_ID.Onboarding_Read_Instructions in with_all)
	testing.expect(t, tools.Tool_ID.Shell_Run in with_all)
	testing.expect(t, tools.Tool_ID.File_Read in with_all)
}

@(test)
fold_exclusion_and_optional_inclusion :: proc(t: ^testing.T) {
	caps := bit_set[tools.Cap]{.Project, .Svc, .Editor}

	// Exclusions remove tools from the base.
	excluded := tools.fold_visibility(caps, false, []tools.Visibility_Layer{
		{excluded = []string{"file_write", "symbol_move"}},
	}, nil)
	testing.expect(t, tools.Tool_ID.File_Read in excluded)
	testing.expect(t, tools.Tool_ID.File_Write not_in excluded)
	testing.expect(t, tools.Tool_ID.Symbol_Move not_in excluded)

	// The read_only strip runs after the layers: an "include everything"
	// layer still loses the editing tools — the config write pair carries
	// can_edit, so a read-only session cannot mutate project.jsonc either.
	read_only := tools.fold_visibility(caps, true, nil, nil)
	testing.expect(t, tools.Tool_ID.File_Write not_in read_only)
	testing.expect(t, tools.Tool_ID.Symbol_Replace_Body not_in read_only)
	testing.expect(t, tools.Tool_ID.File_Search in read_only)
	testing.expect(t, tools.Tool_ID.Config_Set not_in read_only)
	testing.expect(t, tools.Tool_ID.Config_Delete not_in read_only)
	testing.expect(t, tools.Tool_ID.Config_Get in read_only)

	// The family's query half is default-visible — an unconfigured
	// project must still reach the setup guidance langserver_list
	// carries; the management half joins on demand, and only the named
	// tools.
	base := tools.fold_visibility(caps, false, nil, nil)
	testing.expect(t, tools.Tool_ID.Langserver_List in base)
	testing.expect(t, tools.Tool_ID.Langserver_Get_Diagnostics in base)
	testing.expect(t, tools.Tool_ID.Langserver_Find_Calls in base)
	testing.expect(t, tools.Tool_ID.Langserver_Start not_in base)

	// The config write pair is default-visible (mandatory surface — the
	// guidance texts name config_set as the primary route) and never
	// optional; read_only is the only thing that strips it.
	testing.expect(t, tools.Tool_ID.Config_Set in base)
	testing.expect(t, tools.Tool_ID.Config_Delete in base)

	included := tools.fold_visibility(caps, false, []tools.Visibility_Layer{
		{included_optional = []string{"langserver_start", "langserver_find_calls"}},
	}, nil)
	testing.expect(t, tools.Tool_ID.Langserver_Start in included)
	testing.expect(t, tools.Tool_ID.Langserver_Find_Calls in included)
	testing.expect(t, tools.Tool_ID.Langserver_Stop not_in included)
}

@(test)
fold_fixed_replaces :: proc(t: ^testing.T) {
	caps := bit_set[tools.Cap]{.Project, .Svc, .Editor}

	// A fixed layer replaces the whole set — even tools the earlier base
	// had are gone, and layers after the fixed one keep folding.
	set := tools.fold_visibility(caps, false, []tools.Visibility_Layer{
		{fixed = []string{"symbol_find", "file_read"}},
		{excluded = []string{"file_read"}},
	}, nil)
	testing.expect(t, tools.Tool_ID.Symbol_Find in set)
	testing.expect(t, tools.Tool_ID.File_Read not_in set) // excluded after the replace
	testing.expect(t, tools.Tool_ID.File_Search not_in set) // replaced away
	testing.expect(t, tools.Tool_ID.Onboarding_Check not_in set) // replaced away
}

@(test)
fold_warn_and_skip :: proc(t: ^testing.T) {
	caps := bit_set[tools.Cap]{.Project, .Svc, .Editor}

	warnings := make([dynamic]string, 0, 4, context.allocator)
	defer {
		for w in warnings {
			delete(w)
		}
		delete(warnings)
	}

	// Unknown names warn and skip; capability-unsatisfiable names warn
	// and skip too (shell without the Shell cap).
	set := tools.fold_visibility(caps, false, []tools.Visibility_Layer{
		{excluded = []string{"no_such_tool", "shell_run"}},
	}, &warnings)
	testing.expect(t, tools.Tool_ID.Shell_Run not_in set) // no Shell cap anyway
	testing.expect_value(t, len(warnings), 2)

	unknown_seen := false
	shell_seen := false
	for w in warnings {
		if strings.contains(w, "unknown tool name in excluded_tools, skipping: no_such_tool") {
			unknown_seen = true
		}
		if strings.contains(w, "tool not available in this session, skipping: shell_run") {
			shell_seen = true
		}
	}
	testing.expect(t, unknown_seen)
	testing.expect(t, shell_seen)
}

@(test)
fold_markers_config_included :: proc(t: ^testing.T) {
	caps := bit_set[tools.Cap]{.Project, .Svc, .Editor}

	// Markers are optional like every config-includable tool: absent from
	// the base set, present exactly when named.
	base := tools.fold_visibility(caps, false, nil, nil)
	testing.expect(t, tools.Tool_ID.Marker_Symbolic_Read not_in base)
	testing.expect(t, tools.Tool_ID.Marker_Can_Edit not_in base)
	testing.expect(t, tools.Tool_ID.Marker_Symbolic_Edit not_in base)

	included := tools.fold_visibility(caps, false, []tools.Visibility_Layer{
		{included_optional = []string{"marker_symbolic_read", "marker_can_edit"}},
	}, nil)
	testing.expect(t, tools.Tool_ID.Marker_Symbolic_Read in included)
	testing.expect(t, tools.Tool_ID.Marker_Can_Edit in included)
	testing.expect(t, tools.Tool_ID.Marker_Symbolic_Edit not_in included)

	// read_only never strips them (no can_edit).
	read_only := tools.fold_visibility(caps, true, []tools.Visibility_Layer{
		{included_optional = []string{"marker_symbolic_read"}},
	}, nil)
	testing.expect(t, tools.Tool_ID.Marker_Symbolic_Read in read_only)

	// The render paths surface marker names, not tool names.
	testing.expect_value(t, tools.marker_name_for("marker_symbolic_read"), "ToolMarkerSymbolicRead")
	testing.expect_value(t, tools.marker_name_for("marker_can_edit"), "ToolMarkerCanEdit")
	testing.expect_value(t, tools.marker_name_for("marker_symbolic_edit"), "ToolMarkerSymbolicEdit")
	testing.expect_value(t, tools.marker_name_for("file_read"), "")
}

// The table's flags must match behavior: the langserver lifecycle tools
// mutate daemon state (the daemon registers the same methods MUTATING),
// so they carry can_edit — which also strips them in read_only sessions
// where the daemon guard would refuse them anyway — and the
// content-overwriting rename/export tools carry the destructive
// annotation their peers have.
@(test)
fold_tool_table_flag_consistency :: proc(t: ^testing.T) {
	table := tools.TOOLS
	for desc in table {
		switch desc.name {
		case "langserver_start", "langserver_stop", "langserver_restart", "langserver_reload":
			testing.expectf(t, desc.can_edit, "%s mutates daemon state and must carry can_edit", desc.name)
		case "symbol_rename", "tracker_export":
			testing.expectf(t, desc.destructive, "%s overwrites existing content and must be destructive", desc.name)
		}
	}

	// read_only strips the lifecycle family with the rest of the editors —
	// no visible-but-always-failing tools — while the family's pure reader
	// stays available.
	caps := bit_set[tools.Cap]{.Project, .Svc, .Editor}
	read_only := tools.fold_visibility(caps, true, []tools.Visibility_Layer{
		{included_optional = []string{
			"langserver_start", "langserver_stop", "langserver_restart", "langserver_reload", "langserver_list",
		}},
	}, nil)
	testing.expect(t, tools.Tool_ID.Langserver_Start not_in read_only)
	testing.expect(t, tools.Tool_ID.Langserver_Stop not_in read_only)
	testing.expect(t, tools.Tool_ID.Langserver_Restart not_in read_only)
	testing.expect(t, tools.Tool_ID.Langserver_Reload not_in read_only)
	testing.expect(t, tools.Tool_ID.Langserver_List in read_only)
}

// Warning strings must be allocated through the allocator the caller names,
// not the ambient one: the list's owner frees them with its own allocator,
// so a context-allocated element would surface as a bad free under the
// per-test tracking allocator.
@(test)
fold_warnings_follow_the_named_allocator :: proc(t: ^testing.T) {
	amb: mem.Dynamic_Arena
	mem.dynamic_arena_init(&amb, context.allocator)
	defer mem.dynamic_arena_destroy(&amb)

	warnings := make([dynamic]string, 0, 4, context.allocator)
	saved := context.allocator
	context.allocator = mem.dynamic_arena_allocator(&amb)
	set := tools.fold_visibility({.Project, .Svc}, false, []tools.Visibility_Layer{
		{excluded = []string{"no_such_tool"}},
	}, &warnings, saved)
	context.allocator = saved

	testing.expect_value(t, len(warnings), 1)
	if len(warnings) == 1 {
		testing.expect(t, strings.contains(warnings[0], "unknown tool name in excluded_tools, skipping: no_such_tool"))
	}
	// Frees through the list's (tracking) allocator: an element that had
	// come from the ambient arena would be a bad free here.
	for w in warnings {
		delete(w, saved)
	}
	delete(warnings)
	_ = set
}
