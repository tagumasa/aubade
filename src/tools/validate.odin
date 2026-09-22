// Argument validation: Param_Desc driven, run before apply.
// Violations produce .Invalid -> the tools/call response is an
// isError:true text result, never a JSON-RPC -32602.
package tools

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "src:jsonutil"

// validate_args checks the incoming arguments object against the tool's
// Param_Desc list and returns the validated values map (allocated from
// `a`). err_msg == "" means valid. Extra keys not described by the table
// are ignored (they stay visible through Args.raw for error quoting).
// The descriptor arrives by pointer and params are walked by index
// (same discipline as schema_for_tool).
validate_args :: proc(desc: ^Tool_Desc, args: json.Value, a: mem.Allocator) -> (values: map[string]json.Value, err_msg: string) {
	values = make(map[string]json.Value, len(desc.params), a)

	params_obj, is_obj := jsonutil.as_object(args)
	if args != nil && !is_obj {
		// Absent arguments validate as {}; a present non-object never does —
		// silently treating it as {} would contradict the declared schema.
		return nil, "arguments must be a JSON object"
	}

	params := desc.params
	for pi in 0..<len(params) {
		p := &params[pi]
		val: json.Value = nil
		found := false
		if params_obj != nil {
			val, found = params_obj[p.name]
		}
		if !found || val == nil {
			if p.required {
				return nil, strings.concatenate(
					{"missing required parameter: ", p.name},
					a,
				)
			}
			continue
		}
		if msg := check_kind(p, val, a); msg != "" {
			return nil, msg
		}
		values[p.name] = val
	}
	return values, ""
}

check_kind :: proc(p: ^Param_Desc, val: json.Value, a: mem.Allocator) -> string {
	bad := strings.concatenate({"parameter '", p.name, "' expects "}, a)
	type_name := kind_wire_name(p.kind)

	ok := false
#partial switch x in val {
	case json.String:
		ok = p.kind == .Str
	case json.Integer:
		ok = p.kind == .Int || p.kind == .Float
	case json.Float:
		ok = p.kind == .Float
	case json.Boolean:
		ok = p.kind == .Bool
	case json.Array:
		if p.kind == .Str_Array {
			arr := cast([dynamic]json.Value)x
			all_strings := true
			for item in arr {
				#partial switch it in item {
				case json.String:
				case:
					all_strings = false
				}
			}
			ok = all_strings
		} else if p.kind == .Int_Array {
			arr := cast([dynamic]json.Value)x
			all_ints := true
			for item in arr {
				#partial switch it in item {
				case json.Integer:
				case:
					all_ints = false
				}
			}
			ok = all_ints
		}
	case:
	}
	if !ok {
		return strings.concatenate({bad, type_name}, a)
	}

	if len(p.enum_vals) > 0 && p.kind == .Str {
		#partial switch x in val {
		case json.String:
			allowed := false
			for ei in 0..<len(p.enum_vals) {
				if string(x) == p.enum_vals[ei] {
					allowed = true
					break
				}
			}
			if !allowed {
				return strings.concatenate(
					{"parameter '", p.name, "' must be one of the allowed values"},
					a,
				)
			}
		case:
		}
	}
	return ""
}
