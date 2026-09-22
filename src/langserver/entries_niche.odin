// Niche-language entries (the "niche_languages" group): zig,
// nix, lean4, haxe, pascal, rego, al, solidity, systemverilog, hlsl.
package langserver

import "core:mem"

import "src:platform"

register_niche_entries :: proc(reg: ^Registry) {
	registry_add(reg, {
		id                = "zig",
		display_name      = "Zig",
		file_patterns     = {"*.zig", "*.zon"},
		priority          = PRIORITY_NORMAL,
		command           = "zls",
		required_binaries = {{"zls", "zls"}},
	})

	registry_add(reg, {
		id                = "nix",
		display_name      = "Nix",
		file_patterns     = {"*.nix"},
		priority          = PRIORITY_NORMAL,
		command           = "nixd",
		required_binaries = {{"nixd", "nixd"}},
	})

	registry_add(reg, {
		id                = "lean4",
		display_name      = "Lean 4",
		file_patterns     = {"*.lean"},
		priority          = PRIORITY_NORMAL,
		command           = "lean",
		args              = {"--server"},
		required_binaries = {{"lean", "Lean 4"}},
	})

	registry_add(reg, {
		id                = "haxe",
		display_name      = "Haxe",
		file_patterns     = {"*.hx"},
		priority          = PRIORITY_NORMAL,
		command           = "haxe-language-server",
		args              = {"--stdio"},
		check_runtime     = check_haxe_runtime,
	})

	registry_add(reg, {
		id                = "pascal",
		display_name      = "Pascal",
		file_patterns     = {"*.pas", "*.pp", "*.lpr", "*.dpr", "*.dpk", "*.inc"},
		priority          = PRIORITY_NORMAL,
		command           = "pasls",
		required_binaries = {{"pasls", "pasls"}},
	})

	registry_add(reg, {
		id                = "rego",
		display_name      = "Rego",
		file_patterns     = {"*.rego"},
		priority          = PRIORITY_NORMAL,
		command           = "regal",
		args              = {"language-server"},
		required_binaries = {{"regal", "regal"}},
	})

	registry_add(reg, {
		id                = "al",
		display_name      = "AL",
		file_patterns     = {"*.al", "*.dal"},
		priority          = PRIORITY_NORMAL,
		command           = "al",
		required_binaries = {{"al", "AL language server"}},
	})

	registry_add(reg, {
		id                = "solidity",
		display_name      = "Solidity",
		file_patterns     = {"*.sol"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "nomicfoundation-solidity-language-server",
		args              = {"--stdio"},
		required_binaries = {{"nomicfoundation-solidity-language-server", "solidity-language-server"}},
	})

	registry_add(reg, {
		id           = "systemverilog",
		display_name = "SystemVerilog",
		file_patterns = {"*.sv", "*.svh", "*.v", "*.vh"},
		priority     = PRIORITY_NORMAL,
		command      = "verible-verilog-ls",
		required_binaries = {{"verible-verilog-ls", "verible-verilog-ls"}},
	})

	registry_add(reg, {
		id           = "hlsl",
		display_name = "HLSL",
		file_patterns = {
			"*.hlsl", "*.hlsli", "*.fx", "*.fxh", "*.cginc", "*.compute", "*.shader",
			"*.glsl", "*.vert", "*.frag", "*.geom", "*.tesc", "*.tese", "*.comp", "*.wgsl",
		},
		priority          = PRIORITY_NORMAL,
		command           = "shader-language-server",
		args              = {"--stdio"},
		required_binaries = {{"shader-language-server", "shader-language-server"}},
	})
}

check_haxe_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	if !binary_available("haxe-language-server") {
		return not_installed_err("haxe-language-server", "npm install -g haxe-language-server (requires Node.js)", arena)
	}
	return nil
}
