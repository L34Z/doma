package doma

// ## Changes
// - 2026-07-29: Markdown heading chunker with breadcrumbs (DESIGN.md §2).
//   A heading at level L opens a chunk spanning to the next heading of level <= L
//   (equal-or-higher importance) or EOF; ranges may nest. This is literal per DESIGN
//   and is an honest limit: coarse chunks contain their subsections' bytes.
// - 2026-07-29: Fix sibling-heading contiguity bug. Switched to open-order emission:
//   append the chunk at OPEN (document order) with a placeholder end, record its index
//   on the stack, and fill end at close. Sibling same-level headings no longer split
//   the parent's range; the parent stays a single contiguous [start, EOF).
// - 2026-08-01: Language-agnostic code chunker (chunk_code). A line that begins in
//   column 0 with real content — not blank, not a comment, not a lone closing
//   delimiter — opens a chunk running to the next such line or EOF; the run before the
//   first opener is a preamble chunk. This is a heuristic, not a parser: it lands a
//   query on a function- or type-sized passage. Honest limits: a construct whose
//   signature is indented (a nested def, a K&R brace alone on its line) folds into its
//   parent, and a column-0 line inside a raw/multiline string can false-open (unlike
//   Markdown fences, code strings are not tracked).

import "core:strings"
import "base:runtime"

Raw_Chunk :: struct {
	start:  int,
	end:    int,
	crumbs: []string,
}

@(private = "file") Heading :: struct {
	level:       int,    // 1..6
	text:        string, // heading title, trimmed
	start:       int,    // byte offset where the chunk begins (heading line start)
	chunk_index: int,    // index into `out` of this heading's chunk (end filled at close)
}

// Returns (level, title, true) if `line` is an ATX heading; level 0 otherwise.
@(private = "file") atx_heading :: proc(line: string) -> (level: int, title: string, ok: bool) {
	i := 0
	for i < len(line) && line[i] == '#' do i += 1
	if i == 0 || i > 6 do return 0, "", false
	if i < len(line) && line[i] != ' ' && line[i] != '\t' do return 0, "", false
	return i, strings.trim_space(line[i:]), true
}

// Detects a setext underline line: all '=' (h1) or all '-' (h2), length >= 1.
@(private = "file") setext_level :: proc(line: string) -> int {
	s := strings.trim_space(line)
	if len(s) == 0 do return 0
	c := s[0]
	if c != '=' && c != '-' do return 0
	for r in transmute([]u8)s do if r != c do return 0
	return 1 if c == '=' else 2
}

@(private = "file") is_fence :: proc(line: string) -> bool {
	s := strings.trim_left_space(line)
	return strings.has_prefix(s, "```") || strings.has_prefix(s, "~~~")
}

chunk_markdown :: proc(src: []u8, basename, relpath: string, allocator := context.allocator) -> []Raw_Chunk {
	text := string(src)
	out := make([dynamic]Raw_Chunk, allocator)
	stack := make([dynamic]Heading, allocator) // open headings, ascending level
	in_fence := false
	prev_line_start := -1
	prev_line := ""
	first_heading_seen := false

	// Close all open headings of level >= L, filling their chunk's end with `pos`.
	close_to :: proc(out: ^[dynamic]Raw_Chunk, stack: ^[dynamic]Heading, L, pos: int) {
		for len(stack) > 0 && stack[len(stack) - 1].level >= L {
			entry := pop(stack)
			out[entry.chunk_index].end = pos
		}
	}

	// Open a heading `h`: emit preamble if this is the first heading and there is one,
	// close open headings of level >= h.level, push h, and append its (open) chunk.
	open_heading :: proc(out: ^[dynamic]Raw_Chunk, stack: ^[dynamic]Heading, first_seen: ^bool, h: Heading, base, rel: string, a: runtime.Allocator) {
		if !first_seen^ {
			first_seen^ = true
			if h.start > 0 {
				crumbs := make([dynamic]string, a)
				append(&crumbs, base, rel)
				append(out, Raw_Chunk{start = 0, end = h.start, crumbs = crumbs[:]})
			}
		}
		close_to(out, stack, h.level, h.start)
		h := h
		append(stack, h)
		// Breadcrumbs = [base, rel] + text of every heading on the stack, bottom->top.
		crumbs := make([dynamic]string, a)
		append(&crumbs, base, rel)
		for e in stack do append(&crumbs, e.text)
		append(out, Raw_Chunk{start = h.start, end = 0, crumbs = crumbs[:]})
		stack[len(stack) - 1].chunk_index = len(out) - 1
	}

	i := 0
	for i < len(text) {
		// Slice the current line [ls, le); nl points past the newline.
		ls := i
		le := ls
		for le < len(text) && text[le] != '\n' do le += 1
		line := text[ls:le]
		nl := le + 1 if le < len(text) else le

		if is_fence(line) {
			in_fence = !in_fence
			prev_line_start = ls; prev_line = line
			i = nl; continue
		}
		if !in_fence {
			if lvl, title, ok := atx_heading(line); ok {
				h := Heading{level = lvl, text = title, start = ls}
				open_heading(&out, &stack, &first_heading_seen, h, basename, relpath, allocator)
				prev_line_start = ls; prev_line = line
				i = nl; continue
			}
			if slvl := setext_level(line); slvl != 0 && prev_line_start >= 0 {
				ptrim := strings.trim_space(prev_line)
				_, _, was_atx := atx_heading(prev_line)
				if len(ptrim) > 0 && !was_atx {
					h := Heading{level = slvl, text = ptrim, start = prev_line_start}
					open_heading(&out, &stack, &first_heading_seen, h, basename, relpath, allocator)
					prev_line_start = ls; prev_line = line
					i = nl; continue
				}
			}
		}
		prev_line_start = ls; prev_line = line
		i = nl
	}
	// Close remaining headings at EOF, or emit whole file as preamble if no heading seen.
	if !first_heading_seen {
		crumbs := make([dynamic]string, allocator)
		append(&crumbs, basename, relpath)
		append(&out, Raw_Chunk{start = 0, end = len(text), crumbs = crumbs[:]})
	} else {
		close_to(&out, &stack, 0, len(text))
	}
	return out[:]
}

