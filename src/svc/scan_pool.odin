// Bounded parallel per-file executor for the whole-project scans. The
// scans were parse-bound and single-threaded: one file at a time through
// read → parse → outline/hash/tokenize set their multi-second floor.
// scan_run spreads the per-file work over a small pool of dedicated
// worker threads — never the daemon's dispatch pool, whose saturation
// under a scan parent blocking on its own sub-tasks is the classic pool
// self-deadlock — and the caller then merges the results in walk order,
// so the assembled answer is identical to the sequential walk's: the
// merge, not the completion order, decides every ordering the tools
// expose.
//
// Work sharing: each worker owns two arenas — a scratch arena reset
// between files (the parse working set) and a result arena that lives
// until the merge has read it. The body writes its per-file job into
// the result arena and stores the pointer into the scan's job array:
// one slot per file, written by exactly the worker that claimed the
// file, read only after every worker joined (the join is the
// synchronization edge). Shared state the bodies touch — the L2 hot
// cache (mutex-guarded entries), the lazy outliner map, the editor's
// per-file locks, the cancel token — is thread-safe by construction;
// the caller's request arena is not, which is why results stage in the
// worker arenas and clone out during the merge.
//
// Cancellation keeps the existing token discipline: the claim loop
// checks the token before each file (the checkpoint the sequential
// loops had at loop head), a body that observes a mid-file cancel sets
// its worker flag, and either stops the pool — remaining files stay
// unclaimed and the caller returns its .Cancelled error as before.
package svc

import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

import "src:platform"

// Worker ceiling. Parse memory (a resident tree runs ~25x its source)
// and the hot cache's byte budget cap the useful width well below the
// dispatch pool's size; four workers bound the in-flight trees while
// taking most of the parse wall time off repo-scale scans.
SCAN_MAX_WORKERS :: 4
// Below this file count the inline path wins — thread setup would cost
// more than the work (small projects, tests).
SCAN_POOL_MIN_FILES :: 24

Scan_Body :: proc(w: ^Scan_Worker, i: int)

Scan_Worker :: struct {
	pool:        ^Scan_Pool,
	scratch:     mem.Dynamic_Arena, // per-file working set, reset between files
	result:      mem.Dynamic_Arena, // per-worker jobs; read by the merge, then destroyed
	cancel_seen: bool,              // the body observed the token fire mid-file
}

Scan_Pool :: struct {
	body:      Scan_Body,
	user:      rawptr, // scan-specific context the body casts back
	token:     ^platform.Cancel_Token,
	allocator: mem.Allocator,
	count:     int,  // file-slot count
	next:      int,  // next unclaimed index (mu)
	cancelled: bool, // stop claiming: a worker saw the token fire (mu)
	mu:        sync.Mutex,
}

// Scan_Run is a finished run: the workers have joined, so the result
// arenas are readable until scan_run_destroy.
Scan_Run :: struct {
	pool:      ^Scan_Pool,
	workers:   []^Scan_Worker,
	cancelled: bool,
}

// scan_run executes body over file slots [0, count) on up to `workers`
// dedicated threads; workers = 0 picks automatically (inline below
// SCAN_POOL_MIN_FILES, else min(SCAN_MAX_WORKERS, cpus)), workers = 1
// runs the identical claim loop inline on the calling thread. `a` must
// be thread-safe — the workers' arenas grow on it from their own
// threads (the daemon's heap allocator qualifies; a Dynamic_Arena does
// not, and the spawned path would corrupt it). The returned run must be
// merged from and then scan_run_destroy-ed.
scan_run :: proc(
	a: mem.Allocator,
	count: int,
	token: ^platform.Cancel_Token,
	body: Scan_Body,
	user: rawptr,
	workers: int,
) -> (r: Scan_Run) {
	n := workers
	if n == 0 {
		n = scan_auto_workers(count)
	}
	if n < 1 {
		n = 1
	}
	if count > 0 && n > count {
		n = count
	}
	pool := new(Scan_Pool, a)
	pool^ = {body = body, user = user, token = token, allocator = a, count = count}
	ws := make([]^Scan_Worker, n, a)
	for i in 0..<n {
		w := new(Scan_Worker, a)
		w^ = {pool = pool}
		ws[i] = w
	}

	if n == 1 {
		scan_worker_main(ws[0])
	} else {
		// Thread handles come from `a` (the daemon's spawn idiom): the
		// joining thread frees them through it regardless of which
		// context runs here.
		prev := context.allocator
		context.allocator = a
		handles := make([]^thread.Thread, n, a)
		for i in 0..<n {
			handles[i] = thread.create_and_start_with_data(
				ws[i], scan_worker_main, self_cleanup = false, name = "aubade-scan",
			)
		}
		context.allocator = prev
		for i in 0..<n {
			thread.join(handles[i])
			free(handles[i], a)
		}
		delete(handles, a)
	}
	return {pool = pool, workers = ws, cancelled = pool.cancelled}
}

