// Tags-query inference, ported from the gotreesitter registry engine.
// When a grammar ships no usable tags.scm (empty here, or rejected by
// the C core), build_outliner assembles a query from a hand-verified
// per-language override or from generic patterns gated on the grammar's
// symbol table: a pattern joins the query only when every node type it
// mentions exists in the grammar, which also keeps C's atomic
// ts_query_new rejection away from impossible patterns on the generic
// rows. The per-language overrides keep their upstream shape comments
// where the shape is non-obvious; they were verified against the C
// oracle upstream.
//
// There is deliberately no package-level result cache (process globals
// are forbidden): consumers build outliners lazily once per language,
// and one inference pass is 42 pattern checks against the symbol table.
package ts

import "core:strings"

// Hand-verified per-language tags queries (upstream-verified against the C
// oracle). A language listed here short-circuits the generic patterns; row
// comments state the grammar shape the query depends on.
Tags_Infer_Override :: struct {
	langs: []string,
	query: string,
}

TAGS_INFER_OVERRIDES :: []Tags_Infer_Override{
	{langs = {"perl"}, query = "(package_statement (package) @name) @definition.module\n" +
		"(subroutine_declaration_statement (bareword) @name) @definition.function"},
	{langs = {"go"}, query = "(function_declaration name: (identifier) @name) @definition.function\n" +
		"(method_declaration name: (field_identifier) @name) @definition.method\n" +
		"(call_expression function: (identifier) @name) @reference.call\n" +
		"(call_expression function: (selector_expression field: (field_identifier) @name)) @reference.call"},
	{langs = {"python"}, query = "(function_definition (identifier) @name) @definition.function\n" +
		"(class_definition (identifier) @name) @definition.class\n" +
		"(call (identifier) @name) @reference.call\n" +
		"(call (attribute (identifier) @name)) @reference.call"},
	{langs = {"javascript"}, query = "(function_declaration (identifier) @name) @definition.function\n" +
		"(method_definition (property_identifier) @name) @definition.method\n" +
		"(class_declaration (identifier) @name) @definition.class\n" +
		"(call_expression (identifier) @name) @reference.call\n" +
		"(call_expression (member_expression (property_identifier) @name)) @reference.call"},
	{langs = {"typescript", "tsx"}, query = "(function_declaration (identifier) @name) @definition.function\n" +
		"(method_definition (property_identifier) @name) @definition.method\n" +
		"(class_declaration (type_identifier) @name) @definition.class\n" +
		"(interface_declaration (type_identifier) @name) @definition.interface\n" +
		"(enum_declaration (identifier) @name) @definition.type\n" +
		"(call_expression (identifier) @name) @reference.call\n" +
		"(call_expression (member_expression (property_identifier) @name)) @reference.call"},
	{langs = {"java"}, query = "(method_declaration (identifier) @name) @definition.method\n" +
		"(class_declaration (identifier) @name) @definition.class\n" +
		"(interface_declaration (identifier) @name) @definition.interface\n" +
		"(enum_declaration (identifier) @name) @definition.type\n" +
		"(constructor_declaration (identifier) @name) @definition.constructor\n" +
		"(method_invocation (identifier) @name) @reference.call"},
	{langs = {"rust"}, query = "(function_item (identifier) @name) @definition.function\n" +
		"(function_signature_item (identifier) @name) @definition.function\n" +
		"(struct_item (type_identifier) @name) @definition.type\n" +
		"(enum_item (type_identifier) @name) @definition.type\n" +
		"(trait_item (type_identifier) @name) @definition.type\n" +
		"(call_expression (identifier) @name) @reference.call\n" +
		"(call_expression (field_expression (field_identifier) @name)) @reference.call\n" +
		"(call_expression (scoped_identifier (identifier) @name)) @reference.call\n" +
		"(macro_invocation (identifier) @name) @reference.call"},
	{langs = {"c"}, query = "(function_definition (function_declarator (identifier) @name)) @definition.function\n" +
		"(function_definition (function_declarator (field_identifier) @name)) @definition.function\n" +
		"(type_definition (type_identifier) @name) @definition.type\n" +
		"(struct_specifier (type_identifier) @name) @definition.type\n" +
		"(call_expression (identifier) @name) @reference.call\n" +
		"(call_expression (field_expression (field_identifier) @name)) @reference.call"},
	{langs = {"cpp"}, query = "(function_definition (function_declarator (identifier) @name)) @definition.function\n" +
		"(function_definition (function_declarator (field_identifier) @name)) @definition.function\n" +
		"(type_definition (type_identifier) @name) @definition.type\n" +
		"(class_specifier (type_identifier) @name) @definition.class\n" +
		"(struct_specifier (type_identifier) @name) @definition.type\n" +
		"(call_expression (identifier) @name) @reference.call\n" +
		"(call_expression (field_expression (field_identifier) @name)) @reference.call"},
	{langs = {"c_sharp"}, query = "(method_declaration (identifier) @name) @definition.method\n" +
		"(class_declaration (identifier) @name) @definition.class\n" +
		"(interface_declaration (identifier) @name) @definition.interface\n" +
		"(enum_declaration (identifier) @name) @definition.type\n" +
		"(constructor_declaration (identifier) @name) @definition.constructor"},
	// The grammar has no plain "identifier" symbol at all: every
	// name-bearing leaf is "name", which is why the generic patterns
	// gate PHP to an empty query.
	{langs = {"php"}, query = "(function_definition (name) @name) @definition.function\n" +
		"(method_declaration (name) @name) @definition.method\n" +
		"(class_declaration (name) @name) @definition.class\n" +
		"(interface_declaration (name) @name) @definition.interface\n" +
		"(trait_declaration (name) @name) @definition.trait\n" +
		"(enum_declaration (name) @name) @definition.type\n" +
		"(enum_case (name) @name) @definition.enum_member"},
	{langs = {"erlang"}, query = "(fun_decl (function_clause (atom) @name)) @definition.function\n" +
		"(record_decl (atom) @name) @definition.record"},
	{langs = {"ocaml"}, query = "(type_definition (type_binding name: (type_constructor) @name)) @definition.type\n" +
		"(value_definition (let_binding pattern: (value_name) @name)) @definition.function\n" +
		"(module_definition (module_binding (module_name) @name)) @definition.module\n" +
		"(exception_definition (constructor_declaration (constructor_name) @name)) @definition.exception\n" +
		"(class_definition (class_binding (class_name) @name)) @definition.class\n" +
		"(method_definition (method_name) @name) @definition.method"},
	{langs = {"bash"}, query = "(function_definition name: (word) @name) @definition.function"},
	{langs = {"fish"}, query = "(function_definition name: (word) @name) @definition.function"},
	{langs = {"graphql"}, query = "(object_type_definition (name) @name) @definition.type\n" +
		"(interface_type_definition (name) @name) @definition.interface\n" +
		"(enum_type_definition (name) @name) @definition.enum\n" +
		"(enum_value_definition (enum_value (name) @name)) @definition.enum_member\n" +
		"(input_object_type_definition (name) @name) @definition.type\n" +
		"(union_type_definition (name) @name) @definition.union\n" +
		"(scalar_type_definition (name) @name) @definition.scalar\n" +
		"(directive_definition (name) @name) @definition.directive"},
	// The "left" field on assignment excludes a plain read of a
	// constant on the right, so only genuine bindings are captured.
	{langs = {"ruby"}, query = "(class (constant) @name) @definition.class\n" +
		"(module (constant) @name) @definition.module\n" +
		"(method (identifier) @name) @definition.method\n" +
		"(singleton_method (identifier) @name) @definition.method\n" +
		"(assignment left: (constant) @name) @definition.constant"},
	// class_declaration is reused for classes, interfaces, AND enum
	// classes, distinguished only by keyword token or body node type;
	// the three rows are mutually exclusive by construction.
	// Function names use "simple_identifier", never "identifier".
	{langs = {"kotlin"}, query = `(class_declaration "interface" (type_identifier) @name) @definition.interface` + "\n" +
		"(class_declaration (type_identifier) @name (enum_class_body)) @definition.enum\n" +
		`(class_declaration "class" (type_identifier) @name (class_body)) @definition.class` + "\n" +
		"(object_declaration (type_identifier) @name) @definition.object\n" +
		"(function_declaration (simple_identifier) @name) @definition.function\n" +
		"(enum_entry (simple_identifier) @name) @definition.enum_member\n" +
		"(type_alias (type_identifier) @name) @definition.type"},
	// The same class_declaration reuse as Kotlin (class, struct, AND
	// enum all parse as class_declaration). Constructors carry no name
	// distinct from the fixed "init" keyword and are not captured.
	{langs = {"swift"}, query = "(protocol_declaration (type_identifier) @name) @definition.interface\n" +
		`(class_declaration "class" (type_identifier) @name (class_body)) @definition.class` + "\n" +
		`(class_declaration "struct" (type_identifier) @name (class_body)) @definition.struct` + "\n" +
		"(class_declaration (type_identifier) @name (enum_class_body)) @definition.enum\n" +
		"(protocol_function_declaration (simple_identifier) @name) @definition.method\n" +
		"(function_declaration (simple_identifier) @name) @definition.function\n" +
		"(enum_entry (simple_identifier) @name) @definition.enum_member"},
	{langs = {"scala"}, query = "(trait_definition name: (identifier) @name) @definition.interface\n" +
		"(class_definition name: (identifier) @name) @definition.class\n" +
		"(object_definition name: (identifier) @name) @definition.object\n" +
		"(enum_definition name: (identifier) @name) @definition.enum\n" +
		"(function_declaration name: (identifier) @name) @definition.function\n" +
		"(function_definition name: (identifier) @name) @definition.function\n" +
		"(simple_enum_case (identifier) @name) @definition.enum_member"},
	{langs = {"dart"}, query = "(class_definition (identifier) @name) @definition.class\n" +
		"(enum_declaration (identifier) @name) @definition.type\n" +
		"(enum_constant (identifier) @name) @definition.enum_member\n" +
		"(mixin_declaration (identifier) @name) @definition.mixin\n" +
		"(function_signature (identifier) @name) @definition.function\n" +
		"(constructor_signature (identifier) @name) @definition.constructor\n" +
		"(getter_signature (identifier) @name) @definition.method"},
	// struct/enum literals carry no name of their own: the name comes
	// from the surrounding variable binding. The leading anchor on
	// function_declaration keeps a user-defined return type (a later
	// identifier sibling) from colliding with the name.
	{langs = {"zig"}, query = "(variable_declaration (identifier) @name (struct_declaration)) @definition.type\n" +
		"(variable_declaration (identifier) @name (enum_declaration)) @definition.enum\n" +
		"(function_declaration . (identifier) @name) @definition.function"},
	// defmodule/def/defp/defmacro are ordinary calls, not distinct
	// node types; predicates on the call's head identifier are the
	// only way to name the construct.
	{langs = {"elixir"}, query = `(call (identifier) @_head (arguments (alias) @name) (#eq? @_head "defmodule")) @definition.module` + "\n" +
		`(call (identifier) @_head (arguments (call (identifier) @name)) (#any-of? @_head "def" "defp" "defmacro")) @definition.function` + "\n" +
		"(call (identifier) @name) @reference.call"},
	{langs = {"julia"}, query = "(module_definition (identifier) @name) @definition.module\n" +
		"(struct_definition (type_head (identifier) @name)) @definition.type\n" +
		"(abstract_definition (type_head (identifier) @name)) @definition.type\n" +
		"(function_definition (signature (call_expression (identifier) @name))) @definition.function\n" +
		"(const_statement (assignment . (identifier) @name)) @definition.constant"},
	// The trailing anchor resolves typed methods ("String greet()")
	// where return type and name are sibling identifiers.
	{langs = {"groovy"}, query = "(class_definition (identifier) @name) @definition.class\n" +
		"(function_definition (identifier) @name . (parameter_list)) @definition.function"},
	{langs = {"solidity"}, query = "(contract_declaration name: (identifier) @name) @definition.class\n" +
		"(interface_declaration name: (identifier) @name) @definition.interface\n" +
		"(library_declaration name: (identifier) @name) @definition.class\n" +
		"(struct_declaration name: (identifier) @name) @definition.type\n" +
		"(enum_declaration name: (identifier) @name) @definition.type\n" +
		"(function_definition name: (identifier) @name) @definition.function\n" +
		"(modifier_definition name: (identifier) @name) @definition.method\n" +
		"(event_definition name: (identifier) @name) @definition.event"},
	{langs = {"nim"}, query = "(type_declaration (type_symbol_declaration (identifier) @name) (object_declaration)) @definition.type\n" +
		"(type_declaration (type_symbol_declaration (identifier) @name) (enum_declaration)) @definition.enum\n" +
		"(proc_declaration (identifier) @name) @definition.function\n" +
		"(func_declaration (identifier) @name) @definition.function\n" +
		"(method_declaration (identifier) @name) @definition.method\n" +
		"(const_section (variable_declaration (symbol_declaration_list (symbol_declaration (identifier) @name)))) @definition.constant\n" +
		"(call (identifier) @name) @reference.call"},
	{langs = {"crystal"}, query = "(module_def (constant) @name) @definition.module\n" +
		"(class_def (constant) @name) @definition.class\n" +
		"(struct_def (constant) @name) @definition.struct\n" +
		"(enum_def . (constant) @name) @definition.enum\n" +
		"(method_def (identifier) @name) @definition.method\n" +
		"(const_assign (constant) @name) @definition.constant"},
	{langs = {"d"}, query = "(interface_declaration (identifier) @name) @definition.interface\n" +
		"(class_declaration (identifier) @name) @definition.class\n" +
		"(struct_declaration (identifier) @name) @definition.struct\n" +
		"(enum_declaration (identifier) @name) @definition.type\n" +
		"(enum_member (identifier) @name) @definition.enum_member\n" +
		"(function_declaration (identifier) @name) @definition.function"},
	{langs = {"v"}, query = "(interface_declaration (identifier) @name) @definition.interface\n" +
		"(struct_declaration (identifier) @name) @definition.struct\n" +
		"(enum_declaration (identifier) @name) @definition.type\n" +
		"(enum_field_definition (identifier) @name) @definition.enum_member\n" +
		"(function_declaration (identifier) @name) @definition.function\n" +
		"(const_declaration (const_definition (identifier) @name)) @definition.constant"},
	{langs = {"thrift"}, query = "(struct_definition (identifier) @name) @definition.type\n" +
		"(enum_definition . (identifier) @name) @definition.enum\n" +
		"(service_definition (identifier) @name) @definition.service\n" +
		"(typedef_definition (typedef_identifier) @name) @definition.type\n" +
		"(exception_definition (identifier) @name) @definition.exception\n" +
		"(function_definition (identifier) @name) @definition.method"},
	// Every top-level construct is the same generic "block" node with
	// no fields; the name is the LAST label before block_start
	// (Terraform's own TYPE.NAME convention), falling back to the
	// block's type identifier for zero-label blocks.
	{langs = {"hcl"}, query = "(block (identifier) (string_lit (template_literal) @name) . (block_start)) @definition.block\n" +
		"(block (identifier) @name . (block_start)) @definition.block"},
	// function()/macro() define their own name as the FIRST argument;
	// the leading anchor keeps parameter names out of the capture.
	{langs = {"cmake"}, query = "(function_def (function_command (function) (argument_list . (argument (unquoted_argument) @name)))) @definition.function\n" +
		"(macro_def (macro_command (macro) (argument_list . (argument (unquoted_argument) @name)))) @definition.macro"},
	{langs = {"powershell"}, query = "(function_statement (function_name) @name) @definition.function\n" +
		"(class_statement (simple_name) @name) @definition.class\n" +
		"(class_method_definition (simple_name) @name) @definition.method\n" +
		"(enum_statement (simple_name) @name) @definition.enum\n" +
		"(enum_member (simple_name) @name) @definition.enum_member"},
	{langs = {"sql"}, query = "(create_table_statement (identifier) @name) @definition.type\n" +
		"(create_view_statement (identifier) @name) @definition.type\n" +
		"(create_function_statement (identifier) @name) @definition.function\n" +
		"(create_index_statement name: (identifier) @name) @definition.index\n" +
		"(create_type_statement (identifier) @name) @definition.type\n" +
		"(create_sequence (identifier) @name) @definition.sequence\n" +
		"(create_trigger_statement name: (identifier) @name) @definition.trigger"},
	{langs = {"proto"}, query = "(message (message_name (identifier) @name)) @definition.message\n" +
		"(enum (enum_name (identifier) @name)) @definition.enum\n" +
		"(enum_field (identifier) @name) @definition.enum_member\n" +
		"(service (service_name (identifier) @name)) @definition.service\n" +
		"(rpc (rpc_name (identifier) @name)) @definition.rpc"},
	{langs = {"commonlisp"}, query = "(defun (defun_header function_name: (sym_lit) @name)) @definition.function\n" +
		`(list_lit . (sym_lit) @_head . (sym_lit) @name (#eq? @_head "defvar")) @definition.variable` + "\n" +
		`(list_lit . (sym_lit) @_head . (sym_lit) @name (#eq? @_head "defparameter")) @definition.variable`},
	{langs = {"scheme"}, query = `(list . (symbol) @_head . (list . (symbol) @name) (#eq? @_head "define")) @definition.function` + "\n" +
		`(list . (symbol) @_head . (symbol) @name (#eq? @_head "define")) @definition.variable`},
	// The grammar defines a "function_definition" symbol that no
	// production ever reaches (an impossible pattern on the C side);
	// all real definitions go through function_declaration. The
	// trailing anchor picks the LAST identifier of a dotted method
	// name, not the table.
	{langs = {"lua"}, query = "(function_declaration (identifier) @name) @definition.function\n" +
		"(function_declaration (dot_index_expression (identifier) @name .)) @definition.method"},
}