CODE_CRUMB_MAX :: 80 // signature breadcrumb truncated at 80 bytes (honest limit)

// code_opener reports whether `line` starts a top-level definition and, if so, returns
// the signature label for its breadcrumb. An opener begins in column 0 (no leading
// whitespace) with a byte that isn't a comment marker or a closing delimiter. The label
// is the trimmed line with a trailing brace/space stripped, truncated on a UTF-8 rune
// boundary so the crumb is always valid text.
@(private = "file")
code_opener :: proc(line: string) -> (sig: string, ok: bool) {
	if len(line) == 0 do return "", false
	c0 := line[0]
	if c0 == ' ' || c0 == '\t' do return "", false // indented: not top-level

	// A closing delimiter or separator alone at column 0 closes a construct, it doesn't open one.
	switch c0 {
	case '}', ')', ']', ',', ';', '*', '@':
		return "", false
	}
	// Common single- and multi-line comment openers across C/Go/Rust/Odin/JS, shell/Python,
	// SQL/Lua, and Lisp. A leading directive like C's `#include` is not a definition either.
	for p in ([]string{"//", "/*", "#", "--", ";", "%"}) {
		if strings.has_prefix(line, p) do return "", false
	}

	trimmed := strings.trim_right(strings.trim_space(line), " \t{")
	if len(trimmed) == 0 do return "", false

	// Truncate on a UTF-8 boundary: back the cut point off any continuation byte (0b10xxxxxx)
	// so the crumb never ends mid-rune (which would be invalid text in JSON output).
	cap_n := min(len(trimmed), CODE_CRUMB_MAX)
	for cap_n > 0 && cap_n < len(trimmed) && (trimmed[cap_n] & 0xC0) == 0x80 do cap_n -= 1
	return trimmed[:cap_n], true
}

// chunk_code splits `src` at top-level definition boundaries (see code_opener). Chunks
// are contiguous and non-overlapping and cover the whole file: [0, first_opener) is the
// preamble, then each opener spans to the next opener or EOF. A file with no opener is a
// single whole-file chunk. Breadcrumbs are [basename, relpath] for the preamble/whole
// file and [basename, relpath, signature] for each definition.
chunk_code :: proc(src: []u8, basename, relpath: string, allocator := context.allocator) -> []Raw_Chunk {
	text := string(src)
	out := make([dynamic]Raw_Chunk, allocator)

	open_idx := -1 // index in `out` of the chunk awaiting its end, or -1 if none is open

	i := 0
	for i < len(text) {
		ls := i
		le := ls
		for le < len(text) && text[le] != '\n' do le += 1
		nl := le + 1 if le < len(text) else le

		if sig, ok := code_opener(text[ls:le]); ok {
			if open_idx < 0 && ls > 0 {
				// Preamble: content before the first definition (package line, imports).
				crumbs := make([dynamic]string, allocator)
				append(&crumbs, basename, relpath)
				append(&out, Raw_Chunk{start = 0, end = ls, crumbs = crumbs[:]})
			}
			if open_idx >= 0 do out[open_idx].end = ls
			crumbs := make([dynamic]string, allocator)
			append(&crumbs, basename, relpath, sig)
			append(&out, Raw_Chunk{start = ls, end = 0, crumbs = crumbs[:]})
			open_idx = len(out) - 1
		}
		i = nl
	}

	if open_idx >= 0 {
		out[open_idx].end = len(text)
	} else {
		// No opener anywhere: the whole file is one chunk.
		crumbs := make([dynamic]string, allocator)
		append(&crumbs, basename, relpath)
		append(&out, Raw_Chunk{start = 0, end = len(text), crumbs = crumbs[:]})
	}

	// Every byte is covered exactly once: chunks are contiguous from 0 to EOF.
	assert(len(out) > 0, "chunk_code must emit at least one chunk")
	assert(out[0].start == 0, "first code chunk must start at byte 0")
	assert(out[len(out) - 1].end == len(text), "last code chunk must end at EOF")
	return out[:]
}
