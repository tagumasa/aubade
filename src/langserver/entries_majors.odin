// Major language entries: go, python (+ jedi/ty alternates), typescript
// (+ vtsls alternate), rust, dart, odin — with their runtime resolvers.
// Resolver helpers allocate on the temp allocator internally and clone
// only the escaping argv onto the caller's allocator, per the
// intra-procedure-scratch rule.
package langserver

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:unicode"

import "src:platform"
import "src:symbol"

// make_argv clones a locally built argv onto the destination allocator
// (the parts literal is same-proc; the clone is what escapes).
make_argv :: proc(parts: []string, a: mem.Allocator) -> []string {
	return clone_strings(parts, a)
}

// run_quiet_ok reports whether the argv runs to a zero exit within a
// short bound (version/subcommand probes).
run_quiet_ok :: proc(argv: []string) -> bool {
	opts := platform.Procrun_Opts{
		command          = argv,
		capture_stderr   = false,
		max_stream_bytes = 64 * 1024,
		timeout_ms       = 15_000,
	}
	res, err := platform.procrun(opts, context.temp_allocator)
	return err == nil && !res.timed_out && res.exit_code == 0
}

// ---------------------------------------------------------------- go

GO_INSTALL_HINT :: "go install golang.org/x/tools/gopls@latest"

// Go language servers allocate very aggressively while type-checking
// large workspaces; the containment ceiling protects the user's machine
// at the cost of a cgroup OOM kill that the restart machinery absorbs.
GO_MEMORY_LIMIT_MB :: 4096

// go_toolchain_fallback_dirs lists the standard Go toolchain install
// locations probed when the go binary is not on PATH.
go_toolchain_fallback_dirs :: proc() -> []string {
	when ODIN_OS == .Windows {
		src := [2]string{"C:\\Program Files\\Go\\bin", "C:\\Go\\bin"}
	} else {
		src := [1]string{"/usr/local/go/bin"}
	}
	out := make([]string, len(src), context.temp_allocator)
	for v, i in src {
		out[i] = v
	}
	return out
}

// go_candidate_dirs returns the directories, in priority order, that may
// hold the go toolchain or go-installed executables: GOROOT/bin, the
// standard install locations, GOBIN, and the first GOPATH bin entry
// (or ~/go/bin when GOPATH is unset) — covers launches with a minimal
// PATH (GUI apps, sandboxes that skip the shell profile).
go_candidate_dirs :: proc() -> []string {
	dirs := make([dynamic]string, 0, 8, context.temp_allocator)
	if goroot := clean_env_path(os.get_env("GOROOT", context.temp_allocator)); goroot != "" {
		bin, _ := filepath.join({goroot, "bin"}, context.temp_allocator)
		append(&dirs, bin)
	}
	for d in go_toolchain_fallback_dirs() {
		append(&dirs, d)
	}
	if gobin := clean_env_path(os.get_env("GOBIN", context.temp_allocator)); gobin != "" {
		append(&dirs, gobin)
	}
	gopath := clean_env_path(os.get_env("GOPATH", context.temp_allocator))
	if gopath != "" {
		parts := strings.split(gopath, PATH_LIST_SEP, context.temp_allocator)
		if len(parts) > 0 && parts[0] != "" {
			bin, _ := filepath.join({parts[0], "bin"}, context.temp_allocator)
			append(&dirs, bin)
		}
	} else if home := home_dir(context.temp_allocator); home != "" {
		bin, _ := filepath.join({home, "go", "bin"}, context.temp_allocator)
		append(&dirs, bin)
	}
	return dedupe_dirs(dirs[:], context.temp_allocator)
}

// resolve_go_toolchain locates the go and gopls binaries via PATH with
// fallback to the candidate directories.
resolve_go_toolchain :: proc() -> (go_bin, gopls_bin: string) {
	dirs := go_candidate_dirs()
	go_bin = look_path_with_fallbacks("go", dirs, context.temp_allocator)
	gopls_bin = look_path_with_fallbacks("gopls", dirs, context.temp_allocator)
	return
}

check_go_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	go_bin, gopls_bin := resolve_go_toolchain()
	if go_bin == "" {
		return not_installed_err("Go", GO_INSTALL_HINT, arena)
	}
	if gopls_bin == "" {
		return not_installed_err("gopls", GO_INSTALL_HINT, arena)
	}
	return nil
}

