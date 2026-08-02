package main

// doma — thin CLI shell: hand argv to doma.run, exit with its code.
//
// ## Changes
// - 2026-07-29: Root shell split from src; logic lives in the doma package.

import doma "src"
import "core:os"

main :: proc() {
	os.exit(doma.run(os.args))
}
