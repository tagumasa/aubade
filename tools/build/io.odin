// Process and filesystem helpers for the build program. The exec/compile/
// archive flow (including the Windows MSVC fallbacks) is modeled on
// laytan/odin-tree-sitter's build tooling (MIT).
package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

exec :: proc(command: ..string) -> bool {
	log.infof("run: %s", strings.join(command, " "))

	p, err := os.process_start({
		command = command,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if err != nil {
		log.errorf("starting process: %s", os.error_string(err))
		return false
	}

	state, werr := os.process_wait(p)
	if werr != nil {
		log.errorf("waiting on process: %s", os.error_string(werr))
		return false
	}
	if !state.success {
		log.errorf("process exited with status code: %v", state.exit_code)
		return false
	}
	return true
}

compile_c :: proc(cmd: ^[dynamic]string, cxx := false) -> (ok: bool) {
	when ODIN_OS == .Windows {
		// cl.exe selects C or C++ from the source extension on its own.
		tries := []string{"cl.exe"}
	} else {
		tries := []string{"cc", "gcc", "clang"}
		if cxx {
			tries = []string{"c++", "g++", "clang++"}
		}
	}

	env := "CC"
	if cxx {
		env = "CXX"
	}
	if cc, eok := os.lookup_env_alloc(env, context.temp_allocator); eok {
		tries[0] = cc
	}

	inject_at(cmd, 0, "")
	for try in tries {
		cmd[0] = try
		if ok = exec(..cmd[:]); ok {
			break
		}
	}

	if !ok {
		when ODIN_OS == .Windows {
			log.errorf("failed to compile C code due to above errors. Make sure you are running in a Visual Studio developer command prompt (vcvars).")
		} else {
			log.errorf("failed to compile C code, tried: %s", strings.join(tries, ", "))
		}
	}
	return
}

archive :: proc(cmd: ^[dynamic]string) -> (ok: bool) {
	when ODIN_OS == .Windows {
		tries := []string{"lib.exe"}
	} else {
		tries := []string{"ar"}
	}

	if ar, eok := os.lookup_env_alloc("AR", context.temp_allocator); eok {
		tries[0] = ar
	}

	inject_at(cmd, 0, "")
	for try in tries {
		cmd[0] = try
		if ok = exec(..cmd[:]); ok {
			break
		}
	}

	if !ok {
		log.errorf("failed to archive code into library, tried: %s", strings.join(tries, ", "))
	}
	return
}

rmrf :: proc(path: string) -> bool {
	// Removing an absent path is a no-op success — several callers clean up
	// targets that only exist on rebuild paths.
	if !os.exists(path) {
		return true
	}
	err := os.remove_all(path)
	if err != nil {
		// The posix remove_all opendir()s the path, which fails with
		// "Not a directory" when the path is a regular file (the linux
		// implementation has an explicit unlink fallback for that case);
		// plain remove handles files on every core build.
		if err2 := os.remove(path); err2 != nil {
			log.errorf("failed removing %q: %s", path, os.error_string(err2))
			return false
		}
	}
	return true
}

copy_file :: proc(src, dst: string, try_it := false) -> bool {
	if err := os.copy_file(dst, src); err != nil {
		if try_it {
			return false
		}
		log.errorf("failed copying %q to %q: %s", src, dst, os.error_string(err))
		return false
	}
	return true
}

join_path :: proc(paths: ..string) -> string {
	joined, err := filepath.join(paths, context.allocator)
	assert(err == nil)
	return joined
}

read_text_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("could not read %q: %s", path, os.error_string(err))
		return "", false
	}
	return string(data), true
}

