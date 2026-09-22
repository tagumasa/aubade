// Data/config-language entries (the "data_languages" group):
// markdown, yaml, toml, ansible, matlab, msl, json. MATLAB and JSON
// locate an already-installed server component; the verified-download
// installer for missing components is a separate later addition.
package langserver

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "src:jsonutil"
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

// find_first_existing returns the first path that exists on disk.
find_first_existing :: proc(candidates: []string) -> string {
	for c in candidates {
		if file_exists(c) {
			return c
		}
	}
	return ""
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
		id            = "matlab",
		display_name  = "MATLAB",
		file_patterns = {"*.m", "*.mlx", "*.mlapp"},
		priority      = PRIORITY_NORMAL,
		command       = "",
		env           = matlab_registration_env(),
		check_runtime = check_matlab_runtime,
		resolve_command = resolve_matlab_command,
		config_item   = matlab_config_item,
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

// ---------------------------------------------------------------- matlab

// matlab_glob_dir describes one install-location pattern as a directory
// plus name prefix/suffix (a glob-free stand-in).
Matlab_Glob :: struct {
	dir:    string,
	prefix: string,
	suffix: string,
}

matlab_glob_dirs :: proc() -> []Matlab_Glob {
	globs := make([dynamic]Matlab_Glob, 0, 8, context.temp_allocator)
	when ODIN_OS == .Windows {
		// Windows has no home-relative MATLAB convention; only the
		// Program Files locations apply.
		append(&globs, Matlab_Glob{"C:\\Program Files\\MATLAB", "R", ""})
		append(&globs, Matlab_Glob{"C:\\Program Files (x86)\\MATLAB", "R", ""})
	} else {
		home := home_dir(context.temp_allocator)
		when ODIN_OS == .Darwin {
			append(&globs, Matlab_Glob{"/Applications", "MATLAB_", ".app"})
			if home != "" {
				ha, _ := filepath.join({home, "Applications"}, context.temp_allocator)
				append(&globs, Matlab_Glob{ha, "MATLAB_", ".app"})
			}
		}
		append(&globs, Matlab_Glob{"/usr/local/MATLAB", "R", ""})
		append(&globs, Matlab_Glob{"/opt/MATLAB", "R", ""})
		if home != "" {
			hm, _ := filepath.join({home, "MATLAB"}, context.temp_allocator)
			append(&globs, Matlab_Glob{hm, "R", ""})
		}
	}
	return globs[:]
}

// newest_matching_dir lists one glob directory and returns the
// lexicographically greatest matching name (MATLAB versions sort that
// way); "" when no match.
newest_matching_dir :: proc(g: Matlab_Glob) -> string {
	entries, err := os.read_all_directory_by_path(g.dir, context.temp_allocator)
	if err != nil {
		return ""
	}
	best := ""
	for e in entries {
		name := e.name
		if !strings.has_prefix(name, g.prefix) || !strings.has_suffix(name, g.suffix) {
			continue
		}
		if best == "" || name > best {
			best = name
		}
	}
	os.file_info_slice_delete(entries, context.temp_allocator)
	if best == "" {
		return ""
	}
	match, _ := filepath.join({g.dir, best}, context.temp_allocator)
	return match
}

// matlab_install_path resolves the MATLAB installation (env override,
// then the standard locations); "" when not found.
matlab_install_path :: proc() -> string {
	if p := clean_env_path(os.get_env("MATLAB_PATH", context.temp_allocator)); p != "" {
		return p
	}
	for g in matlab_glob_dirs() {
		if m := newest_matching_dir(g); m != "" {
			return m
		}
	}
	return ""
}

check_matlab_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	if !node_available() {
		return not_installed_err("Node.js", "", arena)
	}
	if matlab_install_path() == "" {
		return platform.Wrapped{
			kind = .NotFound,
			msg  = "MATLAB installation not found; set MATLAB_PATH or install MATLAB",
		}
	}
	return nil
}

