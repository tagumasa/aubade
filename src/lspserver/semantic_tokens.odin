// Capture-name to semantic-token mapping for tree-sitter highlights
// queries, plus the LSP semantic-tokens legend derived from it.
//
// The mapping tables are the single declaration: the legend (which token
// types and modifiers the server announces) is computed by walking them —
// only types and modifiers some entry can emit appear, in LSP standard
// order — so the tables are never accompanied by a hand-written legend.
// LSP 3.17 has no type for several highlight conventions (punctuation,
// spell-check regions, parse-error markers, labels); those capture names
// are deliberately absent from every table so lookups report no-match and
// the caller skips the capture. There is no standard "constant" type
// either: constant-ish captures map to variable with the readonly
// modifier, and capture names ending in ".builtin" (names the language
// itself defines — built-in types, values, functions) carry the
// defaultLibrary modifier on top. Names are bare dotted capture names as
// query machinery reports them ("function.method", no leading '@').
package lspserver

// Token_Type lists the LSP 3.17 standard semantic token types in
// specification order — the member order is load-bearing: it is the
// standard order the legend must preserve, and int(member) is the
// position used to derive legend positions from these tables.
Token_Type :: enum {
	Namespace,
	Type,
	Class,
	Enum,
	Interface,
	Struct,
	Type_Parameter,
	Parameter,
	Variable,
	Property,
	Enum_Member,
	Event,
	Function,
	Method,
	Macro,
	Keyword,
	Modifier,
	Comment,
	String,
	Number,
	Regexp,
	Operator,
	Decorator,
}

// The LSP 3.17 standard vocabularies are closed sets: the counts are the
// specification's, and the test suite pins each enum member to the
// standard spelling in standard order.
TOKEN_TYPE_COUNT :: 23

// Token_Modifier lists the LSP 3.17 standard semantic token modifiers in
// specification order; a set of them encodes a token's modifier bitmask.
Token_Modifier :: enum {
	Declaration,
	Definition,
	Readonly,
	Static,
	Deprecated,
	Abstract,
	Async,
	Modification,
	Documentation,
	Default_Library,
}

TOKEN_MODIFIER_COUNT :: 10

Token_Modifier_Set :: bit_set[Token_Modifier]

// The standard wire spellings, indexed by enum member. These carry the
// vocabulary's names, not its membership — which entries the legend
// announces is derived from the mapping tables alone.
TOKEN_TYPE_NAMES :: [TOKEN_TYPE_COUNT]string{
	"namespace",
	"type",
	"class",
	"enum",
	"interface",
	"struct",
	"typeParameter",
	"parameter",
	"variable",
	"property",
	"enumMember",
	"event",
	"function",
	"method",
	"macro",
	"keyword",
	"modifier",
	"comment",
	"string",
	"number",
	"regexp",
	"operator",
	"decorator",
}

TOKEN_MODIFIER_NAMES :: [TOKEN_MODIFIER_COUNT]string{
	"declaration",
	"definition",
	"readonly",
	"static",
	"deprecated",
	"abstract",
	"async",
	"modification",
	"documentation",
	"defaultLibrary",
}

token_type_name :: proc(tt: Token_Type) -> string {
	names := TOKEN_TYPE_NAMES
	return names[int(tt)]
}

token_modifier_name :: proc(m: Token_Modifier) -> string {
	names := TOKEN_MODIFIER_NAMES
	return names[int(m)]
}

// Capture_Token maps one capture name (a bare dotted name) to the
// standard token type and modifier set emitted for it.
Capture_Token :: struct {
	capture:   string,
	token:     Token_Type,
	modifiers: Token_Modifier_Set,
}

// Audited mappings for the quality-gated grammars' capture vocabularies:
// tree-sitter-grammars/tree-sitter-odin @ v1.3.0 and
// tree-sitter/tree-sitter-go @ v0.25.0, queries/highlights.scm — every
// capture in each vocabulary is either mapped here or documented in the
// unmapped-captures note below the tables (the test suite holds that
// contract name by name). Names both vocabularies share appear once.
// Where a name also exists in the generic table, this row is the audited
// choice and wins: the lookup reads this table first, and the generic
// convention applies only to names this table does not carry.
CURATED_CAPTURES :: []Capture_Token{
	{capture = "attribute",           token = .Decorator},
	{capture = "boolean",             token = .Variable,  modifiers = {.Readonly}},
	{capture = "character",           token = .String},
	{capture = "comment",             token = .Comment},
	{capture = "conditional",         token = .Keyword},
	{capture = "conditional.ternary", token = .Keyword},
	{capture = "constant",            token = .Variable,  modifiers = {.Readonly}},
	{capture = "constant.builtin",    token = .Variable,  modifiers = {.Readonly, .Default_Library}},
	{capture = "field",               token = .Property},
	{capture = "float",               token = .Number},
	{capture = "function",            token = .Function},
	{capture = "function.builtin",    token = .Function,  modifiers = {.Default_Library}},
	{capture = "function.call",       token = .Function},
	{capture = "function.macro",      token = .Macro},
	{capture = "function.method",     token = .Method},
	{capture = "include",             token = .Keyword},
	{capture = "keyword",             token = .Keyword},
	{capture = "keyword.function",    token = .Keyword},
	{capture = "keyword.operator",    token = .Keyword},
	{capture = "keyword.return",      token = .Keyword},
	{capture = "namespace",           token = .Namespace},
	{capture = "number",              token = .Number},
	{capture = "operator",            token = .Operator},
	{capture = "parameter",           token = .Parameter},
	{capture = "preproc",             token = .Macro},
	{capture = "property",            token = .Property},
	{capture = "repeat",              token = .Keyword},
	{capture = "storageclass",        token = .Keyword},
	{capture = "string",              token = .String},
	{capture = "type",                token = .Type},
	{capture = "type.builtin",        token = .Type,      modifiers = {.Default_Library}},
	{capture = "variable",            token = .Variable},
	{capture = "variable.builtin",    token = .Variable,  modifiers = {.Default_Library}},
}

