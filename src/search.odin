package doma

// ## Changes
// - 2026-07-29: BM25 over all loaded indexes, deterministic tie-break (DESIGN.md §5).
// - 2026-07-29: rank before breadcrumb — bounded top-k heap, cheap (corpus,file,start)
//   tie key; breadcrumbs built by the presentation layer for survivors only (DESIGN.md §5).

import "core:container/priority_queue"
import "core:math"
import "core:slice"
import "core:strings"

K1 :: 1.2
B  :: 0.75

Hit :: struct {
	corpus: string,
	// idx borrows from the `loaded` slice passed to search; that slice (and its
	// indexes) must outlive the returned hits.
	idx:    ^Index,
	chunk:  u32,
	score:  f64,
}

// breadcrumb_of builds a hit's display path. Only the presentation layer calls this,
// for the ≤k survivors — search() no longer materialises breadcrumbs (DESIGN.md §5).
breadcrumb_of :: proc(idx: ^Index, chunk: u32, allocator := context.allocator) -> string {
	c := idx.chunks[chunk]
	parts := make([]string, c.crumb_len, allocator)
	for i in 0 ..< int(c.crumb_len) do parts[i] = seg(idx, idx.crumbs[c.crumb_off + u32(i)])
	return strings.join(parts, " > ", allocator)
}

// hit_better reports whether a outranks b in final output order: higher score first,
// then the cheap deterministic tie key (corpus, file id, chunk start). That key is a
// total order — two chunks never share (corpus,file,start) — so output is fully
// deterministic without touching breadcrumbs (DESIGN.md §5).
hit_better :: proc(a, b: Hit) -> bool {
	if a.score != b.score do return a.score > b.score
	if a.corpus != b.corpus do return a.corpus < b.corpus
	ca := a.idx.chunks[a.chunk]; cb := b.idx.chunks[b.chunk]
	if ca.file != cb.file do return ca.file < cb.file
	return ca.start < cb.start
}

search :: proc(loaded: []Loaded, query: string, topk: int, allocator := context.allocator) -> []Hit {
	q := tokenize(transmute([]u8)query, allocator)
	if len(q) == 0 do return nil
	if topk == 0 do return nil // negative topk means "all"; zero means none

	// Aggregate corpus stats across all indexes (DESIGN.md §5).
	N := f64(0); total_tokens := f64(0)
	for l in loaded { N += f64(l.idx.total_chunks); total_tokens += f64(l.idx.total_tokens) }
	if N == 0 do return nil
	avgdl := total_tokens / N

	// Global df per unique query term.
	seen := make(map[string]bool, allocator)
	uniq := make([dynamic]string, allocator)
	for tok in q do if !seen[tok.text] { seen[tok.text] = true; append(&uniq, tok.text) }
	df := make(map[string]f64, allocator)
	for term in uniq {
		d := f64(0)
		for &l in loaded {
			ti := find_term(&l.idx, term)
			if ti >= 0 do d += f64(l.idx.terms[ti].post_len)
		}
		df[term] = d
	}

	// Accumulate BM25 per (index, chunk) and keep only the top-k as we go: a bounded
	// min-heap whose root is the *worst* survivor. Pushing every candidate and evicting
	// the root once size exceeds k is O(n log k), and — the point of Candidate B — no
	// breadcrumb is built for the candidates that never survive.
	worst_first :: proc(a, b: Hit) -> bool { return hit_better(b, a) } // root = worst
	heap: priority_queue.Priority_Queue(Hit)
	priority_queue.init(&heap, worst_first, priority_queue.default_swap_proc(Hit), max(topk, 0) + 1, allocator)

	for &l in loaded {
		scores := make(map[u32]f64, allocator)
		for term in uniq {
			n := df[term]
			if n == 0 do continue // absent everywhere -> contributes nothing
			idf := math.ln((N - n + 0.5) / (n + 0.5) + 1)
			ti := find_term(&l.idx, term)
			if ti < 0 do continue
			tr := l.idx.terms[ti]
			for p in l.idx.postings[tr.post_off:tr.post_off + tr.post_len] {
				dl := f64(l.idx.chunks[p.chunk].tok_len)
				tf := f64(p.tf)
				norm := tf * (K1 + 1) / (tf + K1 * (1 - B + B * dl / avgdl))
				scores[p.chunk] += idf * norm
			}
		}
		for chunk, sc in scores {
			h := Hit{corpus = l.corpus, idx = &l.idx, chunk = chunk, score = sc}
			if topk >= 0 && priority_queue.len(heap) == topk {
				if hit_better(priority_queue.peek(heap), h) do continue // worse than every survivor
				priority_queue.pop(&heap)
			}
			priority_queue.push(&heap, h)
		}
	}

	// Drain the ≤k survivors and sort them into final (best-first) order.
	hits := make([]Hit, priority_queue.len(heap), allocator)
	for i in 0 ..< len(hits) do hits[i] = priority_queue.pop(&heap)
	slice.sort_by(hits, hit_better)
	return hits
}
