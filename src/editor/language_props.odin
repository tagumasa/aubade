// The per-language editing properties, one table for the whole package:
// comment syntax, block-validation style (indentation-significant vs
// brace-counted), and the cross-file-move family. Language ids are the
// tree-sitter grammar names, with a few langserver spellings kept for
// compatibility. A language appears exactly once here; the property sets
// overlap (ruby is scripting but brace-validated, mojo shares python's
// comment marker but none of its other habits), so the properties are
// independent fields rather than one family enum carrying everything.
package editor

// Language_Family is the cross-file-move affinity: extraction between two
// languages of one family re-indents without asking (is_same_family).
Language_Family :: enum {
	Other,     // no affinity — every property decided per language
	C_Like,    // brace languages with shared extraction habits
	Scripting, // python-lineage scripting languages
	Lua,       // lua and its descendants
}

Language_Props :: struct {
	comment:            Comment_Pattern,
	// true: validate_indentation governs extracted blocks (indentation is
	// syntax); false: validate_braces counts braces against the comment
	// pattern.
	indent_significant: bool,
	family:             Language_Family,
}

Language_Props_Row :: struct {
	langs: []string,
	props: Language_Props,
}

// LANGUAGE_PROPS is the single per-language decision table. The comment
// syntaxes were extracted from the pinned grammars' own comment rules;
// the table test in tests/editor_test.odin fails when a registry language
// lacks a decided pattern. Languages absent from the table fall to the
// C-family pattern below deliberately (C-family plus a few grammars that
// parse // comments, e.g. css's js_comment and the tolerant json
// grammar).

// The C-family comment pattern: the brace-language rows and the unlisted
// fallback share one spelling.
C_FAMILY_COMMENT :: Comment_Pattern{line_comment = "//", block_start = "/*", block_end = "*/"}

