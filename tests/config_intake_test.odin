// Stat-first intake gates for config/state files: the shared read_gate
// verdict, the config-file reader refusing oversized or non-regular files
// before reading a byte, and registry_load refusing an oversized
// projects.json instead of looking empty (a save after an empty-looking
// load would discard the file's entries).
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:config"
import "src:platform"
import "src:util"

@(test)
util_read_gate_outcomes :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-gate-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	small, _ := filepath.join({tmp, "small.jsonc"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(small, "{}"); werr != nil {
		testing.fail_now(t, "write failed")
	}
	testing.expectf(t, util.read_gate(small, 1024) == .Ok, "small regular file: Ok")
	testing.expectf(t, util.read_gate(small, 1) == .Too_Large, "size cap applies: Too_Large")

	// The temp dir itself is a directory, not a regular file.
	testing.expectf(t, util.read_gate(tmp, 1024) == .Not_Regular, "directory: Not_Regular")

	missing, _ := filepath.join({tmp, "missing"}, context.temp_allocator)
	testing.expectf(t, util.read_gate(missing, 1024) == .Missing, "absent path: Missing")
}

@(test)
config_read_refuses_before_reading :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cap-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	big, _ := filepath.join({tmp, "config.jsonc"}, context.temp_allocator)
	blob := make([]u8, config.MAX_CONFIG_BYTES + 1, context.allocator)
	defer delete(blob)
	if werr := os.write_entire_file(big, blob); werr != nil {
		testing.fail_now(t, "write failed")
	}
	data, miss, rerr := config.read_config_file(big, context.temp_allocator)
	testing.expectf(
		t, data == nil && !miss && rerr != nil,
		"oversized config refused without reading: miss=%v err=%v", miss, rerr,
	)
	testing.expectf(t, platform.err_kind(rerr) == .Invalid, "refusal is Invalid: %v", rerr)

	dir_path, _ := filepath.join({tmp, "adir"}, context.temp_allocator)
	if merr := os.make_directory_all(dir_path, {.Read_User, .Write_User, .Execute_User}); merr != nil {
		testing.fail_now(t, "mkdir failed")
	}
	data, miss, rerr = config.read_config_file(dir_path, context.temp_allocator)
	testing.expectf(
		t, data == nil && !miss && rerr != nil,
		"directory at the config path refused: miss=%v err=%v", miss, rerr,
	)
}

@(test)
registry_load_refuses_oversized_registry :: proc(t: ^testing.T) {
	home, err := os.make_directory_temp("", "aubade-reghi-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home)
	}

	reg_path := platform.projects_registry_path(home, context.temp_allocator)
	blob := make([]u8, config.MAX_CONFIG_BYTES + 1, context.allocator)
	defer delete(blob)
	if werr := os.write_entire_file(reg_path, blob); werr != nil {
		testing.fail_now(t, "write failed")
	}

	_, lerr := config.registry_load(home, context.temp_allocator)
	testing.expectf(t, lerr != nil, "oversized projects.json must fail, not load empty")
	if lerr != nil {
		msg := platform.err_message(lerr, context.temp_allocator)
		testing.expectf(
			t,
			strings.contains(msg, "exceeds"),
			"the failure names the size limit: %s",
			msg,
		)
	}
}
