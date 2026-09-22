// aubade init: create the global config from the commented template. The
// file is write-once — an existing config.jsonc is never overwritten (user
// edits live there; machine state belongs to the registry and the DB).
package cli

import "core:fmt"
import "core:os"
import "src:config"
import "src:platform"

run_init :: proc(args: []string, g: ^Globals, version: string) -> int {
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)
	if !strip_globals(args, g, &rest) {
		return usage_error("init", "invalid global flag value")
	}
	if len(rest) > 0 {
		return usage_error("init", "init takes no arguments")
	}

	home := platform.aubade_home(context.temp_allocator)
	return do_init(home, version, detect_applicable_clients())
}

// do_init writes $AUBADE_HOME/config.jsonc from the template and prints the
// follow-up hints. Split from run_init so tests can drive it against an
// isolated home.
do_init :: proc(home: string, version: string, applicable: []string) -> int {
	fmt.printf("\nAubade version: %s\n\n", version)

	path := platform.config_path(home, context.temp_allocator)
	if os.exists(path) {
		fmt.eprintf("aubade init: config file already exists: %s\n", path)
		return 1
	}
	if err := os.make_directory_all(home); err != nil && !os.is_directory(home) {
		fmt.eprintf("aubade init: cannot create %s\n", home)
		return 1
	}
	body := config.template_global(context.temp_allocator)
	f, oerr := os.open(path, {.Write, .Create, .Excl}, os.Permissions{.Read_User, .Write_User})
	if oerr != nil {
		fmt.eprintf("aubade init: cannot create %s\n", path)
		return 1
	}
	werr := platform.write_all(f, transmute([]u8)body)
	os.close(f)
	if werr != nil {
		os.remove(path)
		fmt.eprintf("aubade init: cannot write %s\n", path)
		return 1
	}

	fmt.printf("Configuration file: %s\n", path)
	if len(applicable) > 0 {
		fmt.println("\nAuto-configurable clients detected.")
		fmt.println("Apply the following commands to configure the Aubade MCP server:")
		for name in applicable {
			fmt.printf("  aubade setup %s\n", name)
		}
	}
	fmt.print("\nAubade has been initialised successfully.\n\n")
	return 0
}

// detect_applicable_clients reports the setup handlers whose clients are
// present on this machine, in the canonical handler order.
detect_applicable_clients :: proc() -> []string {
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	for &c in CLIENT_CMDS {
		if c.applicable() {
			append(&names, c.name)
		}
	}
	return names[:]
}

// user_home_dir resolves the user home directory for client config paths:
// $HOME first (matching platform.aubade_home's ladder), then the core:os
// fallback (USERPROFILE, HOMEDRIVE+HOMEPATH on Windows).
user_home_dir :: proc() -> string {
	if home, ok := os.lookup_env_alloc("HOME", context.temp_allocator); ok && home != "" {
		return home
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		return ""
	}
	return home
}