resolve_go_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	_, gopls_bin := resolve_go_toolchain()
	if gopls_bin == "" {
		return nil, nil
	}
	return make_argv({gopls_bin}, a), nil
}

// toolchain_dirs reports the directories holding the resolved toolchain
// binaries (empty entries skipped), cloned into `a` — the extra PATH a
// language server needs when it invokes its own toolchain commands.
toolchain_dirs :: proc(bin_a, bin_b: string, a: mem.Allocator) -> []string {
	dirs := make([dynamic]string, 0, 2, context.temp_allocator)
	if bin_a != "" {
		if d, ok := containing_dir(bin_a); ok {
			append(&dirs, d)
		}
	}
	if bin_b != "" {
		if d, ok := containing_dir(bin_b); ok {
			append(&dirs, d)
		}
	}
	out := make([dynamic]string, 0, len(dirs), a)
	for d in dirs {
		append(&out, strings.clone(d, a))
	}
	return out[:]
}

// go_extra_path_dirs reports the directories holding the resolved go and
// gopls binaries so they can be prepended to the language server's PATH:
// gopls invokes the go command internally for package loading.
go_extra_path_dirs :: proc(reg: ^Registry, a: mem.Allocator) -> []string {
	go_bin, gopls_bin := resolve_go_toolchain()
	return toolchain_dirs(go_bin, gopls_bin, a)
}

// containing_dir returns the directory part of an already-resolved
// absolute path (bounded use — never fed "" or ".").
containing_dir :: proc(path: string) -> (string, bool) {
	d := filepath.dir(path)
	if d == "" || d == "." {
		return "", false
	}
	return d, true
}

// normalize_go_symbol_name splits receiver-qualified method names reported
// by gopls into the bare method name and the receiver base type name.
// gopls reports methods as top-level document symbols named "(*Recv).Method"
// or "(Recv).Method" (pointer-qualified or generic, e.g. "(List[T]).Push")
// rather than nesting them under the type declaration; returning the
// receiver type lets the symbol pipeline nest the method under its type
// so name paths take the documented "Type/Method" form.
normalize_go_symbol_name :: proc(
	kind: symbol.Symbol_Kind,
	name: string,
	rel_path: string,
) -> (string, string) {
	if kind != .Method || !strings.contains(name, ".") {
		return name, ""
	}
	recv: string
	method: string
	if strings.has_prefix(name, "(") {
		close_idx := strings.index(name, ")")
		if close_idx < 0 || close_idx + 2 > len(name) || name[close_idx + 1] != '.' {
			return name, ""
		}
		recv = name[1:close_idx]
		method = name[close_idx + 2:]
	} else {
		dot_idx := strings.index(name, ".")
		if dot_idx <= 0 {
			return name, ""
		}
		recv = name[:dot_idx]
		method = name[dot_idx + 1:]
	}
	if strings.has_prefix(recv, "*") {
		recv = recv[1:]
	}
	if open_idx := strings.index(recv, "["); open_idx >= 0 {
		if !strings.has_suffix(recv, "]") {
			return name, ""
		}
		recv = recv[:open_idx]
	}
	if !is_go_identifier(recv) || !is_go_identifier(method) {
		return name, ""
	}
	return method, recv
}