// matlab_server_script locates the extension's server entry point: the
// managed ls-resources copy, an explicit MATLAB_EXTENSION_PATH, or a
// VS Code extension checkout. The marketplace download for a missing
// extension belongs to the dependency installer and is not attempted
// here.
matlab_server_script :: proc() -> string {
	base, _ := filepath.join({ls_resources_dir(), "matlab-extension"}, context.temp_allocator)
	ext, _ := filepath.join({base, "extension"}, context.temp_allocator)
	cand1, _ := filepath.join({ext, "server", "out", "index.js"}, context.temp_allocator)
	cand2, _ := filepath.join({ext, "out", "index.js"}, context.temp_allocator)
	if script := find_first_existing({cand1, cand2}); script != "" {
		return script
	}
	if envp := clean_env_path(os.get_env("MATLAB_EXTENSION_PATH", context.temp_allocator)); envp != "" {
		c1, _ := filepath.join({envp, "server", "out", "index.js"}, context.temp_allocator)
		c2, _ := filepath.join({envp, "out", "index.js"}, context.temp_allocator)
		if script := find_first_existing({c1, c2}); script != "" {
			return script
		}
	}
	home := home_dir(context.temp_allocator)
	if home != "" {
		vscode, _ := filepath.join({home, ".vscode", "extensions"}, context.temp_allocator)
		entries, err := os.read_all_directory_by_path(vscode, context.temp_allocator)
		if err == nil {
			script := ""
			for e in entries {
				name := e.name
				if !strings.has_prefix(name, "mathworks.language-matlab") {
					continue
				}
				ext_dir, _ := filepath.join({vscode, name}, context.temp_allocator)
				s1, _ := filepath.join({ext_dir, "server", "out", "index.js"}, context.temp_allocator)
				s2, _ := filepath.join({ext_dir, "out", "index.js"}, context.temp_allocator)
				if found := find_first_existing({s1, s2}); found != "" {
					script = found
				}
			}
			os.file_info_slice_delete(entries, context.temp_allocator)
			if script != "" {
				return script
			}
		}
	}
	return ""
}

resolve_matlab_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	script := matlab_server_script()
	if script == "" {
		return nil, platform.Wrapped{
			kind = .NotFound,
			msg  = "MATLAB language server script not found (install the extension or set MATLAB_EXTENSION_PATH)",
		}
	}
	return make_argv({"node", script, "--stdio"}, a), nil
}

// matlab_config_item answers workspace/configuration: the MATLAB section
// carries the resolved install path and the onStart connection timing.
matlab_config_item :: proc(section: string, arena: mem.Allocator) -> json.Value {
	obj := jsonutil.json_object(2, arena)
	if section == "MATLAB" {
		// matlab_install_path allocates on the temp allocator; the
		// configuration response is arena-owned, so the value is cloned
		// into it instead of escaping its lifetime.
		jsonutil.obj_set(&obj, "installPath", jsonutil.json_string(strings.clone(matlab_install_path(), arena)))
		jsonutil.obj_set(&obj, "matlabConnectionTiming", jsonutil.json_string("onStart"))
	}
	return json.Value(json.Object(obj))
}

// matlab_registration_env snapshots the install path at registration
// time (the entry's env is static data; the configuration handler
// re-resolves per request).
matlab_registration_env :: proc() -> []Env_Var {
	path := matlab_install_path()
	if path == "" {
		return nil
	}
	out := make([]Env_Var, 1, context.temp_allocator)
	out[0] = {key = "MATLAB_INSTALL_PATH", value = path}
	return out
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
	bin, _ := filepath.join({bin_dir, "vscode-json-languageserver"}, context.temp_allocator)
	when ODIN_OS == .Windows {
		bin = strings.concatenate({bin, ".cmd"}, context.temp_allocator)
	}
	if !file_exists(bin) {
		return nil, nil
	}
	return make_argv({bin, "--stdio"}, a), nil
}