// tags_infer_override returns the hand-verified query for a language,
// "" when none exists. Overrides short-circuit the generic patterns.
tags_infer_override :: proc(name: string) -> string {
	for row in TAGS_INFER_OVERRIDES {
		for lang in row.langs {
			if lang == name {
				return row.query
			}
		}
	}
	return ""
}

Tags_Infer_Pattern :: struct {
	query:    string,
	required: string, // space-separated node types the query depends on
}

// Generic, symbol-gated patterns shared by every language without an
// override. A row joins the inferred query only when the grammar's
// symbol table contains every node type in `required`.
TAGS_INFER_PATTERNS :: []Tags_Infer_Pattern{
	// Common definitions.
	{query = "(function_declaration (identifier) @name) @definition.function", required = "function_declaration identifier"},
	{query = "(function_declaration (type_identifier) @name) @definition.function", required = "function_declaration type_identifier"},
	{query = "(function_definition (identifier) @name) @definition.function", required = "function_definition identifier"},
	{query = "(function_definition (field_identifier) @name) @definition.function", required = "function_definition field_identifier"},
	{query = "(function_definition (function_declarator (identifier) @name)) @definition.function", required = "function_definition function_declarator identifier"},
	{query = "(function_definition (function_declarator (field_identifier) @name)) @definition.function", required = "function_definition function_declarator field_identifier"},
	{query = "(method_declaration (identifier) @name) @definition.method", required = "method_declaration identifier"},
	{query = "(method_declaration (field_identifier) @name) @definition.method", required = "method_declaration field_identifier"},
	{query = "(method_definition (property_identifier) @name) @definition.method", required = "method_definition property_identifier"},
	{query = "(method_definition (identifier) @name) @definition.method", required = "method_definition identifier"},
	{query = "(class_declaration (identifier) @name) @definition.class", required = "class_declaration identifier"},
	{query = "(class_declaration (type_identifier) @name) @definition.class", required = "class_declaration type_identifier"},
	{query = "(class_definition (identifier) @name) @definition.class", required = "class_definition identifier"},
	{query = "(interface_declaration (identifier) @name) @definition.interface", required = "interface_declaration identifier"},
	{query = "(interface_declaration (type_identifier) @name) @definition.interface", required = "interface_declaration type_identifier"},
	{query = "(enum_declaration (identifier) @name) @definition.type", required = "enum_declaration identifier"},
	{query = "(enum_declaration (type_identifier) @name) @definition.type", required = "enum_declaration type_identifier"},
	{query = "(constructor_declaration (identifier) @name) @definition.constructor", required = "constructor_declaration identifier"},
	{query = "(type_definition (type_identifier) @name) @definition.type", required = "type_definition type_identifier"},
	{query = "(type_definition (identifier) @name) @definition.type", required = "type_definition identifier"},
	{query = "(type_declaration (type_spec (type_identifier) @name)) @definition.type", required = "type_declaration type_spec type_identifier"},
	{query = "(type_declaration (type_alias (type_identifier) @name)) @definition.type", required = "type_declaration type_alias type_identifier"},
	{query = "(function_item (identifier) @name) @definition.function", required = "function_item identifier"},
	{query = "(function_signature_item (identifier) @name) @definition.function", required = "function_signature_item identifier"},
	{query = "(struct_item (type_identifier) @name) @definition.type", required = "struct_item type_identifier"},
	{query = "(enum_item (type_identifier) @name) @definition.type", required = "enum_item type_identifier"},
	{query = "(trait_item (type_identifier) @name) @definition.type", required = "trait_item type_identifier"},
	{query = "(class_specifier (type_identifier) @name) @definition.class", required = "class_specifier type_identifier"},
	{query = "(struct_specifier (type_identifier) @name) @definition.type", required = "struct_specifier type_identifier"},
	// A bare "type_alias" node (not wrapped in type_declaration, unlike
	// Go's shape above) whose first named child is the alias name.
	{query = "(type_alias (type_identifier) @name) @definition.type", required = "type_alias type_identifier"},

	// Constants and variables.
	{query = "(const_spec (identifier) @name) @definition.constant", required = "const_spec identifier"},
	{query = "(var_spec (identifier) @name) @definition.variable", required = "var_spec identifier"},
	{query = "(short_var_declaration (identifier) @name) @definition.variable", required = "short_var_declaration identifier"},

	// Common call references.
	{query = "(call_expression (identifier) @name) @reference.call", required = "call_expression identifier"},
	{query = "(call_expression (field_identifier) @name) @reference.call", required = "call_expression field_identifier"},
	{query = "(call_expression (property_identifier) @name) @reference.call", required = "call_expression property_identifier"},
	{query = "(call_expression (member_expression (property_identifier) @name)) @reference.call", required = "call_expression member_expression property_identifier"},
	{query = "(call_expression (selector_expression (field_identifier) @name)) @reference.call", required = "call_expression selector_expression field_identifier"},
	{query = "(call_expression (scoped_identifier (identifier) @name)) @reference.call", required = "call_expression scoped_identifier identifier"},
	{query = "(call (identifier) @name) @reference.call", required = "call identifier"},
	{query = "(call (attribute (identifier) @name)) @reference.call", required = "call attribute identifier"},
	{query = "(method_invocation (identifier) @name) @reference.call", required = "method_invocation identifier"},
	{query = "(macro_invocation (identifier) @name) @reference.call", required = "macro_invocation identifier"},
}

