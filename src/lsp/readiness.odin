// Cross-file-reference readiness: after the first didOpen of a workspace,
// symbol queries that hop files (references, call hierarchy) come back
// incomplete until the server has finished initial indexing. Servers show
// that with either the first textDocument/publishDiagnostics or the end of
// a $/progress WorkDone unit; the client waits for either signal within an
// event window and otherwise falls back to a fixed settle wait. This
// replaces the previous implementation's unconditional time.Sleep(2s).
package lsp

import "core:mem"
import "core:sync"
import "core:time"

import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"

CROSSREF_EVENT_TIMEOUT_MS :: i64(5_000)
CROSSREF_FALLBACK_MS :: i64(1_000)

// Event-wait cond slice: the deadline and the cancel token are re-checked
// at this cadence (with a virtual clock the loop only re-reads the clock
// per slice, so tests must advance time past the deadline).
READINESS_SLICE_MS :: i64(25)

Wait_Outcome :: enum {
	Diagnostics, // the first publishDiagnostics arrived
	Progress, // the first $/progress WorkDone end arrived
	Fallback, // no signal; the fixed settle wait ran
	Timeout, // no signal and the fallback is disabled
	Cancelled, // the caller's token fired (the once-latch stays open)
}

Readiness :: struct {
	mu:           sync.Mutex,
	cond:         sync.Cond,
	is_diag_seen:    bool, // first publishDiagnostics (any document) arrived
	is_progress_end: bool, // first $/progress WorkDone end arrived
	is_done:         bool, // once-latch: the first wait completed
	outcome:      Wait_Outcome,
}

readiness_signal_diagnostics :: proc(r: ^Readiness) {
	sync.mutex_lock(&r.mu)
	r.is_diag_seen = true
	sync.cond_broadcast(&r.cond)
	sync.mutex_unlock(&r.mu)
}

readiness_signal_progress_end :: proc(r: ^Readiness) {
	sync.mutex_lock(&r.mu)
	r.is_progress_end = true
	sync.cond_broadcast(&r.cond)
	sync.mutex_unlock(&r.mu)
}

// on_progress watches $/progress for the end of a WorkDone unit — the
// other indexing signal besides the first diagnostics publication.
on_progress :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	cl := cast(^Client)conn.host
	value, ok := jsonutil.obj_get(env.params, "value")
	if !ok {
		return
	}
	kind, kind_ok := jsonutil.obj_get(value, "kind")
	if kind_ok && jsonutil.value_str(kind) == "end" {
		readiness_signal_progress_end(&cl.readiness)
	}
}

// client_wait_cross_file_refs blocks (event window first, fallback second)
// until the server shows first indexing evidence, then latches: every
// later call returns the cached outcome. A cancelled wait does not latch,
// so a retry re-enters it. Checkpoints: the cancel token is checked once
// per slice.
client_wait_cross_file_refs :: proc(cl: ^Client, token: ^platform.Cancel_Token = nil) -> Wait_Outcome {
	r := &cl.readiness
	sync.mutex_lock(&r.mu)
	if r.is_done {
		outcome := r.outcome
		sync.mutex_unlock(&r.mu)
		return outcome
	}

	outcome := Wait_Outcome.Timeout
	if cl.crossref_event_timeout_ms > 0 {
		deadline := platform.clock_now(cl.clock) + cl.crossref_event_timeout_ms
		for !r.is_diag_seen && !r.is_progress_end {
			if token != nil {
				if _, fired := platform.token_check(token); fired {
					sync.mutex_unlock(&r.mu)
					return .Cancelled
				}
			}
			if platform.clock_now(cl.clock) >= deadline {
				break
			}
			// Real-time cond slice by design: the
			// deadline math above reads the injected clock, but the park
			// itself is wall time — only its length bounds wake latency.
			sync.cond_wait_with_timeout(
				&r.cond, &r.mu, time.Duration(READINESS_SLICE_MS * 1_000_000),
			)
		}
		if r.is_diag_seen {
			outcome = .Diagnostics
		} else if r.is_progress_end {
			outcome = .Progress
		}
	}

	if outcome == .Timeout && cl.crossref_fallback_ms > 0 {
		// clock_wait must not hold the gate mutex: the reader thread
		// signals through it while the settle wait runs. The cancel token
		// stays live through the fallback too, so a cancelled caller
		// returns without latching the once-slot.
		sync.mutex_unlock(&r.mu)
		cancelled := false
		if token != nil {
			cancelled = !platform.clock_wait_sliced_until(
				cl.clock,
				token,
				platform.clock_now(cl.clock) + cl.crossref_fallback_ms,
			)
		} else {
			platform.clock_wait(cl.clock, cl.crossref_fallback_ms)
		}
		if cancelled {
			return .Cancelled
		}
		sync.mutex_lock(&r.mu)
		// The fallback slept unlocked: another waiter may have latched the
		// once-slot in the meantime, and a readiness signal that arrived
		// during the sleep outranks the degraded classification.
		if r.is_done {
			latched := r.outcome
			sync.mutex_unlock(&r.mu)
			return latched
		}
		if r.is_diag_seen {
			outcome = .Diagnostics
		} else if r.is_progress_end {
			outcome = .Progress
		} else {
			outcome = .Fallback
		}
	}

	r.is_done = true
	r.outcome = outcome
	sync.mutex_unlock(&r.mu)
	return outcome
}
