// Tests for the bounded scan worker pool (src/svc/scan_pool): claim
// mechanics (every slot exactly once, jobs readable after the join),
// inline/parallel equivalence, cancellation (a pre-fired token and a
// body-driven stop), and the auto worker sizing.
//
// The pool's backing allocator must be thread-safe (worker arenas grow
// on it from their threads — a Dynamic_Arena backing would corrupt
// under concurrent block allocation). The test framework's tracking
// allocator is itself single-threaded, so every multi-worker test wraps
// it in a Mutex_Allocator; the inline test runs on it directly.
package tests

import "core:mem"
import "core:testing"

import "src:platform"
import "src:svc"

Scan_Slot_Job :: struct {
	slot: int,
}

Scan_Slots_Ctx :: struct {
	jobs: []^Scan_Slot_Job,
}

scan_pool_slot_body :: proc(w: ^svc.Scan_Worker, i: int) {
	ctx := cast(^Scan_Slots_Ctx)w.pool.user
	job := new(Scan_Slot_Job, svc.scan_result(w))
	job^ = {slot = i}
	ctx.jobs[i] = job
}

// scan_pool_check_slots asserts the claim contract: every slot written
// exactly once, with the job's content a pure function of the slot. Must
// run before scan_run_destroy (the jobs live in worker result arenas).
scan_pool_check_slots :: proc(t: ^testing.T, jobs: []^Scan_Slot_Job, count: int) {
	written := 0
	for i in 0..<count {
		if jobs[i] == nil {
			continue
		}
		written += 1
		testing.expectf(t, jobs[i].slot == i, "slot %d carries job for %d", i, jobs[i].slot)
	}
	testing.expectf(t, written == count, "%d of %d slots written", written, count)
}

@(test)
scan_pool_parallel_claims_every_slot :: proc(t: ^testing.T) {
	ma: mem.Mutex_Allocator
	mem.mutex_allocator_init(&ma, context.allocator)
	a := mem.mutex_allocator(&ma)
	COUNT :: 200
	jobs := make([]^Scan_Slot_Job, COUNT, a)
	defer delete(jobs, a)
	ctx := Scan_Slots_Ctx{jobs = jobs[:]}
	run := svc.scan_run(a, COUNT, nil, scan_pool_slot_body, &ctx, 4)
	testing.expect(t, !run.cancelled)
	scan_pool_check_slots(t, jobs[:], COUNT)
	svc.scan_run_destroy(&run)
}

@(test)
scan_pool_inline_path_is_identical :: proc(t: ^testing.T) {
	a := context.allocator
	COUNT :: 32
	jobs := make([]^Scan_Slot_Job, COUNT, a)
	defer delete(jobs, a)
	ctx := Scan_Slots_Ctx{jobs = jobs[:]}
	run := svc.scan_run(a, COUNT, nil, scan_pool_slot_body, &ctx, 1)
	testing.expect(t, !run.cancelled)
	scan_pool_check_slots(t, jobs[:], COUNT)
	svc.scan_run_destroy(&run)
}

@(test)
scan_pool_prefired_token_cancels :: proc(t: ^testing.T) {
	ma: mem.Mutex_Allocator
	mem.mutex_allocator_init(&ma, context.allocator)
	a := mem.mutex_allocator(&ma)
	root := new(platform.Cancel_Token, a)
	platform.token_init_root(root)
	token := platform.token_derive(root, 0, a)
	platform.token_fire(token, .Cancelled)

	COUNT :: 8
	jobs := make([]^Scan_Slot_Job, COUNT, a)
	defer delete(jobs, a)
	ctx := Scan_Slots_Ctx{jobs = jobs[:]}
	run := svc.scan_run(a, COUNT, token, scan_pool_slot_body, &ctx, 4)
	testing.expect(t, run.cancelled)
	svc.scan_run_destroy(&run)

	platform.token_destroy(token, a)
	platform.token_destroy(root, a)
}

// scan_pool_stop_body stops the pool from inside the body at slot 3 —
// the body-driven cancel path a scan takes when its own work observes
// the token fire mid-file.
Scan_Stop_Ctx :: struct {
	jobs:   []^Scan_Slot_Job,
	stop_at: int,
}

scan_pool_stop_body :: proc(w: ^svc.Scan_Worker, i: int) {
	ctx := cast(^Scan_Stop_Ctx)w.pool.user
	if i == ctx.stop_at {
		w.cancel_seen = true
		return
	}
	job := new(Scan_Slot_Job, svc.scan_result(w))
	job^ = {slot = i}
	ctx.jobs[i] = job
}

@(test)
scan_pool_body_stop_cancels :: proc(t: ^testing.T) {
	ma: mem.Mutex_Allocator
	mem.mutex_allocator_init(&ma, context.allocator)
	a := mem.mutex_allocator(&ma)
	COUNT :: 64
	jobs := make([]^Scan_Slot_Job, COUNT, a)
	defer delete(jobs, a)
	ctx := Scan_Stop_Ctx{jobs = jobs[:], stop_at = 3}
	run := svc.scan_run(a, COUNT, nil, scan_pool_stop_body, &ctx, 2)
	testing.expect(t, run.cancelled)
	// Claims hand out in slot order, so 0, 1, and 2 were all claimed —
	// and written, their bodies never check the stop — before slot 3
	// stopped the pool. Nothing is promised about the rest.
	for i in 0..<3 {
		testing.expectf(t, jobs[i] != nil, "slot %d before the stop point unwritten", i)
	}
	svc.scan_run_destroy(&run)
}

@(test)
scan_pool_auto_worker_bounds :: proc(t: ^testing.T) {
	testing.expect(t, svc.scan_auto_workers(0) == 1)
	testing.expect(t, svc.scan_auto_workers(23) == 1)
	n := svc.scan_auto_workers(24)
	testing.expectf(t, n >= 1 && n <= svc.SCAN_MAX_WORKERS, "auto workers out of bounds: %d", n)
}