LANGUAGE_PROPS :: []Language_Props_Row{
	{langs = {"python", "python-jedi", "python-ty"}, props = {
		comment = {line_comment = "#"},
		indent_significant = true,
		family = .Scripting,
	}},
	// mojo shares python's marker but is brace-validated with no family
	// affinity.
	{langs = {"mojo"}, props = {comment = {line_comment = "#"}}},
	{langs = {"ruby"}, props = {
		comment = {line_comment = "#", block_start = "=begin", block_end = "=end"},
		family = .Scripting,
	}},
	{langs = {"ruby-solargraph"}, props = {
		comment = {line_comment = "#", block_start = "=begin", block_end = "=end"},
	}},
	{langs = {"lua", "luau"}, props = {
		comment = {line_comment = "--", block_start = "--[[", block_end = "]]"},
		family = .Lua,
	}},
	{langs = {"teal"}, props = {
		comment = {line_comment = "--", block_start = "--[[", block_end = "]]"},
	}},
	{langs = {"r", "crystal", "bash"}, props = {
		comment = {line_comment = "#"},
		indent_significant = true,
		family = .Scripting,
	}},
	{langs = {"perl", "powershell"}, props = {
		comment = {line_comment = "#"},
		family = .Scripting,
	}},
	{langs = {
		"elixir", "heex", "hcl", "tcl", "fish",
		"yaml", "toml", "dockerfile", "make", "cmake", "graphql", "nix",
		"meson", "git_config",
		"awk", "bitbake", "capnp", "cylc", "desktop", "diff",
		"earthfile", "editorconfig", "gdscript", "git_rebase", "gitattributes",
		"gitignore", "gn", "http", "hurl", "hyprlang", "ini",
		"just", "kconfig", "nginx", "nickel", "ninja", "nushell",
		"org", "promql", "properties", "puppet", "rego", "requirements",
		"robot", "sparql", "ssh_config", "starlark", "textproto",
		"turtle",
	}, props = {comment = {line_comment = "#"}}},
	{langs = {"haskell", "elm", "purescript", "dhall"}, props = {
		comment = {line_comment = "--", block_start = "{-", block_end = "-}"},
	}},
	{langs = {"ada", "agda"}, props = {comment = {line_comment = "--"}}},
	{langs = {"sql"}, props = {comment = {line_comment = "--", block_start = "/*", block_end = "*/"}}},
	{langs = {"erlang", "matlab", "prolog"}, props = {comment = {line_comment = "%"}}},
	{langs = {
		"commonlisp", "scheme", "racket", "elisp", "fennel", "asm",
		"bass", "beancount", "firrtl", "godot_resource", "ledger",
		"llvm", "yuck",
	}, props = {comment = {line_comment = ";"}}},
	{langs = {"fortran"}, props = {comment = {line_comment = "!"}}},
	{langs = {"julia"}, props = {comment = {line_comment = "#", block_start = "#=", block_end = "=#"}}},
	{langs = {"nim"}, props = {comment = {line_comment = "#", block_start = "#[", block_end = "]#"}}},
	{langs = {"pascal"}, props = {comment = {line_comment = "//", block_start = "{", block_end = "}"}}},
	{langs = {"fsharp"}, props = {comment = {line_comment = "//", block_start = "(*", block_end = "*)"}}},
	{langs = {"cobol"}, props = {comment = {line_comment = "*>"}}},
	{langs = {"forth"}, props = {comment = {line_comment = "\\"}}},
	{langs = {"tlaplus"}, props = {comment = {line_comment = "\\*", block_start = "(*", block_end = "*)"}}},
	{langs = {"ocaml", "wolfram"}, props = {comment = {block_start = "(*", block_end = "*)"}}},
	{langs = {"uxntal"}, props = {comment = {block_start = "(", block_end = ")"}}},
	{langs = {"wat"}, props = {comment = {line_comment = ";;", block_start = "(;", block_end = ";)"}}},
	{langs = {
		"html", "xml", "dtd", "angular", "astro", "svelte",
		"markdown", "markdown_inline",
	}, props = {comment = {block_start = "<!--", block_end = "-->"}}},
	// vue components carry C-family script blocks.
	{langs = {"vue"}, props = {
		comment = {block_start = "<!--", block_end = "-->"},
		family = .C_Like,
	}},
	{langs = {"jinja2"}, props = {comment = {block_start = "{#", block_end = "#}"}}},
	{langs = {"blade"}, props = {comment = {block_start = "{{--", block_end = "--}}"}}},
	{langs = {"embedded_template"}, props = {comment = {block_start = "<%#", block_end = "%>"}}},
	{langs = {"liquid"}, props = {comment = {block_start = "{% comment %}", block_end = "{% endcomment %}"}}},
	{langs = {"mermaid"}, props = {comment = {line_comment = "%%"}}},
	// Formats with no comment marker the upward scan can key on (bibtex
	// comments are @comment entries; djot/norg comments are markup
	// spans) — the empty pattern matches nothing, so docstring detection
	// honestly reports "nothing above the definition".
	{langs = {
		"bibtex", "comment", "csv", "djot", "norg",
		"pem", "regex", "rst", "todotxt", "vimdoc",
	}, props = {}},
	// The brace languages whose comment syntax is the C-family pattern.
	{langs = {
		"go", "java", "csharp", "c_sharp", "csharp-omnisharp", "cpp", "clangd",
		"typescript", "rust", "kotlin", "swift", "dart", "php", "scala",
		"groovy", "zig", "haxe", "hlsl", "systemverilog", "solidity",
	}, props = {
		comment = C_FAMILY_COMMENT,
		family = .C_Like,
	}},
}

// language_props is the one per-language property lookup. The unlisted
// fallback carries the C-family comment pattern with brace validation and
// no family affinity — a deliberate default for C-family grammars and the
// few that parse // comments.
language_props :: proc(lang: string) -> (props: Language_Props, listed: bool) {
	for row in LANGUAGE_PROPS {
		for name in row.langs {
			if name == lang {
				return row.props, true
			}
		}
	}
	return Language_Props{
		comment = C_FAMILY_COMMENT,
	}, false
}
