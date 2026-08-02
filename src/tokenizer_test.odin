package doma

// ## Changes
// - 2026-07-29: Tokenizer tests — camelCase split, offsets, non-ASCII passthrough, 64-byte truncation.

import "core:testing"

@(test)
tokenize_basic_rules :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	toks := tokenize(transmute([]u8)string("Hello, getValue snake_case ABC123"))
	got := make([]string, len(toks))
	for tok, i in toks do got[i] = tok.text
	// camelCase splits lower->UPPER; underscore & punctuation split; ASCII lowercased.
	// "ABC123" has no lower->UPPER boundary, stays one token, lowercased.
	want := []string{"hello", "get", "value", "snake", "case", "abc123"}
	testing.expect_value(t, len(got), len(want))
	for w, i in want do testing.expect_value(t, got[i], w)
}

@(test)
tokenize_offsets_and_nonascii :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("a café")
	toks := tokenize(src)
	testing.expect_value(t, len(toks), 2)
	testing.expect_value(t, toks[0].text, "a")
	testing.expect_value(t, toks[0].start, 0)
	testing.expect_value(t, toks[0].end, 1)
	// Non-ASCII bytes pass through unfolded and stay in the token.
	testing.expect_value(t, toks[1].text, "café")
	testing.expect_value(t, src[toks[1].start], 'c')
}

@(test)
tokenize_truncates_at_64_bytes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	long := make([]u8, 100)
	for i in 0 ..< 100 do long[i] = 'a'
	toks := tokenize(long)
	testing.expect_value(t, len(toks), 1)
	testing.expect_value(t, len(toks[0].text), 64)
	testing.expect_value(t, toks[0].start, 0)
	testing.expect_value(t, toks[0].end, 100) // range spans the whole source word
}