// Generic mappings for the conventional capture vocabulary highlights
// queries share across grammars (the de-facto standard capture names).
// Dotted sub-names whose mapping equals their parent prefix are not
// listed — the longest-match lookup resolves them through the parent
// entry ("keyword.return" through "keyword", "number.float" through
// "number"); only names that differ from every ancestor appear.
GENERIC_CAPTURES :: []Capture_Token{
	// Identifiers.
	{capture = "variable",                  token = .Variable},
	{capture = "variable.builtin",          token = .Variable,  modifiers = {.Default_Library}},
	{capture = "variable.parameter",        token = .Parameter},
	{capture = "variable.parameter.builtin", token = .Parameter, modifiers = {.Default_Library}},
	{capture = "variable.member",           token = .Property},
	{capture = "constant",                  token = .Variable,  modifiers = {.Readonly}},
	{capture = "constant.builtin",          token = .Variable,  modifiers = {.Readonly, .Default_Library}},
	{capture = "module",                    token = .Namespace},
	{capture = "module.builtin",            token = .Namespace, modifiers = {.Default_Library}},

	// Literals.
	{capture = "string",                token = .String},
	{capture = "string.documentation",  token = .String,    modifiers = {.Documentation}},
	{capture = "string.regexp",         token = .Regexp},
	{capture = "character",             token = .String},
	{capture = "boolean",               token = .Variable,  modifiers = {.Readonly}},
	{capture = "number",                token = .Number},
	{capture = "float",                 token = .Number},

	// Types and attributes.
	{capture = "type",              token = .Type},
	{capture = "type.builtin",      token = .Type,      modifiers = {.Default_Library}},
	{capture = "type.definition",   token = .Type,      modifiers = {.Definition}},
	{capture = "attribute",         token = .Decorator},
	{capture = "attribute.builtin", token = .Decorator, modifiers = {.Default_Library}},
	{capture = "property",          token = .Property},
	{capture = "field",             token = .Property},

	// Functions.
	{capture = "function",         token = .Function},
	{capture = "function.builtin", token = .Function, modifiers = {.Default_Library}},
	{capture = "function.macro",   token = .Macro},
	{capture = "function.method",  token = .Method},
	{capture = "method",           token = .Method},
	{capture = "operator",         token = .Operator},

	// Keywords: the keyword family and the conditional/repeat/include
	// synonyms cover their whole dotted subtrees via fallback.
	{capture = "keyword",      token = .Keyword},
	{capture = "conditional",  token = .Keyword},
	{capture = "repeat",       token = .Keyword},
	{capture = "storageclass", token = .Keyword},
	{capture = "include",      token = .Keyword},
	{capture = "preproc",      token = .Macro},

	// Comments.
	{capture = "comment",               token = .Comment},
	{capture = "comment.documentation", token = .Comment, modifiers = {.Documentation}},
}

// Capture names deliberately absent from every table. Each has no
// defensible LSP 3.17 type, and emitting one anyway would misstate the
// token's meaning to clients:
//
//   - error: marks parse-error nodes; syntax errors surface through
//     diagnostics, not token coloring.
//   - label: no 3.17 token type exists (a standard "label" type was
//     added in LSP 3.18 — map it when the protocol baseline moves).
//   - punctuation.bracket, punctuation.delimiter, punctuation.special:
//     no standard type; LSP servers generally do not emit punctuation.
//   - spell: marks spell-check regions and has no type; on odin it
//     captures the same nodes as @comment, so mapping it would also
//     double-emit those tokens.
//   - escape (go): no standard type, and as a root name it has no
//     ancestor to fall back through. Dotted escape names (odin's
//     string.escape) are NOT skipped — longest-match resolves them
//     through their parent string entry, so they emit the string type;
//     how nested child captures encode is the encoder's concern.
//   - constructor and the tag/markup/diff families: no standard type or
//     outside the code-token scope; extend the tables if a curated
//     grammar needs them.

