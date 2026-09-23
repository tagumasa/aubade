// Data/config-language entries (the "data_languages" group):
// markdown, yaml, toml, ansible, msl, json. JSON locates an
// already-installed server component; the verified-download
// installer for missing components is a separate later addition.
package langserver

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"

import "src:platform"

YAML_INIT_OPTIONS :: `{"yaml":{"schemaStore":{"enable":true},"format":{"enable":true},"validate":true}}`

// ls_resources_dir is the shared install location for server components
// aubade manages itself (<aubade home>/ls-resources).
ls_resources_dir :: proc(a := context.temp_allocator) -> string {
	home := platform.aubade_home(a)
	d, _ := filepath.join({home, "ls-resources"}, a)
	return d
}

file_exists :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return false
	}
	os.file_info_delete(info, context.temp_allocator)
	return true
}

register_data_entries :: proc(reg: ^Registry) {
	registry_add(reg, {
		id                = "markdown",
		display_name      = "Markdown",
		file_patterns     = {"*.md", "*.markdown"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "marksman",
		args              = {"server"},
		required_binaries = {{"marksman", "marksman"}},
	})

	registry_add(reg, {
		id                = "yaml",
		display_name      = "YAML",
		file_patterns     = {"*.yaml", "*.yml"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "yaml-language-server",
		args              = {"--stdio"},
		init_options_json = YAML_INIT_OPTIONS,
		required_binaries = {{"yaml-language-server", "yaml-language-server"}},
	})

	registry_add(reg, {
		id                = "toml",
		display_name      = "TOML",
		file_patterns     = {"*.toml"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "taplo",
		args              = {"lsp", "stdio"},
		required_binaries = {{"taplo", "taplo"}},
	})

	registry_add(reg, {
		id           = "ansible",
		display_name = "Ansible",
		file_patterns = {"*.yaml", "*.yml"},
		priority     = PRIORITY_EXPERIMENTAL,
		experimental = true,
		command      = "ansible-language-server",
		args         = {"--stdio"},
		required_binaries = {{"ansible-language-server", "ansible-language-server"}},
	})

	registry_add(reg, {
		id              = "msl",
		display_name    = "mIRC Scripting",
		file_patterns   = {"*.mrc"},
		priority        = PRIORITY_NORMAL,
		command         = "python",
		args            = {"-m", "msl.langserver", "--stdio"},
		check_runtime   = check_msl_runtime,
		resolve_command = resolve_msl_command,
	})

	registry_add(reg, {
		id              = "json",
		display_name    = "JSON",
		file_patterns   = {"*.json", "*.jsonc"},
		priority        = PRIORITY_EXPERIMENTAL,
		experimental    = true,
		command         = "vscode-json-languageserver",
		args            = {"--stdio"},
		check_runtime   = check_json_runtime,
		resolve_command = resolve_json_command,
	})
}

// ---------------------------------------------------------------- msl

// probe_msl_server resolves a python interpreter with the msl module
// importable; only a successful probe is cached (a cached failure would
// pin "not installed" for the daemon's lifetime and defeat the
// install-then-retry start flow). The returned argv is registry-owned
// and must be cloned by callers that keep it.
probe_msl_server :: proc(reg: ^Registry) -> (argv: []string, ok: bool) {
	sync.mutex_lock(&reg.mu)
	if reg.is_msl_probed {
		argv = reg.msl_argv
		ok = reg.is_msl_ok
		sync.mutex_unlock(&reg.mu)
		return argv, ok
	}
	sync.mutex_unlock(&reg.mu)

	resolved: []string = nil
	found := false
	// Scratch during the probe (reg.allocator is not thread-safe outside
	// reg.mu, and this section deliberately runs unlocked); the winning
	// result is cloned into the arena under the lock below.
	for py in python_interpreter_candidates() {
		if !binary_available(py) {
			continue
		}
		if python_module_importable(py, "msl.langserver") {
			resolved = make_argv({py, "-m", "msl.langserver", "--stdio"}, context.temp_allocator)
			found = true
			break
		}
	}

	sync.mutex_lock(&reg.mu)
	if reg.is_msl_probed {
		// A concurrent probe won the race; ours was scratch and simply
		// disappears with the temp allocator.
	} else if found {
		reg.is_msl_probed = true
		reg.is_msl_ok = true
		reg.msl_argv = clone_strings(resolved, reg.allocator)
	}
	// A failed probe is not a cache state — the next attempt re-probes.
	argv = reg.msl_argv
	ok = reg.is_msl_ok
	sync.mutex_unlock(&reg.mu)
	return argv, ok
}

check_msl_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	if _, ok := probe_msl_server(reg); ok {
		return nil
	}
	return not_installed_err("msl-language-server", "pip install msl-language-server", arena)
}

resolve_msl_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	argv, ok := probe_msl_server(reg)
	if !ok {
		return nil, nil
	}
	return clone_strings(argv, a), nil
}

// ---------------------------------------------------------------- json

check_json_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	if !node_available() {
		return not_installed_err("Node.js", "", arena)
	}
	return nil
}

// resolve_json_command launches the managed ls-resources copy when
// present; the npm install that creates it belongs to the dependency
// installer. Otherwise the static command falls back to PATH.
resolve_json_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	dir, _ := filepath.join({ls_resources_dir(), "json-lsp"}, context.temp_allocator)
	bin_dir, _ := filepath.join({dir, "node_modules", ".bin"}, context.temp_allocator)
	bin_name := "vscode-json-languageserver"
	when ODIN_OS == .Windows {
		bin_name = "vscode-json-languageserver.cmd"
	}
	bin, _ := filepath.join({bin_dir, bin_name}, context.temp_allocator)
	if !file_exists(bin) {
		return nil, nil
	}
	return make_argv({bin, "--stdio"}, a), nil
}