// is_go_identifier reports whether s is a plausible Go identifier
// (letters, digits, and underscores, not starting with a digit). It
// deliberately accepts non-ASCII letters; its only purpose is to reject
// names that are clearly not receiver/method splits.
is_go_identifier :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for r, i in s {
		switch {
		case r == '_':
		case unicode.is_letter(r):
		case unicode.is_digit(r):
			if i == 0 {
				return false
			}
		case:
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------- python

PYTHON_INIT_OPTIONS :: `{"exclude":["**/__pycache__","**/.venv","**/.env","**/build","**/dist","**/.pixi"],"reportMissingImports":"error"}`

// python_interpreter_candidates honors AUBADE_PYTHON_PATH, then the
// platform's interpreter names.
python_interpreter_candidates :: proc() -> []string {
	if p := clean_env_path(os.get_env("AUBADE_PYTHON_PATH", context.temp_allocator)); p != "" {
		out := make([]string, 1, context.temp_allocator)
		out[0] = p
		return out
	}
	when ODIN_OS == .Windows {
		src := [2]string{"python", "python3"}
	} else {
		src := [2]string{"python3", "python"}
	}
	out := make([]string, len(src), context.temp_allocator)
	for v, i in src {
		out[i] = v
	}
	return out
}

// python_module_importable reports whether `python -c "import <module>"`
// succeeds for the interpreter (pyright/msl probe step).
python_module_importable :: proc(python: string, module: string) -> bool {
	cmd := [3]string{python, "-c", strings.concatenate({"import ", module}, context.temp_allocator)}
	return run_quiet_ok(cmd[:])
}

// probe_python_pyright resolves the pyright launch: the standalone
// pyright-langserver binary, or a python interpreter with the pyright
// module importable. Only a SUCCESSFUL probe is cached: the probe spawns
// subprocesses, but caching a failure would pin "not installed" for the
// daemon's lifetime and defeat the install-then-retry start flow. The
// returned argv is registry-owned and must be cloned by callers that
// keep it.
probe_python_pyright :: proc(reg: ^Registry) -> (argv: []string, ok: bool) {
	sync.mutex_lock(&reg.mu)
	if reg.is_pyright_probed {
		argv = reg.pyright_argv
		ok = reg.is_pyright_ok
		sync.mutex_unlock(&reg.mu)
		return argv, ok
	}
	sync.mutex_unlock(&reg.mu)

	resolved: []string = nil
	found := false
	// The probe result is scratch: it is built on the temp allocator (never
	// on reg.allocator — the arena is not thread-safe, and this section runs
	// outside reg.mu precisely so concurrent probes don't serialize behind
	// subprocess spawns) and cloned into the arena under the lock below.
	if binary_available("pyright-langserver") {
		resolved = make_argv({"pyright-langserver", "--stdio"}, context.temp_allocator)
		found = true
	} else {
		for py in python_interpreter_candidates() {
			if !binary_available(py) {
				continue
			}
			if python_module_importable(py, "pyright.langserver") {
				resolved = make_argv(
					{py, "-m", "pyright.langserver", "--stdio"},
					context.temp_allocator,
				)
				found = true
				break
			}
		}
	}

	sync.mutex_lock(&reg.mu)
	if reg.is_pyright_probed {
		// A concurrent probe won the race; ours was scratch and simply
		// disappears with the temp allocator.
	} else if found {
		reg.is_pyright_probed = true
		reg.is_pyright_ok = true
		reg.pyright_argv = clone_strings(resolved, reg.allocator)
	}
	// A failed probe is not a cache state — the next attempt re-probes.
	argv = reg.pyright_argv
	ok = reg.is_pyright_ok
	sync.mutex_unlock(&reg.mu)
	return argv, ok
}

resolve_python_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	argv, ok := probe_python_pyright(reg)
	if !ok {
		return nil, nil
	}
	return clone_strings(argv, a), nil
}

check_python_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	_, ok := probe_python_pyright(reg)
	if ok {
		return nil
	}
	return not_installed_err("pyright", "npm install -g pyright (or pip install pyright)", arena)
}

// ---------------------------------------------------------------- typescript

ts_js_file_patterns :: proc() -> []string {
	src := [8]string{"*.ts", "*.tsx", "*.js", "*.jsx", "*.cts", "*.mts", "*.cjs", "*.mjs"}
	out := make([]string, len(src), context.temp_allocator)
	for v, i in src {
		out[i] = v
	}
	return out
}

// ---------------------------------------------------------------- rust

resolve_rust_toolchain :: proc() -> (rust_analyzer_bin, rustup_bin: string) {
	cargo := make([dynamic]string, 0, 1, context.temp_allocator)
	if d := cargo_bin_dir(); d != "" {
		append(&cargo, d)
	}
	dirs := dedupe_dirs(cargo[:], context.temp_allocator)
	rust_analyzer_bin = look_path_with_fallbacks("rust-analyzer", dirs, context.temp_allocator)
	rustup_bin = look_path_with_fallbacks("rustup", dirs, context.temp_allocator)
	return
}

