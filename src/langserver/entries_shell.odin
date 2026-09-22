// Shell/config-language entries (the "shell_languages"
// group): bash, terraform, vue, elm, fortran, lua, luau.
// No powershell entry: its language server (PowerShellEditorServices)
// launches through a Start-EditorServices.ps1 invocation that names
// module install paths, which a static registry argv cannot spell — a
// bare `pwsh` is an interactive shell, never a server, so every .ps1
// project burned a spawn plus a handshake timeout. Re-adding it belongs
// to the change that grows the registry a path-resolving argv.
package langserver

register_shell_entries :: proc(reg: ^Registry) {
	registry_add(reg, {
		id                = "bash",
		display_name      = "Bash",
		file_patterns     = {"*.sh", "*.bash"},
		priority          = PRIORITY_NORMAL,
		command           = "bash-language-server",
		args              = {"start"},
		required_binaries = {{"bash-language-server", "bash-language-server"}},
		install_hint      = "npm install -g bash-language-server",
	})

	registry_add(reg, {
		id                = "terraform",
		display_name      = "Terraform",
		file_patterns     = {"*.tf", "*.tfvars", "*.tfstate"},
		priority          = PRIORITY_NORMAL,
		command           = "terraform-ls",
		args              = {"serve"},
		required_binaries = {{"terraform-ls", "terraform-ls"}},
		install_hint      = "Install from https://github.com/hashicorp/terraform-ls/releases",
	})

	registry_add(reg, {
		id          = "vue",
		display_name = "Vue",
		file_patterns = {"*.vue"},
		priority    = PRIORITY_SUPERSET,
		command     = "vue-language-server",
		args        = {"--stdio"},
		required_binaries = {{"vue-language-server", "vue-language-server"}},
	})

	registry_add(reg, {
		id                = "elm",
		display_name      = "Elm",
		file_patterns     = {"*.elm"},
		priority          = PRIORITY_NORMAL,
		command           = "elm-language-server",
		args              = {"--stdio"},
		required_binaries = {{"elm-language-server", "elm-language-server"}},
	})

	registry_add(reg, {
		id           = "fortran",
		display_name = "Fortran",
		file_patterns = {
			"*.f90", "*.F90", "*.f95", "*.F95", "*.f03", "*.F03", "*.f08", "*.F08",
			"*.f", "*.F", "*.for", "*.FOR", "*.fpp", "*.FPP",
		},
		priority          = PRIORITY_NORMAL,
		command           = "fortls",
		required_binaries = {{"fortls", "fortls"}},
	})

	registry_add(reg, {
		id                = "lua",
		display_name      = "Lua",
		file_patterns     = {"*.lua"},
		priority          = PRIORITY_NORMAL,
		command           = "lua-language-server",
		required_binaries = {{"lua-language-server", "lua-language-server"}},
		install_hint      = "Install from https://github.com/LuaLS/lua-language-server/releases or via your package manager",
	})

	registry_add(reg, {
		id                = "luau",
		display_name      = "Luau",
		file_patterns     = {"*.luau"},
		priority          = PRIORITY_NORMAL,
		command           = "luau-lsp",
		args              = {"lsp"},
		required_binaries = {{"luau-lsp", "luau-lsp"}},
	})
}
