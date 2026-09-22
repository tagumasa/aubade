// JVM-ecosystem and compiled-language entries (the "jvm_languages"
// group): scala, clojure, elixir, erlang, haskell,
// ocaml, fsharp, julia, swift, crystal.
// No groovy entry: its only language server launches as
// `java -jar <groovy-language-server.jar>`, and a static registry argv
// cannot name the jar's install path. Re-adding it belongs to the change
// that grows the registry a path-resolving argv (a command resolver or
// an env-named jar path) — a bare `java` argv just printed usage and
// exited on every start attempt.
package langserver

register_jvm_entries :: proc(reg: ^Registry) {
	registry_add(reg, {
		id                = "scala",
		display_name      = "Scala",
		file_patterns     = {"*.scala", "*.sbt"},
		priority          = PRIORITY_NORMAL,
		command           = "metals",
		required_binaries = {{"metals", "Metals"}},
	})

	registry_add(reg, {
		id                = "clojure",
		display_name      = "Clojure",
		file_patterns     = {"*.clj", "*.cljs", "*.cljc", "*.edn"},
		priority          = PRIORITY_NORMAL,
		command           = "clojure-lsp",
		required_binaries = {{"clojure-lsp", "clojure-lsp"}},
	})

	registry_add(reg, {
		id                = "elixir",
		display_name      = "Elixir",
		file_patterns     = {"*.ex", "*.exs"},
		priority          = PRIORITY_NORMAL,
		command           = "elixir-ls",
		required_binaries = {{"elixir-ls", "elixir-ls"}},
	})

	registry_add(reg, {
		id                = "erlang",
		display_name      = "Erlang",
		file_patterns = {
			"*.erl", "*.hrl", "*.escript", "*.config", "*.app", "*.app.src",
		},
		priority          = PRIORITY_NORMAL,
		command           = "erlang_ls",
		args              = {"--transport", "stdio"},
		required_binaries = {{"erlang_ls", "erlang_ls"}},
	})

	registry_add(reg, {
		id                = "haskell",
		display_name      = "Haskell",
		file_patterns     = {"*.hs", "*.lhs"},
		priority          = PRIORITY_NORMAL,
		command           = "haskell-language-server-wrapper",
		args              = {"--lsp"},
		required_binaries = {{"haskell-language-server-wrapper", "haskell-language-server-wrapper"}},
	})

	registry_add(reg, {
		id                = "ocaml",
		display_name      = "OCaml",
		file_patterns     = {"*.ml", "*.mli", "*.re", "*.rei"},
		priority          = PRIORITY_NORMAL,
		command           = "ocamllsp",
		args              = {"--fallback-read-dot-merlin"},
		required_binaries = {{"ocamllsp", "ocamllsp"}},
	})

	registry_add(reg, {
		id                = "fsharp",
		display_name      = "F#",
		file_patterns     = {"*.fs", "*.fsx", "*.fsi"},
		priority          = PRIORITY_NORMAL,
		command           = "fsautocomplete",
		args              = {"--adaptive-lsp-server-enabled", "--project-graph-enabled", "--use-fcs-transparent-compiler"},
		required_binaries = {{"fsautocomplete", "fsautocomplete"}},
	})

	registry_add(reg, {
		id                = "julia",
		display_name      = "Julia",
		file_patterns     = {"*.jl"},
		priority          = PRIORITY_NORMAL,
		command           = "julia",
		args              = {"--startup-file=no", "--history-file=no", "-e", "using LanguageServer; runserver()"},
		required_binaries = {{"julia", "Julia"}},
	})

	registry_add(reg, {
		id                = "swift",
		display_name      = "Swift",
		file_patterns     = {"*.swift"},
		priority          = PRIORITY_NORMAL,
		// sourcekit-lsp supports multiple workspace folders (the multiple
		// workspace feature shipped alongside Swift 5): every announced
		// folder gets its own workspace. Package.swift marks SwiftPM
		// package roots; Xcode-only repositories carry no marker and keep
		// the single project-root folder.
		root_markers      = {"Package.swift"},
		multi_root        = true,
		command           = "sourcekit-lsp",
		required_binaries = {{"sourcekit-lsp", "sourcekit-lsp"}},
	})

	registry_add(reg, {
		id                = "crystal",
		display_name      = "Crystal",
		file_patterns     = {"*.cr"},
		priority          = PRIORITY_NORMAL,
		command           = "crystalline",
		required_binaries = {{"crystalline", "crystalline"}},
	})
}