// cargo_bin_dir returns the directory holding cargo-installed binaries:
// $CARGO_HOME/bin, defaulting to ~/.cargo/bin. The rustup shims live
// there, but GUI apps and sandboxes often run without it on PATH.
cargo_bin_dir :: proc() -> string {
	if cargo_home := clean_env_path(os.get_env("CARGO_HOME", context.temp_allocator)); cargo_home != "" {
		bin, _ := filepath.join({cargo_home, "bin"}, context.temp_allocator)
		return bin
	}
	if home := home_dir(context.temp_allocator); home != "" {
		bin, _ := filepath.join({home, ".cargo", "bin"}, context.temp_allocator)
		return bin
	}
	return ""
}

check_rust_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	rust_analyzer_bin, rustup_bin := resolve_rust_toolchain()
	if rust_analyzer_bin != "" {
		return nil
	}
	if rustup_bin != "" {
		return not_installed_err("rust-analyzer", "rustup component add rust-analyzer", arena)
	}
	return not_installed_err("rust-analyzer", "install it via rustup or your package manager", arena)
}

resolve_rust_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	rust_analyzer_bin, rustup_bin := resolve_rust_toolchain()
	if rust_analyzer_bin != "" {
		probe := [2]string{rust_analyzer_bin, "--version"}
		if run_quiet_ok(probe[:]) {
			return make_argv({rust_analyzer_bin}, a), nil
		}
	}
	if rustup_bin != "" {
		probe := [5]string{rustup_bin, "run", "stable", "rust-analyzer", "--version"}
		if run_quiet_ok(probe[:]) {
			return make_argv({rustup_bin, "run", "stable", "rust-analyzer"}, a), nil
		}
	}
	return nil, nil
}

rust_extra_path_dirs :: proc(reg: ^Registry, a: mem.Allocator) -> []string {
	rust_analyzer_bin, rustup_bin := resolve_rust_toolchain()
	return toolchain_dirs(rust_analyzer_bin, rustup_bin, a)
}

// ---------------------------------------------------------------- dart

DART_INSTALL_HINT :: "install the Dart SDK (https://dart.dev/get-dart) or Flutter (https://docs.flutter.dev/get-started/install)"

// dart_candidate_dirs covers setups where the dart binary is not on
// PATH: an explicit FLUTTER_ROOT, the default Flutter and standalone SDK
// checkouts, and distro packages (dart ships with flutter).
dart_candidate_dirs :: proc() -> []string {
	dirs := make([dynamic]string, 0, 6, context.temp_allocator)
	if root := clean_env_path(os.get_env("FLUTTER_ROOT", context.temp_allocator)); root != "" {
		bin, _ := filepath.join({root, "bin"}, context.temp_allocator)
		append(&dirs, bin)
	}
	if home := home_dir(context.temp_allocator); home != "" {
		fb, _ := filepath.join({home, "flutter", "bin"}, context.temp_allocator)
		append(&dirs, fb)
		db, _ := filepath.join({home, "dart-sdk", "bin"}, context.temp_allocator)
		append(&dirs, db)
	}
	when ODIN_OS == .Windows {
		append(&dirs, "C:\\dart-sdk\\bin")
	} else {
		append(&dirs, "/usr/lib/dart/bin")
	}
	return dedupe_dirs(dirs[:], context.temp_allocator)
}

resolve_dart_binary :: proc() -> string {
	return look_path_with_fallbacks("dart", dart_candidate_dirs(), context.temp_allocator)
}

check_dart_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	if resolve_dart_binary() == "" {
		return not_installed_err("Dart SDK", DART_INSTALL_HINT, arena)
	}
	return nil
}

resolve_dart_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	dart := resolve_dart_binary()
	if dart == "" {
		return nil, nil
	}
	// Old SDKs without the language-server subcommand fall back to the
	// static command.
	probe := [3]string{dart, "language-server", "--help"}
	if !run_quiet_ok(probe[:]) {
		return nil, nil
	}
	return make_argv({dart, "language-server"}, a), nil
}

// ---------------------------------------------------------------- odin

ODIN_INSTALL_HINT :: "install Odin (https://odin-lang.org/docs/install/) and ols (https://github.com/DanielGavin/ols)"

