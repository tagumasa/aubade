// aubade entry point: everything lives behind the cli table (init, mcp,
// setup, daemon status/stop, and the internal _daemon spawn verb).
package main

import "core:os"
import "src:cli"
import "src:version"

VERSION :: version.AUBADE_VERSION

main :: proc() {
	os.exit(cli.run(os.args[1:], VERSION))
}
