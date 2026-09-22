// inputSchema generation: the Param_Desc -> JSON Schema projection.
// Base dialect is JSON Schema 2020-12 ($schema explicitly included — the
// MCP 2025-11 default dialect). Built per tools/list from the constant
// table (the table is immutable; a per-startup cache would save only
// the projection walk).
package tools

import "core:encoding/json"
import "core:mem"
import "src:jsonutil"

SCHEMA_DIALECT :: "https://json-schema.org/draft/2020-12/schema"

kind_wire_name :: proc(k: Param_Kind) -> string {
	switch k {
	case .Str:        return "string"
	case .Int:        return "integer"
	case .Float:      return "number"
	case .Bool:       return "boolean"
	case .Str_Array:  return "array"
	case .Int_Array:  return "array"
	}
	return "string"
}

// schema_for_tool projects a Tool_Desc into its MCP inputSchema value,
// allocated from `a`. The descriptor arrives by pointer and params are
// walked by index.
schema_for_tool :: proc(desc: ^Tool_Desc, a: mem.Allocator) -> json.Value {
	schema := jsonutil.json_object(4, a)
	jsonutil.obj_set(&schema, "$schema", jsonutil.json_string(SCHEMA_DIALECT))
	jsonutil.obj_set(&schema, "type", jsonutil.json_string("object"))

	params := desc.params
	props := jsonutil.json_object(max(len(params), 1), a)
	required := make([dynamic]json.Value, 0, a)

	for pi in 0..<len(params) {
		p := &params[pi]
		po := jsonutil.json_object(4, a)
		jsonutil.obj_set(&po, "type", jsonutil.json_string(kind_wire_name(p.kind)))
		if p.kind == .Str_Array || p.kind == .Int_Array {
			// The validator rejects arrays with foreign-typed elements; the
			// schema must say the same or it admits what validation denies.
			items := jsonutil.json_object(1, a)
			jsonutil.obj_set(&items, "type", jsonutil.json_string(p.kind == .Str_Array ? "string" : "integer"))
			jsonutil.obj_set(&po, "items", json.Value(json.Object(items)))
		}
		if p.description != "" {
			jsonutil.obj_set(&po, "description", jsonutil.json_string(p.description))
		}
		if len(p.enum_vals) > 0 {
			// Built in place from the []string — no intermediate []json.Value
			// stranded on the arena (json_string_array's documented purpose).
			jsonutil.obj_set(&po, "enum", jsonutil.json_string_array(p.enum_vals, a))
		}
		jsonutil.obj_set_object(&props, p.name, po)
		if p.required {
			append(&required, jsonutil.json_string(p.name))
		}
	}

	jsonutil.obj_set_object(&schema, "properties", props)
	// The owned dynamic enters the union directly — no copy, no intermediate.
	jsonutil.obj_set(&schema, "required", json.Array(required))
	return json.Value(json.Object(schema))
}
