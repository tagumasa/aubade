// GENERATED FILE — regenerate with `odin run scripts/extract_table
// -- <gotreesitter-dir>`; do not edit by hand. Row order
// is alphabetical and extension claims resolve first-wins in it
// (linguist fallbacks only fill unclaimed extensions). Consumers
// materialize the table before indexing (the compiler rejects
// variable indexing straight into constant data).
package ts

import ts_ada "grammars:ada"
import ts_agda "grammars:agda"
import ts_angular "grammars:angular"
import ts_apex "grammars:apex"
import ts_arduino "grammars:arduino"
import ts_asm "grammars:asm"
import ts_astro "grammars:astro"
import ts_awk "grammars:awk"
import ts_bash "grammars:bash"
import ts_bass "grammars:bass"
import ts_beancount "grammars:beancount"
import ts_bibtex "grammars:bibtex"
import ts_bicep "grammars:bicep"
import ts_bitbake "grammars:bitbake"
import ts_blade "grammars:blade"
import ts_c "grammars:c"
import ts_c_sharp "grammars:c_sharp"
import ts_cairo "grammars:cairo"
import ts_capnp "grammars:capnp"
import ts_chatito "grammars:chatito"
import ts_circom "grammars:circom"
import ts_cmake "grammars:cmake"
import ts_cobol "grammars:cobol"
import ts_comment "grammars:comment"
import ts_commonlisp "grammars:commonlisp"
import ts_cpon "grammars:cpon"
import ts_cpp "grammars:cpp"
import ts_crystal "grammars:crystal"
import ts_css "grammars:css"
import ts_csv "grammars:csv"
import ts_cuda "grammars:cuda"
import ts_cue "grammars:cue"
import ts_cylc "grammars:cylc"
import ts_d "grammars:d"
import ts_dart "grammars:dart"
import ts_desktop "grammars:desktop"
import ts_devicetree "grammars:devicetree"
import ts_dhall "grammars:dhall"
import ts_diff "grammars:diff"
import ts_djot "grammars:djot"
import ts_dockerfile "grammars:dockerfile"
import ts_dot "grammars:dot"
import ts_doxygen "grammars:doxygen"
import ts_dtd "grammars:dtd"
import ts_earthfile "grammars:earthfile"
import ts_editorconfig "grammars:editorconfig"
import ts_elisp "grammars:elisp"
import ts_elixir "grammars:elixir"
import ts_elm "grammars:elm"
import ts_embedded_template "grammars:embedded_template"
import ts_enforce "grammars:enforce"
import ts_erlang "grammars:erlang"
import ts_faust "grammars:faust"
import ts_fennel "grammars:fennel"
import ts_fidl "grammars:fidl"
import ts_firrtl "grammars:firrtl"
import ts_fish "grammars:fish"
import ts_foam "grammars:foam"
import ts_forth "grammars:forth"
import ts_fortran "grammars:fortran"
import ts_fsharp "grammars:fsharp"
import ts_gdscript "grammars:gdscript"
import ts_git_config "grammars:git_config"
import ts_git_rebase "grammars:git_rebase"
import ts_gitattributes "grammars:gitattributes"
import ts_gitignore "grammars:gitignore"
import ts_gleam "grammars:gleam"
import ts_glsl "grammars:glsl"
import ts_gn "grammars:gn"
import ts_go "grammars:go"
import ts_godot_resource "grammars:godot_resource"
import ts_gomod "grammars:gomod"
import ts_graphql "grammars:graphql"
import ts_groovy "grammars:groovy"
import ts_hack "grammars:hack"
import ts_hare "grammars:hare"
import ts_haskell "grammars:haskell"
import ts_haxe "grammars:haxe"
import ts_hcl "grammars:hcl"
import ts_heex "grammars:heex"
import ts_hlsl "grammars:hlsl"
import ts_html "grammars:html"
import ts_http "grammars:http"
import ts_hurl "grammars:hurl"
import ts_hyprlang "grammars:hyprlang"
import ts_ini "grammars:ini"
import ts_java "grammars:java"
import ts_javascript "grammars:javascript"
import ts_jinja2 "grammars:jinja2"
import ts_jsdoc "grammars:jsdoc"
import ts_json "grammars:json"
import ts_json5 "grammars:json5"
import ts_jsonnet "grammars:jsonnet"
import ts_julia "grammars:julia"
import ts_just "grammars:just"
import ts_kconfig "grammars:kconfig"
import ts_kdl "grammars:kdl"
import ts_kotlin "grammars:kotlin"
import ts_ledger "grammars:ledger"
import ts_less "grammars:less"
import ts_linkerscript "grammars:linkerscript"
import ts_liquid "grammars:liquid"
import ts_llvm "grammars:llvm"
import ts_lua "grammars:lua"
import ts_luau "grammars:luau"
import ts_make "grammars:make"
import ts_markdown "grammars:markdown"
import ts_markdown_inline "grammars:markdown_inline"
import ts_matlab "grammars:matlab"
import ts_mermaid "grammars:mermaid"
import ts_meson "grammars:meson"
import ts_mojo "grammars:mojo"
import ts_move "grammars:move"
import ts_nginx "grammars:nginx"
import ts_nickel "grammars:nickel"
import ts_nim "grammars:nim"
import ts_ninja "grammars:ninja"
import ts_nix "grammars:nix"
import ts_norg "grammars:norg"
import ts_nushell "grammars:nushell"
import ts_objc "grammars:objc"
import ts_ocaml "grammars:ocaml"
import ts_odin "grammars:odin"
import ts_org "grammars:org"
import ts_pascal "grammars:pascal"
import ts_pem "grammars:pem"
import ts_perl "grammars:perl"
import ts_php "grammars:php"
import ts_pkl "grammars:pkl"
import ts_powershell "grammars:powershell"
import ts_prisma "grammars:prisma"
import ts_prolog "grammars:prolog"
import ts_promql "grammars:promql"
import ts_properties "grammars:properties"
import ts_proto "grammars:proto"
import ts_pug "grammars:pug"
import ts_puppet "grammars:puppet"
import ts_purescript "grammars:purescript"
import ts_python "grammars:python"
import ts_ql "grammars:ql"
import ts_r "grammars:r"
import ts_racket "grammars:racket"
import ts_regex "grammars:regex"
import ts_rego "grammars:rego"
import ts_requirements "grammars:requirements"
import ts_rescript "grammars:rescript"
import ts_robot "grammars:robot"
import ts_rst "grammars:rst"
import ts_ruby "grammars:ruby"
import ts_rust "grammars:rust"
import ts_scala "grammars:scala"
import ts_scheme "grammars:scheme"
import ts_scss "grammars:scss"
import ts_smithy "grammars:smithy"
import ts_solidity "grammars:solidity"
import ts_sparql "grammars:sparql"
import ts_sql "grammars:sql"
import ts_squirrel "grammars:squirrel"
import ts_ssh_config "grammars:ssh_config"
import ts_starlark "grammars:starlark"
import ts_svelte "grammars:svelte"
import ts_swift "grammars:swift"
import ts_tablegen "grammars:tablegen"
import ts_tcl "grammars:tcl"
import ts_teal "grammars:teal"
import ts_templ "grammars:templ"
import ts_textproto "grammars:textproto"
import ts_thrift "grammars:thrift"
import ts_tlaplus "grammars:tlaplus"
import ts_todotxt "grammars:todotxt"
import ts_toml "grammars:toml"
import ts_tsx "grammars:tsx"
import ts_turtle "grammars:turtle"
import ts_typescript "grammars:typescript"
import ts_typst "grammars:typst"
import ts_uxntal "grammars:uxntal"
import ts_v "grammars:v"
import ts_verilog "grammars:verilog"
import ts_vimdoc "grammars:vimdoc"
import ts_vue "grammars:vue"
import ts_wat "grammars:wat"
import ts_wgsl "grammars:wgsl"
import ts_wolfram "grammars:wolfram"
import ts_xml "grammars:xml"
import ts_yaml "grammars:yaml"
import ts_yuck "grammars:yuck"
import ts_zig "grammars:zig"

