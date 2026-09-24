// probe_in_dir must answer from an exact directory probe: an executable
// file at dir/name hits (exec bit on POSIX, launchable extension on
// Windows), an absent name misses. The Windows suffix probing past the
// exact name is a Windows-build behavior and runs on the CI matrix.
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "src:platform"

@(test)
probe_in_dir_answers_exact_name :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-ep-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	name := "tool.cmd"
	path, _ := filepath.join([]string{dir, name}, context.allocator)
	defer delete(path, context.allocator)
	if werr := os.write_entire_file_from_string(path, "tool\n"); werr != nil {
		testing.expectf(t, false, "fixture write failed")
		return
	}
	// The exec bit carries launchability on POSIX; on Windows the .cmd
	// extension does (chmod there is advisory).
	os.chmod(path, os.Permissions{.Read_User, .Execute_User})

	hit := platform.probe_in_dir(dir, name)
	testing.expectf(t, hit != "", "exact name must hit")
	miss := platform.probe_in_dir(dir, "absent")
	testing.expect_value(t, miss, "")
}
