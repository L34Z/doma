package doma

// ## Changes
// - 2026-07-29: Tests for highest-density snippet window (DESIGN.md §6).

import "core:strings"
import "core:testing"

@(test)
snippet_picks_densest_window :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	body :=
		"# H\n" +
		"padding padding padding padding padding padding padding padding padding\n" +
		"here is the needle and the second target close together needle target\n" +
		"more padding padding padding padding padding padding padding padding\n"
	src := transmute([]u8)body
	chunk := Chunk_Rec{start = 0, end = u32(len(src))}
	snip := snippet_of(src, chunk, []string{"needle", "target"})
	// The window with both distinct terms wins; snippet contains both.
	testing.expect(t, strings.contains(snip, "needle"), "has needle")
	testing.expect(t, strings.contains(snip, "target"), "has target")
	// Whitespace collapsed: no double spaces, no newlines.
	testing.expect(t, !strings.contains(snip, "  "), "no double spaces")
	testing.expect(t, !strings.contains(snip, "\n"), "no newlines")
	// Ellipsis at the start because the window is past the chunk start.
	testing.expect(t, strings.has_prefix(snip, "…"), "leading ellipsis when truncated")
}

@(test)
snippet_no_query_term_shows_head :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// A chunk well over 200 bytes containing none of the query terms.
	body :=
		"alpha bravo charlie delta echo foxtrot golf hotel india juliet " +
		"kilo lima mike november oscar papa quebec romeo sierra tango " +
		"uniform victor whiskey xray yankee zulu one two three four five " +
		"six seven eight nine ten eleven twelve\n"
	src := transmute([]u8)body
	testing.expect(t, len(src) > SNIPPET_BYTES, "fixture longer than window")
	chunk := Chunk_Rec{start = 0, end = u32(len(src))}
	snip := snippet_of(src, chunk, []string{"needle", "target"})
	// No query hit: show the head, starting at region 0 (no leading ellipsis).
	testing.expect(t, strings.has_prefix(snip, "alpha"), "starts with first word")
	testing.expect(t, !strings.has_prefix(snip, "…"), "no leading ellipsis at head")
	// Chunk longer than the window, so the tail is truncated.
	testing.expect(t, strings.has_suffix(snip, "…"), "trailing ellipsis when truncated")
	testing.expect(t, !strings.contains(snip, "  "), "no double spaces")
	testing.expect(t, !strings.contains(snip, "\n"), "no newlines")
}

@(test)
snippet_short_chunk_no_ellipsis :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// A chunk shorter than the window, with the query term as the first word so
	// the anchor window starts at region 0 (algorithm anchors on the term).
	body := "needle is right here\n"
	src := transmute([]u8)body
	testing.expect(t, len(src) < SNIPPET_BYTES, "fixture shorter than window")
	chunk := Chunk_Rec{start = 0, end = u32(len(src))}
	snip := snippet_of(src, chunk, []string{"needle"})
	// Whole chunk fits one window: no ellipsis at either end.
	testing.expect(t, strings.contains(snip, "needle"), "has needle")
	testing.expect(t, !strings.has_prefix(snip, "…"), "no leading ellipsis")
	testing.expect(t, !strings.has_suffix(snip, "…"), "no trailing ellipsis")
}