scan_auto_workers :: proc(count: int) -> int {
	if count < SCAN_POOL_MIN_FILES {
		return 1
	}
	// The affinity-aware count: a taskset/cgroup-restricted daemon must
	// not oversubscribe its allowance.
	cpus := os.get_processor_core_count()
	if cpus < 1 {
		cpus = 1
	}
	return min(SCAN_MAX_WORKERS, cpus)
}

// scan_worker_main is the claim loop: claim the next file slot,
// checkpoint the token, reset the per-file arenas, run the body. The
// single-worker run calls it inline on the calling thread — the setup
// below (own arenas, own context.temp_allocator) makes the inline path
// identical to a spawned one, which is what keeps one body
// implementation for both.
scan_worker_main :: proc(data: rawptr) {
	w := cast(^Scan_Worker)data
	p := w.pool
	mem.dynamic_arena_init(&w.scratch, p.allocator)
	mem.dynamic_arena_init(&w.result, p.allocator)
	temp: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp, p.allocator)
	prev_alloc := context.allocator
	prev_temp := context.temp_allocator
	context.allocator = p.allocator
	context.temp_allocator = mem.dynamic_arena_allocator(&temp)
	for {
		sync.mutex_lock(&p.mu)
		i := -1
		if !p.cancelled && p.next < p.count {
			i = p.next
			p.next += 1
		}
		sync.mutex_unlock(&p.mu)
		if i < 0 {
			break
		}
		if p.token != nil {
			if _, fired := platform.token_check(p.token); fired {
				scan_pool_stop(p)
				break
			}
		}
		mem.dynamic_arena_free_all(&w.scratch)
		free_all(context.temp_allocator)
		p.body(w, i)
		if w.cancel_seen {
			scan_pool_stop(p)
			break
		}
	}
	context.allocator = prev_alloc
	context.temp_allocator = prev_temp
	mem.dynamic_arena_destroy(&temp)
}

scan_pool_stop :: proc(p: ^Scan_Pool) {
	sync.mutex_lock(&p.mu)
	p.cancelled = true
	sync.mutex_unlock(&p.mu)
}

// scan_scratch / scan_result hand the body its two arenas' allocators.
scan_scratch :: proc(w: ^Scan_Worker) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&w.scratch)
}

scan_result :: proc(w: ^Scan_Worker) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&w.result)
}

// scan_run_destroy releases the run — worker arenas (the merge has read
// them), worker structs, and the pool — and then returns the scan's
// freed pages to the OS: a run's parses and arenas are a mass-free
// boundary, and on glibc the freed chunks would otherwise stay resident
// (see platform.heap_trim). Destroy is the one exit every path takes —
// cancelled runs included — so the release lives here, not at each
// caller. Safe only after the workers stopped: the spawned path joined
// them, the inline path returned.
scan_run_destroy :: proc(r: ^Scan_Run) {
	if r.pool == nil {
		return
	}
	for w in r.workers {
		mem.dynamic_arena_destroy(&w.scratch)
		mem.dynamic_arena_destroy(&w.result)
		free(w, r.pool.allocator)
	}
	alloc := r.pool.allocator
	delete(r.workers, alloc)
	free(r.pool, alloc)
	r^ = {}
	platform.heap_trim()
}