// odin_candidate_dirs covers $ODIN_ROOT (the directory containing the
// compiler executable), the standard ~/Odin checkout, and system
// installs.
odin_candidate_dirs :: proc() -> []string {
	dirs := make([dynamic]string, 0, 5, context.temp_allocator)
	if root := clean_env_path(os.get_env("ODIN_ROOT", context.temp_allocator)); root != "" {
		append(&dirs, root)
	}
	if home := home_dir(context.temp_allocator); home != "" {
		ho, _ := filepath.join({home, "Odin"}, context.temp_allocator)
		append(&dirs, ho)
	}
	when ODIN_OS == .Windows {
		src := [1]string{"C:\\Odin"}
	} else {
		src := [1]string{"/opt/odin"}
	}
	for d in src {
		append(&dirs, d)
	}
	return dedupe_dirs(dirs[:], context.temp_allocator)
}

// resolve_odin_toolchain locates ols and the odin compiler. ols has no
// standard install location, so it resolves through PATH only — normal
// resolution carries no hardcoded machine locations (a ~/ols checkout is
// deliberately not probed; pin an explicit path in language_servers when
// PATH cannot carry it). The odin compiler keeps its candidate dirs (the
// official ~/Odin convention).
resolve_odin_toolchain :: proc() -> (ols_bin, odin_bin: string) {
	ols_bin = find_in_path("ols", context.temp_allocator)
	odin_bin = look_path_with_fallbacks("odin", odin_candidate_dirs(), context.temp_allocator)
	return
}

// check_odin_runtime requires both ols and the odin compiler: ols locates
// the core collection and runs `odin check` through the compiler.
check_odin_runtime :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err {
	ols_bin, odin_bin := resolve_odin_toolchain()
	if ols_bin == "" {
		return not_installed_err("ols", ODIN_INSTALL_HINT, arena)
	}
	if odin_bin == "" {
		return not_installed_err("Odin", ODIN_INSTALL_HINT, arena)
	}
	return nil
}

resolve_odin_command :: proc(reg: ^Registry, a: mem.Allocator) -> ([]string, platform.Err) {
	ols_bin, _ := resolve_odin_toolchain()
	if ols_bin == "" {
		return nil, nil
	}
	return make_argv({ols_bin}, a), nil
}

// odin_extra_path_dirs reports the directories holding ols and odin so
// they can be prepended to the language server's PATH: ols invokes
// `odin check` and finds the core collection via the odin binary.
odin_extra_path_dirs :: proc(reg: ^Registry, a: mem.Allocator) -> []string {
	ols_bin, odin_bin := resolve_odin_toolchain()
	return toolchain_dirs(ols_bin, odin_bin, a)
}

// ---------------------------------------------------------------- registration

