// Scripting-language entries (the "scripting_languages"
// group): ruby (+ solargraph alternate), php (+ phpactor alternate),
// perl, r.
package langserver

register_scripting_entries :: proc(reg: ^Registry) {
	registry_add(reg, {
		id                = "ruby",
		display_name      = "Ruby",
		file_patterns     = {"*.rb", "*.rake", "*.ru", "*.erb"},
		priority          = PRIORITY_NORMAL,
		command           = "ruby-lsp",
		required_binaries = {{"ruby-lsp", "ruby-lsp"}},
		install_hint      = "gem install ruby-lsp",
	})

	registry_add(reg, {
		id                = "ruby_solargraph",
		display_name      = "Ruby (Solargraph)",
		file_patterns     = {"*.rb"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "solargraph",
		args              = {"stdio"},
		required_binaries = {{"solargraph", "solargraph"}},
	})

	registry_add(reg, {
		id                = "php",
		display_name      = "PHP",
		file_patterns     = {"*.php"},
		priority          = PRIORITY_NORMAL,
		command           = "intelephense",
		args              = {"--stdio"},
		required_binaries = {{"node", "Node.js"}, {"intelephense", "intelephense"}},
		install_hint      = "npm install -g intelephense",
	})

	registry_add(reg, {
		id                = "php_phpactor",
		display_name      = "PHP (Phpactor)",
		file_patterns     = {"*.php"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		// phpactor speaks LSP over stdio through its language-server
		// subcommand — a bare `php` never becomes a server.
		command           = "phpactor",
		args              = {"language-server"},
		required_binaries = {{"phpactor", "phpactor"}},
	})

	registry_add(reg, {
		id                = "perl",
		display_name      = "Perl",
		file_patterns     = {"*.pl", "*.pm", "*.t"},
		priority          = PRIORITY_NORMAL,
		command           = "perl",
		args              = {"-MPerl::LanguageServer", "-e", "Perl::LanguageServer::run()"},
		required_binaries = {{"perl", "Perl"}},
	})

	registry_add(reg, {
		id                = "r",
		display_name      = "R",
		file_patterns     = {"*.R", "*.r", "*.Rmd", "*.Rnw"},
		priority          = PRIORITY_NORMAL,
		command           = "R",
		args              = {"--vanilla", "--quiet", "--slave", "-e", "options(languageserver.debug_mode = FALSE); languageserver::run()"},
		required_binaries = {{"R", "R"}},
	})
}