str_lt :: proc(a, b: string) -> bool {
	n := min(len(a), len(b))
	for i in 0..<n {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

sort_strings :: proc(list: ^[dynamic]string) {
	for i in 1..<len(list^) {
		v := list[i]
		j := i - 1
		for j >= 0 && str_lt(v, list[j]) {
			list[j+1] = list[j]
			j -= 1
		}
		list[j+1] = v
	}
}

escape_odin_string :: proc(s: string) -> string {
	needs := false
	for i in 0..<len(s) {
		if s[i] == '"' || s[i] == '\\' {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	out := make([dynamic]u8, 0, len(s) + 8)
	for i in 0..<len(s) {
		if s[i] == '"' || s[i] == '\\' {
			append(&out, '\\')
		}
		append(&out, s[i])
	}
	return string(out[:])
}

// Compiles one C translation unit into tools/build/cache/obj/<obj_name>
// and returns its path, or "" on failure.
compile_c_file :: proc(src, obj_name: string, includes: []string, extra: []string = nil, cxx := false) -> string {
	obj_path := join_path(cache_dir(), "obj", obj_name)
	obj_dir := filepath.dir(obj_path)
	if err := os.make_directory_all(obj_dir); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", obj_dir, os.error_string(err))
		return ""
	}

	cmd: [dynamic]string
	when ODIN_OS == .Windows {
		append(&cmd, "/O2", "/EHsc", "/c")
		for inc in includes {
			append(&cmd, fmt.tprintf("/I%s", inc))
		}
		for flag in extra {
			if strings.has_prefix(flag, "-D") {
				// MSVC spells defines /DNAME: a bare /NAME is an unknown
				// option cl.exe silently ignores, dropping the define.
				append(&cmd, fmt.tprintf("/D%s", flag[2:]))
			} else {
				log.errorf("unsupported extra flag for MSVC: %q", flag)
				return ""
			}
		}
		append(&cmd, fmt.tprintf("/Fo%s", obj_path), src)
	} else {
		append(&cmd, "-O2", "-c")
		for inc in includes {
			append(&cmd, fmt.tprintf("-I%s", inc))
		}
		append(&cmd, ..extra[:])
		append(&cmd, "-o", obj_path, src)
	}

	if !compile_c(&cmd, cxx) {
		return ""
	}
	return obj_path
}

// write_response_file serializes object paths for lib.exe's @file operand,
// one quoted path per line (LIB applies its command-line quoting rules to
// the file's contents).
write_response_file :: proc(rsp_path: string, objs: []string) -> bool {
	rsp_dir := filepath.dir(rsp_path)
	if err := os.make_directory_all(rsp_dir); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", rsp_dir, os.error_string(err))
		return false
	}
	buf := strings.builder_make_len_cap(0, 4096, context.allocator)
	defer strings.builder_destroy(&buf)
	for o in objs {
		strings.write_string(&buf, "\"")
		strings.write_string(&buf, o)
		strings.write_string(&buf, "\"\r\n")
	}
	if werr := os.write_entire_file(rsp_path, buf.buf[:]); werr != nil {
		log.errorf("could not write %q: %s", rsp_path, os.error_string(werr))
		return false
	}
	return true
}

// archive_objs creates the archive fresh from the given objects. On Windows
// the object list travels in an @response file — the grammar set's hundreds
// of paths overflow the 32 KiB process command line — and the archive must
// never be fed back in as an input: merge-style updates are exactly what
// lib.exe quietly drops while exiting 0. Fresh creation behaves identically
// to the unix `ar cr` path.
archive_objs :: proc(lib_path: string, objs: ..string) -> (ok: bool) {
	cmd: [dynamic]string
	when ODIN_OS == .Windows {
		rsp_path := join_path(cache_dir(), "archive.rsp")
		if !write_response_file(rsp_path, objs[:]) {
			return false
		}
		append(&cmd, fmt.tprintf("/OUT:%s", lib_path))
		append(&cmd, fmt.tprintf("@%s", rsp_path))
		ok = archive(&cmd)
		os.remove(rsp_path)
	} else {
		append(&cmd, "cr", lib_path)
		append(&cmd, ..objs[:])
		ok = archive(&cmd)
	}
	return
}