GRAMMARS :: []Grammar_Entry{
	{name = "ada",                aliases = {"ada2005", "ada95"}, extensions = {".adb", ".ads", ".ada"},
	 language = ts_ada.tree_sitter_ada, tags_query = ts_ada.TAGS},
	{name = "agda",               aliases = {}, extensions = {".agda"},
	 language = ts_agda.tree_sitter_agda, tags_query = ts_agda.TAGS},
	{name = "angular",            aliases = {}, extensions = {},
	 language = ts_angular.tree_sitter_angular, tags_query = ts_angular.TAGS},
	{name = "apex",               aliases = {}, extensions = {".cls", ".trigger", ".apex"},
	 language = ts_apex.tree_sitter_apex, tags_query = ts_apex.TAGS},
	{name = "arduino",            aliases = {}, extensions = {".ino"},
	 language = ts_arduino.tree_sitter_arduino, tags_query = ts_arduino.TAGS},
	{name = "asm",                aliases = {"assembly", "nasm"}, extensions = {".s", ".asm", ".a51", ".i", ".nas", ".nasm"},
	 language = ts_asm.tree_sitter_asm, tags_query = ts_asm.TAGS},
	{name = "astro",              aliases = {}, extensions = {".astro"},
	 language = ts_astro.tree_sitter_astro, tags_query = ts_astro.TAGS},
	{name = "awk",                aliases = {}, extensions = {".awk", ".auk", ".gawk", ".mawk", ".nawk"},
	 language = ts_awk.tree_sitter_awk, tags_query = ts_awk.TAGS},
	{name = "bash",               aliases = {"envrc", "sh", "shell", "shell-script", "zsh"}, extensions = {".sh", ".bash", ".bats", ".cgi", ".command", ".fcgi", ".ksh", ".sbatch", ".sh.in", ".slurm", ".tmux", ".tool", ".zsh", ".zsh-theme"},
	 language = ts_bash.tree_sitter_bash, tags_query = ts_bash.TAGS},
	{name = "bass",               aliases = {}, extensions = {".bass"},
	 language = ts_bass.tree_sitter_bass, tags_query = ts_bass.TAGS},
	{name = "beancount",          aliases = {}, extensions = {".beancount"},
	 language = ts_beancount.tree_sitter_beancount, tags_query = ts_beancount.TAGS},
	{name = "bibtex",             aliases = {}, extensions = {".bib", ".bibtex"},
	 language = ts_bibtex.tree_sitter_bibtex, tags_query = ts_bibtex.TAGS},
	{name = "bicep",              aliases = {}, extensions = {".bicep", ".bicepparam"},
	 language = ts_bicep.tree_sitter_bicep, tags_query = ts_bicep.TAGS},
	{name = "bitbake",            aliases = {}, extensions = {".bb", ".bbappend", ".bbclass"},
	 language = ts_bitbake.tree_sitter_bitbake, tags_query = ts_bitbake.TAGS},
	{name = "blade",              aliases = {}, extensions = {".blade.php", ".blade"},
	 language = ts_blade.tree_sitter_blade, tags_query = ts_blade.TAGS},
	{name = "c",                  aliases = {}, extensions = {".c", ".h", ".cats", ".h.in", ".idc"},
	 language = ts_c.tree_sitter_c, tags_query = ts_c.TAGS},
	{name = "c_sharp",            aliases = {"c#", "cake", "cakescript", "cs", "csharp"}, extensions = {".cs", ".cake", ".cs.pp", ".csx", ".linq"},
	 language = ts_c_sharp.tree_sitter_c_sharp, tags_query = ts_c_sharp.TAGS},
	{name = "cairo",              aliases = {}, extensions = {".cairo"},
	 language = ts_cairo.tree_sitter_cairo, tags_query = ts_cairo.TAGS},
	{name = "capnp",              aliases = {"cap'n proto"}, extensions = {".capnp"},
	 language = ts_capnp.tree_sitter_capnp, tags_query = ts_capnp.TAGS},
	{name = "chatito",            aliases = {}, extensions = {".chatito"},
	 language = ts_chatito.tree_sitter_chatito, tags_query = ts_chatito.TAGS},
	{name = "circom",             aliases = {}, extensions = {".circom"},
	 language = ts_circom.tree_sitter_circom, tags_query = ts_circom.TAGS},
	{name = "cmake",              aliases = {}, extensions = {".cmake", ".cmake.in"},
	 language = ts_cmake.tree_sitter_cmake, tags_query = ts_cmake.TAGS},
	{name = "cobol",              aliases = {}, extensions = {".cob", ".cbl", ".cpy", ".ccp", ".cobol"},
	 language = ts_cobol.tree_sitter_COBOL, tags_query = ts_cobol.TAGS},
	{name = "comment",            aliases = {}, extensions = {},
	 language = ts_comment.tree_sitter_comment, tags_query = ts_comment.TAGS},
	{name = "commonlisp",         aliases = {"common lisp", "lisp"}, extensions = {".cl", ".lisp", ".lsp", ".asd", ".l", ".ny", ".podsl", ".sexp"},
	 language = ts_commonlisp.tree_sitter_commonlisp, tags_query = ts_commonlisp.TAGS},
	{name = "cpon",               aliases = {}, extensions = {".cpon"},
	 language = ts_cpon.tree_sitter_cpon, tags_query = ts_cpon.TAGS},
	{name = "cpp",                aliases = {"c++", "cxx"}, extensions = {".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".c++", ".cp", ".cppm", ".h++", ".inl", ".ipp", ".ixx", ".re", ".tcc", ".tpp", ".txx"},
	 language = ts_cpp.tree_sitter_cpp, tags_query = ts_cpp.TAGS},
	{name = "crystal",            aliases = {}, extensions = {".cr"},
	 language = ts_crystal.tree_sitter_crystal, tags_query = ts_crystal.TAGS},
	{name = "css",                aliases = {}, extensions = {".css"},
	 language = ts_css.tree_sitter_css, tags_query = ts_css.TAGS},
	{name = "csv",                aliases = {}, extensions = {".csv", ".tsv"},
	 language = ts_csv.tree_sitter_csv, tags_query = ts_csv.TAGS},
	{name = "cuda",               aliases = {}, extensions = {".cu", ".cuh"},
	 language = ts_cuda.tree_sitter_cuda, tags_query = ts_cuda.TAGS},
	{name = "cue",                aliases = {}, extensions = {".cue"},
	 language = ts_cue.tree_sitter_cue, tags_query = ts_cue.TAGS},
	{name = "cylc",               aliases = {}, extensions = {".cylc"},
	 language = ts_cylc.tree_sitter_cylc, tags_query = ts_cylc.TAGS},
	{name = "d",                  aliases = {"dlang"}, extensions = {".d", ".di"},
	 language = ts_d.tree_sitter_d, tags_query = ts_d.TAGS},
	{name = "dart",               aliases = {}, extensions = {".dart"},
	 language = ts_dart.tree_sitter_dart, tags_query = ts_dart.TAGS},
	{name = "desktop",            aliases = {}, extensions = {".desktop", ".desktop.in", ".service"},
	 language = ts_desktop.tree_sitter_desktop, tags_query = ts_desktop.TAGS},
	{name = "devicetree",         aliases = {}, extensions = {".dts", ".dtsi"},
	 language = ts_devicetree.tree_sitter_devicetree, tags_query = ts_devicetree.TAGS},
	{name = "dhall",              aliases = {}, extensions = {".dhall"},
	 language = ts_dhall.tree_sitter_dhall, tags_query = ts_dhall.TAGS},
	{name = "diff",               aliases = {"udiff"}, extensions = {".diff", ".patch"},
	 language = ts_diff.tree_sitter_diff, tags_query = ts_diff.TAGS},
	{name = "djot",               aliases = {}, extensions = {".djot"},
	 language = ts_djot.tree_sitter_djot, tags_query = ts_djot.TAGS},
	{name = "dockerfile",         aliases = {"containerfile"}, extensions = {".containerfile", ".dockerfile"},
	 language = ts_dockerfile.tree_sitter_dockerfile, tags_query = ts_dockerfile.TAGS},
	{name = "dot",                aliases = {"graphviz (dot)"}, extensions = {".dot", ".gv"},
	 language = ts_dot.tree_sitter_dot, tags_query = ts_dot.TAGS},
	{name = "doxygen",            aliases = {}, extensions = {},
	 language = ts_doxygen.tree_sitter_doxygen, tags_query = ts_doxygen.TAGS},
	{name = "dtd",                aliases = {}, extensions = {".dtd"},
	 language = ts_dtd.tree_sitter_dtd, tags_query = ts_dtd.TAGS},
	{name = "earthfile",          aliases = {"earthly"}, extensions = {},
	 language = ts_earthfile.tree_sitter_earthfile, tags_query = ts_earthfile.TAGS},
	{name = "editorconfig",       aliases = {"editor-config"}, extensions = {".editorconfig"},
	 language = ts_editorconfig.tree_sitter_editorconfig, tags_query = ts_editorconfig.TAGS},
	{name = "elisp",              aliases = {"cask", "eask", "emacs", "emacs lisp"}, extensions = {".el", ".emacs", ".emacs.desktop"},
	 language = ts_elisp.tree_sitter_elisp, tags_query = ts_elisp.TAGS},
	{name = "elixir",             aliases = {}, extensions = {".ex", ".exs"},
	 language = ts_elixir.tree_sitter_elixir, tags_query = ts_elixir.TAGS},
	{name = "elm",                aliases = {}, extensions = {".elm"},
	 language = ts_elm.tree_sitter_elm, tags_query = ts_elm.TAGS},
	{name = "embedded_template",  aliases = {"erb", "html+erb", "html+ruby", "rhtml"}, extensions = {".erb", ".ejs", ".erb.deface", ".rhtml"},
	 language = ts_embedded_template.tree_sitter_embedded_template, tags_query = ts_embedded_template.TAGS},
	{name = "enforce",            aliases = {}, extensions = {".enf"},
	 language = ts_enforce.tree_sitter_enforce, tags_query = ts_enforce.TAGS},
	{name = "erlang",             aliases = {}, extensions = {".erl", ".hrl", ".app", ".app.src", ".escript", ".xrl", ".yrl"},
	 language = ts_erlang.tree_sitter_erlang, tags_query = ts_erlang.TAGS},
	{name = "faust",              aliases = {}, extensions = {".dsp"},
	 language = ts_faust.tree_sitter_faust, tags_query = ts_faust.TAGS},
	{name = "fennel",             aliases = {}, extensions = {".fnl"},
	 language = ts_fennel.tree_sitter_fennel, tags_query = ts_fennel.TAGS},
	{name = "fidl",               aliases = {}, extensions = {".fidl"},
	 language = ts_fidl.tree_sitter_fidl, tags_query = ts_fidl.TAGS},
	{name = "firrtl",             aliases = {}, extensions = {".fir"},
	 language = ts_firrtl.tree_sitter_firrtl, tags_query = ts_firrtl.TAGS},
	{name = "fish",               aliases = {}, extensions = {".fish"},
	 language = ts_fish.tree_sitter_fish, tags_query = ts_fish.TAGS},
	{name = "foam",               aliases = {}, extensions = {},
	 language = ts_foam.tree_sitter_foam, tags_query = ts_foam.TAGS},
	{name = "forth",              aliases = {}, extensions = {".fs", ".fth", ".4th", ".forth", ".fr", ".frt"},
	 language = ts_forth.tree_sitter_forth, tags_query = ts_forth.TAGS},
	{name = "fortran",            aliases = {}, extensions = {".f", ".f90", ".f95", ".f03", ".f08", ".f77", ".for", ".fpp"},
	 language = ts_fortran.tree_sitter_fortran, tags_query = ts_fortran.TAGS},
	{name = "fsharp",             aliases = {"f#"}, extensions = {".fsi", ".fsx"},
	 language = ts_fsharp.tree_sitter_fsharp, tags_query = ts_fsharp.TAGS},
	{name = "gdscript",           aliases = {}, extensions = {".gd"},
	 language = ts_gdscript.tree_sitter_gdscript, tags_query = ts_gdscript.TAGS},
	{name = "git_config",         aliases = {"git config", "gitconfig", "gitmodules"}, extensions = {".gitconfig"},
	 language = ts_git_config.tree_sitter_git_config, tags_query = ts_git_config.TAGS},
	{name = "git_rebase",         aliases = {"git rebase"}, extensions = {},
	 language = ts_git_rebase.tree_sitter_git_rebase, tags_query = ts_git_rebase.TAGS},
	{name = "gitattributes",      aliases = {}, extensions = {".gitattributes"},
	 language = ts_gitattributes.tree_sitter_gitattributes, tags_query = ts_gitattributes.TAGS},
	{name = "gitignore",          aliases = {}, extensions = {".gitignore"},
	 language = ts_gitignore.tree_sitter_gitignore, tags_query = ts_gitignore.TAGS},
	{name = "gleam",              aliases = {}, extensions = {".gleam"},
	 language = ts_gleam.tree_sitter_gleam, tags_query = ts_gleam.TAGS},
	{name = "glsl",               aliases = {}, extensions = {".glsl", ".vert", ".frag", ".fp", ".frg", ".fsh", ".fshader", ".geo", ".geom", ".glslf", ".glslv", ".gshader", ".rchit", ".rmiss", ".shader", ".tesc", ".tese", ".vrx", ".vs", ".vshader"},
	 language = ts_glsl.tree_sitter_glsl, tags_query = ts_glsl.TAGS},
	{name = "gn",                 aliases = {}, extensions = {".gn", ".gni"},
	 language = ts_gn.tree_sitter_gn, tags_query = ts_gn.TAGS},
	{name = "go",                 aliases = {"golang"}, extensions = {".go"},
	 language = ts_go.tree_sitter_go, tags_query = ts_go.TAGS},
	{name = "godot_resource",     aliases = {"godot resource"}, extensions = {".tres", ".tscn", ".gdnlib", ".gdns"},
	 language = ts_godot_resource.tree_sitter_godot_resource, tags_query = ts_godot_resource.TAGS},
	{name = "gomod",              aliases = {"go mod", "go module", "go.mod"}, extensions = {},
	 language = ts_gomod.tree_sitter_gomod, tags_query = ts_gomod.TAGS},
	{name = "graphql",            aliases = {}, extensions = {".graphql", ".gql", ".graphqls"},
	 language = ts_graphql.tree_sitter_graphql, tags_query = ts_graphql.TAGS},
	{name = "groovy",             aliases = {}, extensions = {".groovy", ".gvy", ".grt", ".gtpl"},
	 language = ts_groovy.tree_sitter_groovy, tags_query = ts_groovy.TAGS},
	{name = "hack",               aliases = {}, extensions = {".hack", ".hhi"},
	 language = ts_hack.tree_sitter_hack, tags_query = ts_hack.TAGS},
	{name = "hare",               aliases = {}, extensions = {".ha"},
	 language = ts_hare.tree_sitter_hare, tags_query = ts_hare.TAGS},
	{name = "haskell",            aliases = {}, extensions = {".hs", ".lhs", ".hs-boot", ".hsc"},
	 language = ts_haskell.tree_sitter_haskell, tags_query = ts_haskell.TAGS},
	{name = "haxe",               aliases = {}, extensions = {".hx", ".hxsl"},
	 language = ts_haxe.tree_sitter_haxe, tags_query = ts_haxe.TAGS},
	{name = "hcl",                aliases = {"hashicorp configuration language", "opentofu", "terraform"}, extensions = {".hcl", ".tf", ".tfvars", ".nomad", ".tofu", ".workflow"},
	 language = ts_hcl.tree_sitter_hcl, tags_query = ts_hcl.TAGS},
	{name = "heex",               aliases = {"eex", "html+eex", "leex"}, extensions = {".heex"},
	 language = ts_heex.tree_sitter_heex, tags_query = ts_heex.TAGS},
	{name = "hlsl",               aliases = {}, extensions = {".hlsl", ".fx", ".cginc", ".fxh", ".hlsli"},
	 language = ts_hlsl.tree_sitter_hlsl, tags_query = ts_hlsl.TAGS},
	{name = "html",               aliases = {"xhtml"}, extensions = {".html", ".htm", ".hta", ".html.hl", ".xht", ".xhtml"},
	 language = ts_html.tree_sitter_html, tags_query = ts_html.TAGS},
	{name = "http",               aliases = {}, extensions = {".http"},
	 language = ts_http.tree_sitter_http, tags_query = ts_http.TAGS},
	{name = "hurl",               aliases = {}, extensions = {".hurl"},
	 language = ts_hurl.tree_sitter_hurl, tags_query = ts_hurl.TAGS},
	{name = "hyprlang",           aliases = {}, extensions = {".conf"},
	 language = ts_hyprlang.tree_sitter_hyprlang, tags_query = ts_hyprlang.TAGS},
	{name = "ini",                aliases = {"dosini"}, extensions = {".ini", ".cfg", ".cnf", ".dof", ".frm", ".lektorproject", ".prefs", ".url"},
	 language = ts_ini.tree_sitter_ini, tags_query = ts_ini.TAGS},
	{name = "java",               aliases = {}, extensions = {".java", ".jav", ".jsh"},
	 language = ts_java.tree_sitter_java, tags_query = ts_java.TAGS},
	{name = "javascript",         aliases = {"js", "node"}, extensions = {".js", ".jsx", ".mjs", ".cjs", "._js", ".bones", ".es", ".es6", ".gs", ".jake", ".javascript", ".jsb", ".jscad", ".jsfl", ".jslib", ".jsm", ".jspre", ".jss", ".njs", ".pac", ".sjs", ".ssjs", ".xsjs", ".xsjslib"},
	 language = ts_javascript.tree_sitter_javascript, tags_query = ts_javascript.TAGS},
	{name = "jinja2",             aliases = {"django", "html+django", "html+jinja", "htmldjango", "jinja"}, extensions = {".j2", ".jinja2", ".jinja"},
	 language = ts_jinja2.tree_sitter_jinja2, tags_query = ts_jinja2.TAGS},
	{name = "jsdoc",              aliases = {}, extensions = {},
	 language = ts_jsdoc.tree_sitter_jsdoc, tags_query = ts_jsdoc.TAGS},
	{name = "json",               aliases = {"geojson", "jsonl", "sarif", "topojson"}, extensions = {".json", ".4dform", ".4dproject", ".avsc", ".geojson", ".gltf", ".har", ".ice", ".json-tmlanguage", ".json.example", ".jsonl", ".mcmeta", ".sarif", ".tact", ".tfstate", ".tfstate.backup", ".topojson", ".webapp", ".webmanifest", ".yy", ".yyp"},
	 language = ts_json.tree_sitter_json, tags_query = ts_json.TAGS},
	{name = "json5",              aliases = {}, extensions = {".json5", ".jsonc"},
	 language = ts_json5.tree_sitter_json5, tags_query = ts_json5.TAGS},
	{name = "jsonnet",            aliases = {}, extensions = {".jsonnet", ".libsonnet"},
	 language = ts_jsonnet.tree_sitter_jsonnet, tags_query = ts_jsonnet.TAGS},
	{name = "julia",              aliases = {}, extensions = {".jl"},
	 language = ts_julia.tree_sitter_julia, tags_query = ts_julia.TAGS},
	{name = "just",               aliases = {"justfile"}, extensions = {".just"},
	 language = ts_just.tree_sitter_just, tags_query = ts_just.TAGS},
	{name = "kconfig",            aliases = {}, extensions = {},
	 language = ts_kconfig.tree_sitter_kconfig, tags_query = ts_kconfig.TAGS},
	{name = "kdl",                aliases = {}, extensions = {".kdl"},
	 language = ts_kdl.tree_sitter_kdl, tags_query = ts_kdl.TAGS},
	{name = "kotlin",             aliases = {}, extensions = {".kt", ".kts", ".ktm"},
	 language = ts_kotlin.tree_sitter_kotlin, tags_query = ts_kotlin.TAGS},
	{name = "ledger",             aliases = {}, extensions = {".ledger", ".journal"},
	 language = ts_ledger.tree_sitter_ledger, tags_query = ts_ledger.TAGS},
	{name = "less",               aliases = {"less-css"}, extensions = {".less"},
	 language = ts_less.tree_sitter_less, tags_query = ts_less.TAGS},
	{name = "linkerscript",       aliases = {"linker script"}, extensions = {".ld", ".lds", ".x"},
	 language = ts_linkerscript.tree_sitter_linkerscript, tags_query = ts_linkerscript.TAGS},
	{name = "liquid",             aliases = {}, extensions = {".liquid"},
	 language = ts_liquid.tree_sitter_liquid, tags_query = ts_liquid.TAGS},
	{name = "llvm",               aliases = {}, extensions = {".ll"},
	 language = ts_llvm.tree_sitter_llvm, tags_query = ts_llvm.TAGS},
	{name = "lua",                aliases = {}, extensions = {".lua", ".nse", ".p8", ".pd_lua", ".rbxs", ".rockspec", ".wlua"},
	 language = ts_lua.tree_sitter_lua, tags_query = ts_lua.TAGS},
	{name = "luau",               aliases = {}, extensions = {".luau"},
	 language = ts_luau.tree_sitter_luau, tags_query = ts_luau.TAGS},
	{name = "make",               aliases = {"bsdmake", "makefile", "mf"}, extensions = {".mk", ".mak", ".make", ".makefile", ".mkfile"},
	 language = ts_make.tree_sitter_make, tags_query = ts_make.TAGS},
	{name = "markdown",           aliases = {"md", "pandoc"}, extensions = {".md", ".markdown", ".livemd", ".mdown", ".mdwn", ".mkd", ".mkdn", ".mkdown", ".ronn", ".scd", ".workbook"},
	 language = ts_markdown.tree_sitter_markdown, tags_query = ts_markdown.TAGS},
	{name = "markdown_inline",    aliases = {}, extensions = {},
	 language = ts_markdown_inline.tree_sitter_markdown_inline, tags_query = ts_markdown_inline.TAGS},
	{name = "matlab",             aliases = {"octave"}, extensions = {".mat", ".matlab"},
	 language = ts_matlab.tree_sitter_matlab, tags_query = ts_matlab.TAGS},
	{name = "mermaid",            aliases = {"mermaid example"}, extensions = {".mmd", ".mermaid"},
	 language = ts_mermaid.tree_sitter_mermaid, tags_query = ts_mermaid.TAGS},
	{name = "meson",              aliases = {}, extensions = {},
	 language = ts_meson.tree_sitter_meson, tags_query = ts_meson.TAGS},
	{name = "mojo",               aliases = {}, extensions = {".mojo", ".🔥"},
	 language = ts_mojo.tree_sitter_mojo, tags_query = ts_mojo.TAGS},
	{name = "move",               aliases = {}, extensions = {".move"},
	 language = ts_move.tree_sitter_move_on_aptos, tags_query = ts_move.TAGS},
	{name = "nginx",              aliases = {"nginx configuration file"}, extensions = {".nginx", ".nginxconf", ".vhost"},
	 language = ts_nginx.tree_sitter_nginx, tags_query = ts_nginx.TAGS},
	{name = "nickel",             aliases = {}, extensions = {".ncl"},
	 language = ts_nickel.tree_sitter_nickel, tags_query = ts_nickel.TAGS},
	{name = "nim",                aliases = {}, extensions = {".nim", ".nims", ".nim.cfg", ".nimble", ".nimrod"},
	 language = ts_nim.tree_sitter_nim, tags_query = ts_nim.TAGS},
	{name = "ninja",              aliases = {}, extensions = {".ninja"},
	 language = ts_ninja.tree_sitter_ninja, tags_query = ts_ninja.TAGS},
	{name = "nix",                aliases = {"nixos"}, extensions = {".nix"},
	 language = ts_nix.tree_sitter_nix, tags_query = ts_nix.TAGS},
	{name = "norg",               aliases = {}, extensions = {".norg"},
	 language = ts_norg.tree_sitter_norg, tags_query = ts_norg.TAGS},
	{name = "nushell",            aliases = {"nu", "nush"}, extensions = {".nu"},
	 language = ts_nushell.tree_sitter_nu, tags_query = ts_nushell.TAGS},
	{name = "objc",               aliases = {"obj-c", "objective-c", "objectivec"}, extensions = {".m", ".mm"},
	 language = ts_objc.tree_sitter_objc, tags_query = ts_objc.TAGS},
	{name = "ocaml",              aliases = {}, extensions = {".ml", ".mli", ".eliom", ".eliomi", ".ml4", ".mll", ".mly"},
	 language = ts_ocaml.tree_sitter_ocaml, tags_query = ts_ocaml.TAGS},
	{name = "odin",               aliases = {"odin-lang", "odinlang"}, extensions = {".odin"},
	 language = ts_odin.tree_sitter_odin, tags_query = ts_odin.TAGS},
	{name = "org",                aliases = {}, extensions = {".org"},
	 language = ts_org.tree_sitter_org, tags_query = ts_org.TAGS},
	{name = "pascal",             aliases = {"delphi", "objectpascal"}, extensions = {".pas", ".pp", ".inc", ".dfm", ".dpr", ".lpr", ".pascal"},
	 language = ts_pascal.tree_sitter_pascal, tags_query = ts_pascal.TAGS},
	{name = "pem",                aliases = {}, extensions = {".pem"},
	 language = ts_pem.tree_sitter_pem, tags_query = ts_pem.TAGS},
	{name = "perl",               aliases = {"cperl"}, extensions = {".pl", ".pm", ".al", ".perl", ".ph", ".plx", ".psgi", ".t"},
	 language = ts_perl.tree_sitter_perl, tags_query = ts_perl.TAGS},
	{name = "php",                aliases = {"inc"}, extensions = {".php", ".aw", ".ctp", ".php3", ".php4", ".php5", ".phps", ".phpt"},
	 language = ts_php.tree_sitter_php, tags_query = ts_php.TAGS},
	{name = "pkl",                aliases = {}, extensions = {".pkl"},
	 language = ts_pkl.tree_sitter_pkl, tags_query = ts_pkl.TAGS},
	{name = "powershell",         aliases = {"posh", "pwsh"}, extensions = {".ps1", ".psm1", ".psd1"},
	 language = ts_powershell.tree_sitter_powershell, tags_query = ts_powershell.TAGS},
	{name = "prisma",             aliases = {}, extensions = {".prisma"},
	 language = ts_prisma.tree_sitter_prisma, tags_query = ts_prisma.TAGS},
	{name = "prolog",             aliases = {}, extensions = {".pro", ".plt", ".prolog", ".yap"},
	 language = ts_prolog.tree_sitter_prolog, tags_query = ts_prolog.TAGS},
	{name = "promql",             aliases = {}, extensions = {".promql"},
	 language = ts_promql.tree_sitter_promql, tags_query = ts_promql.TAGS},
	{name = "properties",         aliases = {"java properties"}, extensions = {".properties"},
	 language = ts_properties.tree_sitter_properties, tags_query = ts_properties.TAGS},
	{name = "proto",              aliases = {"protobuf", "protocol buffer", "protocol buffers"}, extensions = {".proto"},
	 language = ts_proto.tree_sitter_proto, tags_query = ts_proto.TAGS},
	{name = "pug",                aliases = {}, extensions = {".pug", ".jade"},
	 language = ts_pug.tree_sitter_pug, tags_query = ts_pug.TAGS},
	{name = "puppet",             aliases = {}, extensions = {},
	 language = ts_puppet.tree_sitter_puppet, tags_query = ts_puppet.TAGS},
	{name = "purescript",         aliases = {}, extensions = {".purs"},
	 language = ts_purescript.tree_sitter_purescript, tags_query = ts_purescript.TAGS},
	{name = "python",             aliases = {"py", "py3", "python3", "rusthon"}, extensions = {".py", ".gyp", ".gypi", ".lmi", ".py3", ".pyde", ".pyi", ".pyp", ".pyt", ".pyw", ".rpy", ".spec", ".tac", ".wsgi", ".xpy"},
	 language = ts_python.tree_sitter_python, tags_query = ts_python.TAGS},
	{name = "ql",                 aliases = {"codeql"}, extensions = {".ql", ".qll"},
	 language = ts_ql.tree_sitter_ql, tags_query = ts_ql.TAGS},
	{name = "r",                  aliases = {"rscript", "splus"}, extensions = {".r", ".rd", ".rsx"},
	 language = ts_r.tree_sitter_r, tags_query = ts_r.TAGS},
	{name = "racket",             aliases = {}, extensions = {".rkt", ".rktd", ".rktl", ".scrbl"},
	 language = ts_racket.tree_sitter_racket, tags_query = ts_racket.TAGS},
	{name = "regex",              aliases = {}, extensions = {".regex"},
	 language = ts_regex.tree_sitter_regex, tags_query = ts_regex.TAGS},
	{name = "rego",               aliases = {"open policy agent"}, extensions = {".rego"},
	 language = ts_rego.tree_sitter_rego, tags_query = ts_rego.TAGS},
	{name = "requirements",       aliases = {"pip requirements"}, extensions = {},
	 language = ts_requirements.tree_sitter_requirements, tags_query = ts_requirements.TAGS},
	{name = "rescript",           aliases = {}, extensions = {".res", ".resi"},
	 language = ts_rescript.tree_sitter_rescript, tags_query = ts_rescript.TAGS},
	{name = "robot",              aliases = {"robotframework"}, extensions = {".robot", ".resource"},
	 language = ts_robot.tree_sitter_robot, tags_query = ts_robot.TAGS},
	{name = "rst",                aliases = {"restructuredtext"}, extensions = {".rst", ".rest", ".rest.txt", ".rst.txt"},
	 language = ts_rst.tree_sitter_rst, tags_query = ts_rst.TAGS},
	{name = "ruby",               aliases = {"jruby", "macruby", "rake", "rb", "rbx"}, extensions = {".rb", ".builder", ".eye", ".gemspec", ".god", ".jbuilder", ".mspec", ".pluginspec", ".podspec", ".prawn", ".rabl", ".rake", ".rbi", ".rbuild", ".rbw", ".rbx", ".ru", ".ruby", ".thor", ".watchr"},
	 language = ts_ruby.tree_sitter_ruby, tags_query = ts_ruby.TAGS},
	{name = "rust",               aliases = {"rs"}, extensions = {".rs", ".rs.in"},
	 language = ts_rust.tree_sitter_rust, tags_query = ts_rust.TAGS},
	{name = "scala",              aliases = {}, extensions = {".scala", ".kojo", ".sbt", ".sc"},
	 language = ts_scala.tree_sitter_scala, tags_query = ts_scala.TAGS},
	{name = "scheme",             aliases = {}, extensions = {".scm", ".ss", ".sld", ".sls", ".sps"},
	 language = ts_scheme.tree_sitter_scheme, tags_query = ts_scheme.TAGS},
	{name = "scss",               aliases = {}, extensions = {".scss"},
	 language = ts_scss.tree_sitter_scss, tags_query = ts_scss.TAGS},
	{name = "smithy",             aliases = {}, extensions = {".smithy"},
	 language = ts_smithy.tree_sitter_smithy, tags_query = ts_smithy.TAGS},
	{name = "solidity",           aliases = {}, extensions = {".sol"},
	 language = ts_solidity.tree_sitter_solidity, tags_query = ts_solidity.TAGS},
	{name = "sparql",             aliases = {}, extensions = {".rq", ".sparql"},
	 language = ts_sparql.tree_sitter_sparql, tags_query = ts_sparql.TAGS},
	{name = "sql",                aliases = {}, extensions = {".sql", ".ddl", ".mysql", ".prc", ".tab", ".udf", ".viw"},
	 language = ts_sql.tree_sitter_sql, tags_query = ts_sql.TAGS},
	{name = "squirrel",           aliases = {}, extensions = {".nut"},
	 language = ts_squirrel.tree_sitter_squirrel, tags_query = ts_squirrel.TAGS},
	{name = "ssh_config",         aliases = {}, extensions = {},
	 language = ts_ssh_config.tree_sitter_ssh_config, tags_query = ts_ssh_config.TAGS},
	{name = "starlark",           aliases = {"bazel", "bzl"}, extensions = {".star", ".bzl"},
	 language = ts_starlark.tree_sitter_starlark, tags_query = ts_starlark.TAGS},
	{name = "svelte",             aliases = {}, extensions = {".svelte"},
	 language = ts_svelte.tree_sitter_svelte, tags_query = ts_svelte.TAGS},
	{name = "swift",              aliases = {}, extensions = {".swift"},
	 language = ts_swift.tree_sitter_swift, tags_query = ts_swift.TAGS},
	{name = "tablegen",           aliases = {}, extensions = {".td"},
	 language = ts_tablegen.tree_sitter_tablegen, tags_query = ts_tablegen.TAGS},
	{name = "tcl",                aliases = {"sdc", "xdc"}, extensions = {".tcl", ".adp", ".sdc", ".tcl.in", ".tm", ".xdc"},
	 language = ts_tcl.tree_sitter_tcl, tags_query = ts_tcl.TAGS},
	{name = "teal",               aliases = {}, extensions = {".tl"},
	 language = ts_teal.tree_sitter_teal, tags_query = ts_teal.TAGS},
	{name = "templ",              aliases = {}, extensions = {".templ"},
	 language = ts_templ.tree_sitter_templ, tags_query = ts_templ.TAGS},
	{name = "textproto",          aliases = {"protobuf text format", "protocol buffer text format", "text proto"}, extensions = {".textproto", ".txtpb", ".pbtxt", ".pbt"},
	 language = ts_textproto.tree_sitter_textproto, tags_query = ts_textproto.TAGS},
	{name = "thrift",             aliases = {}, extensions = {".thrift"},
	 language = ts_thrift.tree_sitter_thrift, tags_query = ts_thrift.TAGS},
	{name = "tlaplus",            aliases = {"tla"}, extensions = {".tla"},
	 language = ts_tlaplus.tree_sitter_tlaplus, tags_query = ts_tlaplus.TAGS},
	{name = "todotxt",            aliases = {}, extensions = {},
	 language = ts_todotxt.tree_sitter_todotxt, tags_query = ts_todotxt.TAGS},
	{name = "toml",               aliases = {}, extensions = {".toml", ".toml.example"},
	 language = ts_toml.tree_sitter_toml, tags_query = ts_toml.TAGS},
	{name = "tsx",                aliases = {"typescriptreact"}, extensions = {".tsx"},
	 language = ts_tsx.tree_sitter_tsx, tags_query = ts_tsx.TAGS},
	{name = "turtle",             aliases = {}, extensions = {".ttl"},
	 language = ts_turtle.tree_sitter_turtle, tags_query = ts_turtle.TAGS},
	{name = "typescript",         aliases = {"ts"}, extensions = {".ts", ".cts", ".mts"},
	 language = ts_typescript.tree_sitter_typescript, tags_query = ts_typescript.TAGS},
	{name = "typst",              aliases = {"typ"}, extensions = {".typ"},
	 language = ts_typst.tree_sitter_typst, tags_query = ts_typst.TAGS},
	{name = "uxntal",             aliases = {}, extensions = {".tal"},
	 language = ts_uxntal.tree_sitter_uxntal, tags_query = ts_uxntal.TAGS},
	{name = "v",                  aliases = {"vlang"}, extensions = {".v", ".vsh"},
	 language = ts_v.tree_sitter_v, tags_query = ts_v.TAGS},
	{name = "verilog",            aliases = {}, extensions = {".sv", ".svh", ".veo"},
	 language = ts_verilog.tree_sitter_verilog, tags_query = ts_verilog.TAGS},
	{name = "vimdoc",             aliases = {"help", "vim help file", "vimhelp"}, extensions = {},
	 language = ts_vimdoc.tree_sitter_vimdoc, tags_query = ts_vimdoc.TAGS},
	{name = "vue",                aliases = {}, extensions = {".vue"},
	 language = ts_vue.tree_sitter_vue, tags_query = ts_vue.TAGS},
	{name = "wat",                aliases = {"wasm", "wast", "webassembly"}, extensions = {".wat", ".wast"},
	 language = ts_wat.tree_sitter_wat, tags_query = ts_wat.TAGS},
	{name = "wgsl",               aliases = {}, extensions = {".wgsl"},
	 language = ts_wgsl.tree_sitter_wgsl, tags_query = ts_wgsl.TAGS},
	{name = "wolfram",            aliases = {"mathematica", "mma", "wl", "wolfram lang", "wolfram language"}, extensions = {".wl", ".nb", ".cdf", ".ma", ".mathematica", ".mt", ".nbp", ".wls", ".wlt"},
	 language = ts_wolfram.tree_sitter_wolfram, tags_query = ts_wolfram.TAGS},
	{name = "xml",                aliases = {"rss", "wsdl", "xsd"}, extensions = {".xml", ".adml", ".admx", ".ant", ".axaml", ".axml", ".builds", ".ccproj", ".ccxml", ".clixml", ".cproject", ".cscfg", ".csdef", ".csl", ".csproj", ".ct", ".depproj", ".dita", ".ditamap", ".ditaval", ".dll.config", ".dotsettings", ".filters", ".fsproj", ".fxml", ".glade", ".gml", ".gmx", ".gpx", ".grxml", ".gst", ".hzp", ".iml", ".ivy", ".jelly", ".jsproj", ".kml", ".launch", ".mdpolicy", ".mjml", ".mm", ".mod", ".mxml", ".natvis", ".ndproj", ".nproj", ".nuspec", ".odd", ".osm", ".pkgproj", ".proj", ".props", ".ps1xml", ".psc1", ".pt", ".pubxml", ".qhelp", ".rdf", ".resx", ".rss", ".sch", ".scxml", ".sfproj", ".shproj", ".slnx", ".srdf", ".storyboard", ".sublime-snippet", ".sw", ".targets", ".tml", ".ui", ".urdf", ".ux", ".vbproj", ".vcxproj", ".vsixmanifest", ".vssettings", ".vstemplate", ".vxml", ".wixproj", ".wsdl", ".wsf", ".wxi", ".wxl", ".wxs", ".x3d", ".xacro", ".xaml", ".xib", ".xlf", ".xliff", ".xmi", ".xml.dist", ".xmp", ".xproj", ".xsd", ".xspec", ".xul", ".zcml"},
	 language = ts_xml.tree_sitter_xml, tags_query = ts_xml.TAGS},
	{name = "yaml",               aliases = {"yml"}, extensions = {".yaml", ".yml", ".mir", ".reek", ".rviz", ".sublime-syntax", ".syntax", ".yaml-tmlanguage", ".yaml.sed", ".yml.mysql"},
	 language = ts_yaml.tree_sitter_yaml, tags_query = ts_yaml.TAGS},
	{name = "yuck",               aliases = {}, extensions = {".yuck"},
	 language = ts_yuck.tree_sitter_yuck, tags_query = ts_yuck.TAGS},
	{name = "zig",                aliases = {}, extensions = {".zig", ".zig.zon"},
	 language = ts_zig.tree_sitter_zig, tags_query = ts_zig.TAGS},
}

// Linguist exact-filename claims (the detection tier checked before
// extensions: Makefile, Dockerfile, .bashrc, ...) and shebang
// interpreter claims (#!/usr/bin/env python3 -> python3), filtered to
// registered grammars and sorted by key.
LINGUIST_FILENAMES :: []Linguist_Claim{
	{key = ".JUSTFILE", grammar = "just"},
	{key = ".Justfile", grammar = "just"},
	{key = ".Rprofile", grammar = "r"},
	{key = ".abbrev_defs", grammar = "elisp"},
	{key = ".all-contributorsrc", grammar = "json"},
	{key = ".arcconfig", grammar = "json"},
	{key = ".auto-changelog", grammar = "json"},
	{key = ".bash_aliases", grammar = "bash"},
	{key = ".bash_functions", grammar = "bash"},
	{key = ".bash_history", grammar = "bash"},
	{key = ".bash_logout", grammar = "bash"},
	{key = ".bash_profile", grammar = "bash"},
	{key = ".bashrc", grammar = "bash"},
	{key = ".buckconfig", grammar = "ini"},
	{key = ".c8rc", grammar = "json"},
	{key = ".clang-format", grammar = "yaml"},
	{key = ".clang-tidy", grammar = "yaml"},
	{key = ".clangd", grammar = "yaml"},
	{key = ".classpath", grammar = "xml"},
	{key = ".coveragerc", grammar = "ini"},
	{key = ".cproject", grammar = "xml"},
	{key = ".cshrc", grammar = "bash"},
	{key = ".editorconfig", grammar = "editorconfig"},
	{key = ".emacs", grammar = "elisp"},
	{key = ".emacs.desktop", grammar = "elisp"},
	{key = ".envrc", grammar = "bash"},
	{key = ".flake8", grammar = "ini"},
	{key = ".flaskenv", grammar = "bash"},
	{key = ".gclient", grammar = "python"},
	{key = ".gemrc", grammar = "yaml"},
	{key = ".gitconfig", grammar = "git_config"},
	{key = ".gitmodules", grammar = "git_config"},
	{key = ".gn", grammar = "gn"},
	{key = ".gnus", grammar = "elisp"},
	{key = ".htmlhintrc", grammar = "json"},
	{key = ".imgbotconfig", grammar = "json"},
	{key = ".irbrc", grammar = "ruby"},
	{key = ".justfile", grammar = "just"},
	{key = ".kshrc", grammar = "bash"},
	{key = ".latexmkrc", grammar = "perl"},
	{key = ".login", grammar = "bash"},
	{key = ".luacheckrc", grammar = "lua"},
	{key = ".nycrc", grammar = "json"},
	{key = ".php", grammar = "php"},
	{key = ".php_cs", grammar = "php"},
	{key = ".php_cs.dist", grammar = "php"},
	{key = ".profile", grammar = "bash"},
	{key = ".project", grammar = "xml"},
	{key = ".pryrc", grammar = "ruby"},
	{key = ".pylintrc", grammar = "ini"},
	{key = ".simplecov", grammar = "ruby"},
	{key = ".spacemacs", grammar = "elisp"},
	{key = ".tern-config", grammar = "json"},
	{key = ".tern-project", grammar = "json"},
	{key = ".tmux.conf", grammar = "bash"},
	{key = ".viper", grammar = "elisp"},
	{key = ".watchmanconfig", grammar = "json"},
	{key = ".xinitrc", grammar = "bash"},
	{key = ".xsession", grammar = "bash"},
	{key = ".zlogin", grammar = "bash"},
	{key = ".zlogout", grammar = "bash"},
	{key = ".zprofile", grammar = "bash"},
	{key = ".zshenv", grammar = "bash"},
	{key = ".zshrc", grammar = "bash"},
	{key = "9fs", grammar = "bash"},
	{key = "App.config", grammar = "xml"},
	{key = "Appraisals", grammar = "ruby"},
	{key = "BSDmakefile", grammar = "make"},
	{key = "BUCK", grammar = "starlark"},
	{key = "BUILD", grammar = "starlark"},
	{key = "BUILD.bazel", grammar = "starlark"},
	{key = "Berksfile", grammar = "ruby"},
	{key = "Brewfile", grammar = "ruby"},
	{key = "Buildfile", grammar = "ruby"},
	{key = "CITATION.cff", grammar = "yaml"},
	{key = "CMakeLists.txt", grammar = "cmake"},
	{key = "Capfile", grammar = "ruby"},
	{key = "Cargo.lock", grammar = "toml"},
	{key = "Cargo.toml.orig", grammar = "toml"},
	{key = "Cask", grammar = "elisp"},
	{key = "Containerfile", grammar = "dockerfile"},
	{key = "DEPS", grammar = "python"},
	{key = "Dangerfile", grammar = "ruby"},
	{key = "Deliverfile", grammar = "ruby"},
	{key = "Dockerfile", grammar = "dockerfile"},
	{key = "Earthfile", grammar = "earthfile"},
	{key = "Eask", grammar = "elisp"},
	{key = "Emakefile", grammar = "erlang"},
	{key = "Fastfile", grammar = "ruby"},
	{key = "GNUmakefile", grammar = "make"},
	{key = "Gemfile", grammar = "ruby"},
	{key = "Gopkg.lock", grammar = "toml"},
	{key = "Guardfile", grammar = "ruby"},
	{key = "HOSTS", grammar = "ini"},
	{key = "JUSTFILE", grammar = "just"},
	{key = "Jakefile", grammar = "javascript"},
	{key = "Jarfile", grammar = "ruby"},
	{key = "Jenkinsfile", grammar = "groovy"},
	{key = "Justfile", grammar = "just"},
	{key = "Kbuild", grammar = "make"},
	{key = "MODULE.bazel", grammar = "starlark"},
	{key = "MODULE.bazel.lock", grammar = "json"},
	{key = "Makefile", grammar = "make"},
	{key = "Makefile.PL", grammar = "perl"},
	{key = "Makefile.am", grammar = "make"},
	{key = "Makefile.boot", grammar = "make"},
	{key = "Makefile.frag", grammar = "make"},
	{key = "Makefile.in", grammar = "make"},
	{key = "Makefile.inc", grammar = "make"},
	{key = "Makefile.wat", grammar = "make"},
	{key = "Mavenfile", grammar = "ruby"},
	{key = "Modulefile", grammar = "puppet"},
	{key = "NuGet.config", grammar = "xml"},
	{key = "Nukefile", grammar = "nushell"},
	{key = "PKGBUILD", grammar = "bash"},
	{key = "Package.resolved", grammar = "json"},
	{key = "Phakefile", grammar = "php"},
	{key = "Pipfile", grammar = "toml"},
	{key = "Pipfile.lock", grammar = "json"},
	{key = "Podfile", grammar = "ruby"},
	{key = "Project.ede", grammar = "elisp"},
	{key = "Puppetfile", grammar = "ruby"},
	{key = "Rakefile", grammar = "ruby"},
	{key = "Rexfile", grammar = "perl"},
	{key = "SConscript", grammar = "python"},
	{key = "SConstruct", grammar = "python"},
	{key = "Settings.StyleCop", grammar = "xml"},
	{key = "Snapfile", grammar = "ruby"},
	{key = "Steepfile", grammar = "ruby"},
	{key = "Thorfile", grammar = "ruby"},
	{key = "Tiltfile", grammar = "starlark"},
	{key = "Vagrantfile", grammar = "ruby"},
	{key = "WORKSPACE", grammar = "starlark"},
	{key = "WORKSPACE.bazel", grammar = "starlark"},
	{key = "WORKSPACE.bzlmod", grammar = "starlark"},
	{key = "Web.Debug.config", grammar = "xml"},
	{key = "Web.Release.config", grammar = "xml"},
	{key = "Web.config", grammar = "xml"},
	{key = "_emacs", grammar = "elisp"},
	{key = "abbrev_defs", grammar = "elisp"},
	{key = "ack", grammar = "perl"},
	{key = "bash_aliases", grammar = "bash"},
	{key = "bash_logout", grammar = "bash"},
	{key = "bash_profile", grammar = "bash"},
	{key = "bashrc", grammar = "bash"},
	{key = "buildfile", grammar = "ruby"},
	{key = "buildozer.spec", grammar = "ini"},
	{key = "bun.lock", grammar = "json"},
	{key = "composer.lock", grammar = "json"},
	{key = "contents.lr", grammar = "markdown"},
	{key = "cpanfile", grammar = "perl"},
	{key = "cshrc", grammar = "bash"},
	{key = "deno.lock", grammar = "json"},
	{key = "dev-requirements.txt", grammar = "requirements"},
	{key = "expr-dist", grammar = "r"},
	{key = "flake.lock", grammar = "json"},
	{key = "glide.lock", grammar = "yaml"},
	{key = "go.mod", grammar = "gomod"},
	{key = "gradlew", grammar = "bash"},
	{key = "hosts", grammar = "ini"},
	{key = "justfile", grammar = "just"},
	{key = "kshrc", grammar = "bash"},
	{key = "latexmkrc", grammar = "perl"},
	{key = "ld.script", grammar = "linkerscript"},
	{key = "login", grammar = "bash"},
	{key = "makefile", grammar = "make"},
	{key = "makefile.sco", grammar = "make"},
	{key = "man", grammar = "bash"},
	{key = "mcmod.info", grammar = "json"},
	{key = "meson.build", grammar = "meson"},
	{key = "meson_options.txt", grammar = "meson"},
	{key = "mix.lock", grammar = "elixir"},
	{key = "mkfile", grammar = "make"},
	{key = "mvnw", grammar = "bash"},
	{key = "nginx.conf", grammar = "nginx"},
	{key = "nim.cfg", grammar = "nim"},
	{key = "owh", grammar = "tcl"},
	{key = "packages.config", grammar = "xml"},
	{key = "pdm.lock", grammar = "toml"},
	{key = "pixi.lock", grammar = "yaml"},
	{key = "poetry.lock", grammar = "toml"},
	{key = "profile", grammar = "bash"},
	{key = "project.godot", grammar = "godot_resource"},
	{key = "pylintrc", grammar = "ini"},
	{key = "rebar.config", grammar = "erlang"},
	{key = "rebar.config.lock", grammar = "erlang"},
	{key = "rebar.lock", grammar = "erlang"},
	{key = "requirements-dev.txt", grammar = "requirements"},
	{key = "requirements.lock.txt", grammar = "requirements"},
	{key = "requirements.txt", grammar = "requirements"},
	{key = "starfield", grammar = "tcl"},
	{key = "suite.rc", grammar = "cylc"},
	{key = "tmux.conf", grammar = "bash"},
	{key = "uv.lock", grammar = "toml"},
	{key = "vlcrc", grammar = "ini"},
	{key = "wscript", grammar = "python"},
	{key = "xinitrc", grammar = "bash"},
	{key = "xsession", grammar = "bash"},
	{key = "yarn.lock", grammar = "yaml"},
	{key = "zlogin", grammar = "bash"},
	{key = "zlogout", grammar = "bash"},
	{key = "zprofile", grammar = "bash"},
	{key = "zshenv", grammar = "bash"},
	{key = "zshrc", grammar = "bash"},
}
LINGUIST_INTERPRETERS :: []Linguist_Claim{
	{key = "ash", grammar = "bash"},
	{key = "awk", grammar = "awk"},
	{key = "bash", grammar = "bash"},
	{key = "bigloo", grammar = "scheme"},
	{key = "bun", grammar = "typescript"},
	{key = "ccl", grammar = "commonlisp"},
	{key = "chakra", grammar = "javascript"},
	{key = "chicken", grammar = "scheme"},
	{key = "clisp", grammar = "commonlisp"},
	{key = "cperl", grammar = "perl"},
	{key = "crystal", grammar = "crystal"},
	{key = "csi", grammar = "scheme"},
	{key = "d8", grammar = "javascript"},
	{key = "dart", grammar = "dart"},
	{key = "dash", grammar = "bash"},
	{key = "deno", grammar = "typescript"},
	{key = "ecl", grammar = "commonlisp"},
	{key = "elixir", grammar = "elixir"},
	{key = "escript", grammar = "erlang"},
	{key = "fennel", grammar = "fennel"},
	{key = "fish", grammar = "fish"},
	{key = "gawk", grammar = "awk"},
	{key = "gjs", grammar = "javascript"},
	{key = "gn", grammar = "gn"},
	{key = "gosh", grammar = "scheme"},
	{key = "groovy", grammar = "groovy"},
	{key = "guile", grammar = "scheme"},
	{key = "instantfpc", grammar = "pascal"},
	{key = "jruby", grammar = "ruby"},
	{key = "js", grammar = "javascript"},
	{key = "julia", grammar = "julia"},
	{key = "ksh", grammar = "bash"},
	{key = "lisp", grammar = "commonlisp"},
	{key = "lua", grammar = "lua"},
	{key = "luajit", grammar = "lua"},
	{key = "luau", grammar = "luau"},
	{key = "macruby", grammar = "ruby"},
	{key = "make", grammar = "make"},
	{key = "math", grammar = "wolfram"},
	{key = "mathematica", grammar = "wolfram"},
	{key = "mathematicascript", grammar = "wolfram"},
	{key = "mathkernel", grammar = "wolfram"},
	{key = "mawk", grammar = "awk"},
	{key = "mksh", grammar = "bash"},
	{key = "nawk", grammar = "awk"},
	{key = "node", grammar = "javascript"},
	{key = "nodejs", grammar = "javascript"},
	{key = "nush", grammar = "nushell"},
	{key = "ocaml", grammar = "ocaml"},
	{key = "ocamlrun", grammar = "ocaml"},
	{key = "ocamlscript", grammar = "ocaml"},
	{key = "pdksh", grammar = "bash"},
	{key = "perl", grammar = "perl"},
	{key = "php", grammar = "php"},
	{key = "pkl", grammar = "pkl"},
	{key = "pwsh", grammar = "powershell"},
	{key = "py", grammar = "python"},
	{key = "pypy", grammar = "python"},
	{key = "pypy3", grammar = "python"},
	{key = "python", grammar = "python"},
	{key = "python2", grammar = "python"},
	{key = "python3", grammar = "python"},
	{key = "qjs", grammar = "javascript"},
	{key = "r6rs", grammar = "scheme"},
	{key = "racket", grammar = "racket"},
	{key = "rake", grammar = "ruby"},
	{key = "rbx", grammar = "ruby"},
	{key = "rc", grammar = "bash"},
	{key = "rhino", grammar = "javascript"},
	{key = "rscript", grammar = "r"},
	{key = "ruby", grammar = "ruby"},
	{key = "runghc", grammar = "haskell"},
	{key = "runhaskell", grammar = "haskell"},
	{key = "runhugs", grammar = "haskell"},
	{key = "rust-script", grammar = "rust"},
	{key = "sbcl", grammar = "commonlisp"},
	{key = "scala", grammar = "scala"},
	{key = "scheme", grammar = "scheme"},
	{key = "sh", grammar = "bash"},
	{key = "swipl", grammar = "prolog"},
	{key = "tcc", grammar = "c"},
	{key = "tclsh", grammar = "tcl"},
	{key = "tl", grammar = "teal"},
	{key = "ts-node", grammar = "typescript"},
	{key = "tsx", grammar = "typescript"},
	{key = "uv", grammar = "python"},
	{key = "v8", grammar = "javascript"},
	{key = "v8-shell", grammar = "javascript"},
	{key = "wish", grammar = "tcl"},
	{key = "wolfram", grammar = "wolfram"},
	{key = "wolframkernel", grammar = "wolfram"},
	{key = "wolframnb", grammar = "wolfram"},
	{key = "wolframscript", grammar = "wolfram"},
	{key = "yap", grammar = "prolog"},
	{key = "zsh", grammar = "bash"},
}