// tags_query_infer assembles the inferred tags query for a language.
// The result lives on the temp allocator: it feeds a single
// compile_query call inside build_outliner and is never retained.
tags_query_infer :: proc(lang_name: string, lang: Language) -> string {
	if override := tags_infer_override(lang_name); strings.trim_space(override) != "" {
		return override
	}
	patterns := TAGS_INFER_PATTERNS
	lines := make([dynamic]string, 0, len(patterns), context.temp_allocator)
	for i in 0..<len(patterns) {
		if !has_all_required_symbols(lang, patterns[i].required) {
			continue
		}
		tags_infer_append_unique(&lines, patterns[i].query)
	}
	if len(lines) == 0 {
		return ""
	}
	joined, jerr := strings.join(lines[:], "\n", context.temp_allocator)
	if jerr != nil {
		return ""
	}
	return joined
}

has_all_required_symbols :: proc(lang: Language, required: string) -> bool {
	i := 0
	for i < len(required) {
		for i < len(required) && required[i] == ' ' {
			i += 1
		}
		if i >= len(required) {
			break
		}
		start := i
		for i < len(required) && required[i] != ' ' {
			i += 1
		}
		if !language_has_symbol(lang, required[start:i]) {
			return false
		}
	}
	return true
}

tags_infer_append_unique :: proc(lines: ^[dynamic]string, s: string) {
	for i in 0..<len(lines^) {
		if lines[i] == s {
			return
		}
	}
	append(lines, s)
}
