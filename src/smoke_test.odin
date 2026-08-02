package doma

import "core:testing"

@(test)
smoke_ref_roundtrips :: proc(t: ^testing.T) {
	idx := Index{blob = transmute([]u8)string("hello")}
	testing.expect_value(t, seg(&idx, Ref{0, 5}), "hello")
	testing.expect_value(t, seg(&idx, Ref{1, 3}), "ell")
}

// These two are CWD-independent: no-args always prints USAGE (exit 2), help always exits 0.
// (An unknown first token is now context-sensitive — a corpus name or a default query when a
// catalog is present — so it can't be smoke-tested from an ambient working directory.)
@(test)
smoke_no_args_is_usage_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, run([]string{"doma"}), 2)
}

@(test)
smoke_help_is_ok :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, run([]string{"doma", "help"}), 0)
}