register_major_entries :: proc(reg: ^Registry) {
	registry_add(reg, {
		id                = "go",
		display_name      = "Go",
		file_patterns     = {"*.go"},
		priority          = PRIORITY_NORMAL,
		// gopls builds one view per workspace folder, so a project root
		// holding sibling Go modules is covered by a single server as long
		// as every module directory is announced at initialize. Without
		// this, a module-less root loads zero packages and every semantic
		// answer comes back empty.
		root_markers      = {"go.mod"},
		multi_root        = true,
		command           = "gopls",
		env = {
			{"GOTELEMETRY", "off"},
			// Soft in-process memory limit: the Go runtime reads this
			// directly and paces the GC before the OS-level containment
			// ceiling is reached. It sits ~12% below the hard cap so the
			// GC engages first and the OOM kill stays a last resort;
			// gopls v0.23 rejects "memoryLimit" as an initialisation
			// option, so the environment variable is the
			// version-independent carrier.
			{"GOMEMLIMIT", "3584MiB"},
		},
		memory_limit_mb = GO_MEMORY_LIMIT_MB,
		check_runtime   = check_go_runtime,
		resolve_command = resolve_go_command,
		extra_path_dirs = go_extra_path_dirs,
		install_hint    = GO_INSTALL_HINT,
		normalize       = normalize_go_symbol_name,
	})

	registry_add(reg, {
		id                = "python",
		display_name      = "Python",
		file_patterns     = {"*.py", "*.pyi"},
		priority          = PRIORITY_NORMAL,
		command           = "pyright-langserver",
		args              = {"--stdio"},
		init_options_json = PYTHON_INIT_OPTIONS,
		check_runtime     = check_python_runtime,
		resolve_command   = resolve_python_command,
	})

	registry_add(reg, {
		id                = "python_jedi",
		display_name      = "Python (Jedi)",
		file_patterns     = {"*.py", "*.pyi"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "jedi-language-server",
		required_binaries = {{"jedi-language-server", "jedi-language-server"}},
	})

	registry_add(reg, {
		id                = "python_ty",
		display_name      = "Python (Ty)",
		file_patterns     = {"*.py", "*.pyi"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "uvx",
		args              = {"--from", "ty", "ty", "server"},
		required_any_of   = {{names = {"uvx", "uv"}, display_name = "uv/uvx"}},
	})

	registry_add(reg, {
		id                = "typescript",
		display_name      = "TypeScript",
		file_patterns     = ts_js_file_patterns(),
		priority          = PRIORITY_NORMAL,
		command           = "typescript-language-server",
		args              = {"--stdio"},
		required_binaries = {{"node", "Node.js"}, {"typescript-language-server", "typescript-language-server"}},
		install_hint      = "npm install -g typescript-language-server typescript",
	})

	registry_add(reg, {
		id                = "typescript_vts",
		display_name      = "TypeScript (VTS)",
		file_patterns     = ts_js_file_patterns(),
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "vtsls",
		args              = {"--stdio"},
		required_binaries = {{"node", "Node.js"}, {"vtsls", "vtsls"}},
		install_hint      = "npm install -g @vtsls/language-server",
	})

	registry_add(reg, {
		id                = "rust",
		display_name      = "Rust",
		file_patterns     = {"*.rs"},
		priority          = PRIORITY_NORMAL,
		// rust-analyzer loads every announced workspace folder as its own
		// project root, so sibling Cargo packages in one project root all
		// get semantic answers (path dependencies between them resolve).
		// Nested markers (workspace members below a workspace root) are
		// collected too; rust-analyzer tolerates the redundant loads.
		root_markers      = {"Cargo.toml"},
		multi_root        = true,
		command           = "rust-analyzer",
		check_runtime     = check_rust_runtime,
		resolve_command   = resolve_rust_command,
		extra_path_dirs   = rust_extra_path_dirs,
	})

	registry_add(reg, {
		id                = "dart",
		display_name      = "Dart",
		file_patterns     = {"*.dart"},
		priority          = PRIORITY_NORMAL,
		// The Dart analysis server has accepted several analysis roots
		// since its original protocol (the included-roots array), and its
		// LSP face maps every workspace folder to one analysis root, so
		// sibling packages in one project root are all analyzed.
		root_markers      = {"pubspec.yaml"},
		multi_root        = true,
		command           = "dart",
		args              = {"language-server"},
		check_runtime     = check_dart_runtime,
		resolve_command   = resolve_dart_command,
		install_hint      = DART_INSTALL_HINT,
	})

	registry_add(reg, {
		id             = "odin",
		display_name   = "Odin",
		file_patterns  = {"*.odin"},
		priority       = PRIORITY_NORMAL,
		// ols takes every workspace folder at initialize and runs
		// references, workspace/symbol, and package checks across all of
		// them; its ols.json is read from the first folder only, so the
		// manager's folder order (configured seeds first, then sorted
		// discovery) decides which project's collections apply.
		root_markers    = {"ols.json", ".git"},
		multi_root      = true,
		// Without collections ols cannot resolve collection imports
		// (`import "src:..."`), so references and workspace symbols
		// silently stay same-package. The remedy stays inside aubade's
		// config: collections ride the initialize handshake's
		// initializationOptions (the language_server_options key of
		// project.jsonc) — aubade never directs anyone to create a
		// per-server config file. An ols.json that already exists also
		// carries collections, so the note stands down for it too.
		config_note_files       = {"ols.json"},
		config_note_option_keys = {"collections"},
		config_note             = "references and workspace symbols stay same-package: ols cannot resolve collection imports (import \"src:...\") without collections. Set them with config_set: key language_server_options, member odin, value {\"collections\": [{\"name\": \"src\", \"path\": \"src\"}]} — both fields are the server's own: name is the prefix before the colon in the imports, path is the directory holding that collection's packages, relative to the first workspace folder (the server binary's own location is designated separately, by language_servers' path; config_get with include_schema documents every key). The write applies live: running servers restart on demand with the new options",
		command         = "ols",
		check_runtime  = check_odin_runtime,
		resolve_command = resolve_odin_command,
		extra_path_dirs = odin_extra_path_dirs,
		install_hint   = ODIN_INSTALL_HINT,
	})
}