// capture_token resolves a capture name to its token type and modifiers.
// Match is longest-match over the capture's dot hierarchy: the full name
// first, then successively shorter prefixes cut at dots; a capture with
// no entry at any level reports found = false and the caller skips it.
// The walk is bounded by the capture's own segment count over these
// compile-time tables — no allocation, no per-lookup state.
capture_token :: proc(capture: string) -> (token: Token_Type, modifiers: Token_Modifier_Set, found: bool) {
	end := len(capture)
	for end > 0 {
		hit_token, hit_modifiers, hit := capture_tables_entry(capture[:end])
		if hit {
			return hit_token, hit_modifiers, true
		}
		cut := -1
		for i := end - 1; i >= 0; i -= 1 {
			if capture[i] == '.' {
				cut = i
				break
			}
		}
		if cut < 0 {
			break
		}
		end = cut
	}
	return
}

// capture_tables_entry looks up one exact name; a curated row is the
// audited choice and wins over the generic convention for the same name.
capture_tables_entry :: proc(name: string) -> (token: Token_Type, modifiers: Token_Modifier_Set, found: bool) {
	for entry in CURATED_CAPTURES {
		if entry.capture == name {
			return entry.token, entry.modifiers, true
		}
	}
	for entry in GENERIC_CAPTURES {
		if entry.capture == name {
			return entry.token, entry.modifiers, true
		}
	}
	return
}

table_emits_type :: proc(tt: Token_Type) -> bool {
	for entry in CURATED_CAPTURES {
		if entry.token == tt {
			return true
		}
	}
	for entry in GENERIC_CAPTURES {
		if entry.token == tt {
			return true
		}
	}
	return false
}

table_emits_modifier :: proc(m: Token_Modifier) -> bool {
	for entry in CURATED_CAPTURES {
		if m in entry.modifiers {
			return true
		}
	}
	for entry in GENERIC_CAPTURES {
		if m in entry.modifiers {
			return true
		}
	}
	return false
}

// legend_token_types returns the token types the mapping tables can
// emit, in LSP standard (enum) order. This list — not a second
// declaration — is what the protocol layer serializes into
// SemanticTokensLegend.tokenTypes.
legend_token_types :: proc() -> (types: [TOKEN_TYPE_COUNT]Token_Type, count: int) {
	for tt in Token_Type {
		if table_emits_type(tt) {
			types[count] = tt
			count += 1
		}
	}
	return
}

// legend_token_modifiers returns the modifiers the mapping tables can
// emit, in LSP standard (enum) order — the serialization order for
// SemanticTokensLegend.tokenModifiers.
legend_token_modifiers :: proc() -> (modifiers: [TOKEN_MODIFIER_COUNT]Token_Modifier, count: int) {
	for m in Token_Modifier {
		if table_emits_modifier(m) {
			modifiers[count] = m
			count += 1
		}
	}
	return
}

// legend_type_index returns a token type's index inside the emitted
// legend — the wire value for tokenType. The legend position is the rank
// among emitted types, not the enum ordinal: types the tables never
// emit are not announced and have no index (found = false).
legend_type_index :: proc(tt: Token_Type) -> (index: int, found: bool) {
	if !table_emits_type(tt) {
		return
	}
	rank: int
	for candidate in Token_Type {
		if candidate == tt {
			return rank, true
		}
		if table_emits_type(candidate) {
			rank += 1
		}
	}
	return
}

// legend_modifier_bit returns a modifier's bit position inside the
// emitted legend — the wire bit for tokenModifiers. Positions rank the
// emitted modifiers in standard order; modifiers no entry carries have
// no bit (found = false).
legend_modifier_bit :: proc(m: Token_Modifier) -> (bit: u32, found: bool) {
	if !table_emits_modifier(m) {
		return
	}
	rank: u32
	for candidate in Token_Modifier {
		if candidate == m {
			return rank, true
		}
		if table_emits_modifier(candidate) {
			rank += 1
		}
	}
	return
}

// Legend_Ranks is the per-connection rank table for the wire legend: for
// every Token_Type member its announced legend index, for every
// Token_Modifier member its announced wire bit — -1 when the mapping
// tables never emit the member. legend_ranks_build derives both rows from
// the legend procs above (the tables stay the single source), so a token
// stream resolves by one array read instead of a per-token table scan.
// A Server owns one, built at init; nothing package-global.
Legend_Ranks :: struct {
	type_rank:    [TOKEN_TYPE_COUNT]int,
	modifier_bit: [TOKEN_MODIFIER_COUNT]int,
}

legend_ranks_build :: proc() -> Legend_Ranks {
	ranks: Legend_Ranks
	for i in 0 ..< TOKEN_TYPE_COUNT {
		ranks.type_rank[i] = -1
	}
	for i in 0 ..< TOKEN_MODIFIER_COUNT {
		ranks.modifier_bit[i] = -1
	}
	for tt in Token_Type {
		if index, ok := legend_type_index(tt); ok {
			ranks.type_rank[int(tt)] = index
		}
	}
	for m in Token_Modifier {
		if bit, ok := legend_modifier_bit(m); ok {
			ranks.modifier_bit[int(m)] = int(bit)
		}
	}
	return ranks
}
