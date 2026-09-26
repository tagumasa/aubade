// aubade entry point: main only hands the cli its arguments and the
// version constant — the command table in src/cli owns every command.
package main

import "core:os"
import "src:cli"
import "src:version"

VERSION :: version.AUBADE_VERSION

main :: proc() {
	os.exit(cli.run(os.args[1:], VERSION))
}
