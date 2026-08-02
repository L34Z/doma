package doma

// ## Changes
// - 2026-07-29: Pure freshness verdict tests (ADR-0001, two-tier staleness).

import "core:testing"

// Unchanged file: size matches the record and mtime is no newer than the
// index's own mtime -> Fresh, no read required.
@(test)
freshness_unchanged_is_fresh :: proc(t: ^testing.T) {
	rec := File_Rec{length = 100}
	st  := File_State{present = true, size = 100, mtime = 5}
	testing.expect_value(t, freshness_of(rec, st, 10), Freshness.Fresh)
}

// A file that no longer exists on disk is stale outright — no bytes to hash.
@(test)
freshness_missing_is_stale :: proc(t: ^testing.T) {
	rec := File_Rec{length = 100}
	st  := File_State{present = false}
	testing.expect_value(t, freshness_of(rec, st, 10), Freshness.Stale)
}

// Size differs from the record: content changed for sure, but the gate only flags
// it suspect and lets the hash arbiter confirm (uniform with the touch case).
@(test)
freshness_size_change_is_suspect :: proc(t: ^testing.T) {
	rec := File_Rec{length = 100}
	st  := File_State{present = true, size = 101, mtime = 5}
	testing.expect_value(t, freshness_of(rec, st, 10), Freshness.Suspect)
}

// Same size but mtime newer than the index: this is the `touch` shape — suspect,
// so the arbiter re-hashes and (if bytes match) keeps it fresh.
@(test)
freshness_newer_mtime_is_suspect :: proc(t: ^testing.T) {
	rec := File_Rec{length = 100}
	st  := File_State{present = true, size = 100, mtime = 11}
	testing.expect_value(t, freshness_of(rec, st, 10), Freshness.Suspect)
}
