// dispatch: the middleware chain:
//   exposure -> capability -> (onboarding gate) -> submit to the tool
//   worker pool -> on the worker: request arena -> validate args ->
//   apply (with the retry stage) -> measure -> banner -> respond.
// Immediate rejections (unknown tool, not visible) answer synchronously
// on the calling thread.
package tools

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:safety"
import "src:svc"

RETRY_POLL_MS :: i64(1000) // re-apply cadence while a retryable failure cools down
RETRY_MAX_ATTEMPTS :: 60   // hard bound so a deadline-less call cannot re-apply forever

// The onboarding banner: prefixed onto the session's first answer from a
// project-requiring tool when onboarding has not been performed (the
// reference warns on every such call; the design narrows it to once per
// session). The state is evaluated lazily on the calling thread only.
Banner_State :: struct {
	is_decided: bool, // the session gate was evaluated
	is_owed:    bool, // onboarding is pending and this session still owes the banner
}

// banner_warning renders the onboarding banner (prefixed onto the
// session's first answer from a project-requiring tool when onboarding
// has not been performed); the tool names come from the registry.
banner_warning :: proc(a := context.allocator) -> string {
	return strings.concatenate({
		"WARNING: Project onboarding has not been performed yet. Call `",
		tool_name(.Onboarding_Check),
		"` to verify, then `",
		tool_name(.Onboarding_Run),
		"` if needed.\n\n",
	}, a)
}

Dispatch_Host :: struct {
	user: rawptr,

	// submit hands the task to the host's tool worker pool.
	submit: proc(user: rawptr, task: ^Call_Task),

	// response senders (host bridges to the mcp server).
	send_response: proc(user: rawptr, id: jsonrpc.Id, id_set: bool, is_error: bool, text: string),
	send_error:    proc(user: rawptr, id: jsonrpc.Id, id_set: bool, code: jsonrpc.Err_Code, msg: string),

	// cancel registry so notifications/cancelled can fire the token.
	register:   proc(user: rawptr, id: jsonrpc.Id, token: ^platform.Cancel_Token),
	deregister: proc(user: rawptr, id: jsonrpc.Id, token: ^platform.Cancel_Token),

	// audit is the measurement stage's port: invoked once after the apply
	// completes with the tool name, whether it succeeded, the wall
	// duration, and the response size. nil = no auditing.
	audit: proc(user: rawptr, tool: string, ok: bool, duration_ms: i64, result_bytes: int),

	// mu guards the per-session refresh trio below (available_caps,
	// visible, svc_conn): the host rewrites them under it (wiring's
	// host_call_tool), and every consumer — dispatch_call's gate, the
	// onboarding probe, each pool worker at task start — snapshots them
	// under it. Without the lock a worker's plain read races the refresh
	// (and teardown's nil-ing of svc_conn).
	mu:              sync.Mutex,
	available_caps: bit_set[Cap],
	// visible is the folded tool set (fold_visibility output) that gates
	// tools/call — the single engine, kept in lockstep with the caps by
	// the host refresh. available_caps stays for Tool_Ctx consumers.
	visible:         Visibility,
	root:           ^platform.Cancel_Token,
	clock:          ^platform.Clock, // deadline timer host (nil = no timers)
	tool_timeout_ms: i64,            // 0 = no per-call deadline
	// The retry stage's poll interval between re-applies (the cooldown a
	// retryable failure hints at is tens of seconds; polling stays
	// responsive inside it). Tests set 0 to retry without waiting.
	retry_poll_ms:   i64,

	// The onboarding-banner state; nil = the stage is off (hostless
	// consumers, tests without a parent).
	banner: ^Banner_State,
	session:        ^Session_Info,
	safety:         ^safety.Safety_Checker, // nil = shell_run refuses to run
	project_root:   string,                // containment root for shell_run
	default_max_chars: int,                // 0 = limit_length default off
	svc_conn:       ^jsonrpc.Conn, // parent link for svc-backed tools (nil = absent)
	// Session identity handed to Tool_Ctx (the config overview reports
	// these verbatim; strings live for the host's lifetime).
	context_name: string,
	mode_names:   []string,
	allocator:    mem.Allocator, // task structs and cloned strings
	cancel_alloc: mem.Allocator, // cancel tokens
}

Call_Task :: struct {
	host:      ^Dispatch_Host,
	tid:       Tool_ID,
	id:        jsonrpc.Id, // string variant cloned into the task allocator
	id_set:    bool,
	id_string: string, // backing of the string variant ("" for numeric ids)
	raw_json:  string, // the single marshaled arguments copy (cloned or marshaled here)
	token:     ^platform.Cancel_Token,
	timer:     ^platform.Timer, // deadline timer armed at dispatch (nil = none)
	show_banner: bool,            // prefix the onboarding warning on this answer
}

// task_proc adapts Call_Task to the thread.Pool Task_Proc signature.
task_proc :: proc(task: thread.Task) {
	run_task(cast(^Call_Task)task.data)
	// Frame-loop temp reset for this worker thread: apply and response
	// scratch (result quoting, marshaling helpers) must not accumulate
	// across calls for the session's lifetime.
	free_all(context.temp_allocator)
}

dispatch_call :: proc(
	h: ^Dispatch_Host,
	name: string,
	args: json.Value,
	raw_json: string,
	id: jsonrpc.Id,
	id_set: bool,
) {
	tid, found := find_by_name(name)
	if !found {
		h.send_error(h.user, id, id_set, .Invalid_Params, "unknown tool")
		return
	}

	// exposure: the folded visibility set — the same fold_visibility
	// output tools/list serves — so read_only stripping, optional-tool
	// exclusion, and layer exclusions gate calls and listings alike.
	// {} (the zero set) hides everything: a host that forgets to refresh
	// fails closed.
	sync.mutex_lock(&h.mu)
	visible := h.visible
	svc_conn := h.svc_conn
	caps := h.available_caps
	sync.mutex_unlock(&h.mu)
	if tid not_in visible {
		h.send_error(h.user, id, id_set, .Invalid_Params, "tool is not available in this session")
		return
	}

	// The onboarding banner rides the session's first call to an
	// eligible tool: the gate is evaluated exactly once (here, on the
	// calling thread — serialized, so the state needs no lock) and the
	// warning prefixes that one answer. A parent link that is not up yet
	// defers the decision to the next eligible call instead of deciding
	// "done" on a probe that never ran.
	show_banner := false
	if h.banner != nil && !h.banner.is_decided && banner_eligible(tid) &&
	   svc_conn != nil && (.Memories in caps) {
		h.banner.is_decided = true
		h.banner.is_owed = onboarding_pending(h)
		show_banner = h.banner.is_owed
	}

	deadline := i64(0)
	if h.tool_timeout_ms > 0 {
		deadline = platform.clock_now(h.clock) + h.tool_timeout_ms
	}
	token := platform.token_derive(h.root, deadline, h.cancel_alloc)

	// One marshaled copy serves the whole call: the host's marshaled args
	// (the child marshals exactly once at its entry point) are cloned into
	// the task for both the worker's re-parse and the error-quoting raw;
	// hostless callers that pass only the value marshal here.
	raw_owned := ""
	if raw_json != "" {
		raw_owned = strings.clone(raw_json, h.allocator)
	} else if args != nil {
		raw_owned = jsonutil.marshal_value_unsorted(args, h.allocator)
	}

	task := new(Call_Task, h.allocator)
	task^ = {
		host      = h,
		tid       = tid,
		id        = 0,
		id_set    = id_set,
		raw_json  = raw_owned,
		token     = token,
		show_banner = show_banner,
	}
	// The deadline timer is armed by the deriving caller (here, right
	// after token_derive) — derive itself only records the deadline
	// value; every other derive site passes 0 and needs no timer. The
	// Clock owns it from here and fires .Deadline at expiry; run_task
	// cancels it when the call completes (a task that never runs holds
	// its timer until clock_destroy, which is teardown-only).
	if h.clock != nil && deadline > 0 {
		task.timer = platform.clock_timer_add(h.clock, deadline, deadline_fire_token, token)
	}
	switch v in id {
	case i64:
		task.id = v
	case string:
		task.id_string = strings.clone(v, h.allocator)
		task.id = task.id_string
	}

	h.register(h.user, id, token)
	h.submit(h.user, task)
}

run_task :: proc(task: ^Call_Task) {
	h := task.host
	// Defers fire LIFO: free_task is declared first so it runs last — the
	// deregister, token_destroy, and timer defers below must read the task
	// (id, token, timer) before its strings and struct are released.
	defer free_task(task)
	defer platform.token_destroy(task.token, h.cancel_alloc)
	defer h.deregister(h.user, task.id, task.token)
	// The timer was armed at dispatch; cancel it here on every exit path.
	// When the cancel finds the timer, the clock freed it and the deadline
	// fire never happened. When it does not, a fire pass owns the timer and
	// will call token_fire on this task's token after the clock mutex was
	// already released: token_wait blocks until that fire has signalled,
	// and token_destroy's mutex then serializes with the rest of the fire.
	// Skipping the wait would let the destroy free the token before the
	// fire has even started (freed-token dereference in the fire pass).
	defer if task.timer != nil {
		if !platform.clock_timer_cancel(h.clock, task.timer) {
			platform.token_wait(task.token)
		}
	}

	// Request arena: freed after apply; the response text is copied into
	// plain strings before the arena goes away. destroy, not free_all —
	// free_all retains the arena's tracking allocation (a per-task leak).
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, h.allocator)
	arena_alloc := mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	// Cancellation before work starts: the request is answered with the
	// typed -32800 so the jsonrpc request/response pairing holds. The
	// message distinguishes the token's outcome (deadline, dependency
	// death) — the code stays Request_Cancelled by the pairing rule.
	if e, fired := platform.token_check(task.token); fired {
		msg := "request cancelled before execution"
		#partial switch platform.err_kind(e) {
		case .Timeout:
			msg = "request deadline exceeded before execution"
		case .Terminated:
			msg = "request dependency terminated before execution"
		case:
		}
		h.send_error(h.user, task.id, task.id_set, .Request_Cancelled, msg)
		return
	}

	// Materialize the constant table and take the descriptor by pointer
	// out of it (the compiler rejects variable indexing straight into
	// constant data).
	table := TOOLS
	desc := &table[int(task.tid)]

	args: Args
	args.raw = task.raw_json
	args.values = nil

	args_value: json.Value = nil
	if task.raw_json != "" {
		parsed, perr := json.parse_string(task.raw_json, spec = .JSON, parse_integers = true, allocator = arena_alloc)
		if perr == nil {
			args_value = parsed
		}
	}
	values, err_msg := validate_args(desc, args_value, arena_alloc)
	if err_msg != "" {
		h.send_response(h.user, task.id, task.id_set, true, err_msg)
		return
	}
	args.values = values

	// The refresh trio is snapshot under the host mutex: the fields are
	// rewritten by the session side between calls, and this task's whole
	// lifetime runs against the snapshot it started with.
	sync.mutex_lock(&h.mu)
	task_caps := h.available_caps
	task_svc_conn := h.svc_conn
	task_visible := h.visible
	sync.mutex_unlock(&h.mu)
	caps: Caps = {available = task_caps}
	ctx: Tool_Ctx = {
		call_id     = task.id,
		id_set      = task.id_set,
		allocator   = arena_alloc,
		cancel      = task.token,
		deadline_ms = task.token.deadline,
		caps        = &caps,
		session     = h.session,
		safety          = h.safety,
		project_root    = h.project_root,
		default_max_chars = h.default_max_chars,
		svc_conn        = task_svc_conn,
		context_name    = h.context_name,
		mode_names      = h.mode_names,
		visible         = task_visible,
	}

	// Apply runs on the request arena: result builders allocate through
	// ctx.allocator (result_init), so their allocations die with the arena.
	started_ms := platform.mono_ms()
	result := desc.apply(&ctx, &args)

	// The retry stage: a retryable failure of a read-only tool is
	// re-applied until the call deadline. The wait runs through the
	// injected clock (virtual clocks advance instead of sleeping), each
	// attempt runs under a child token — a cancellation fired at the
	// parent reaches the in-flight attempt, and the child inherits the
	// deadline without ever widening it — and editing tools never retry
	// (their effects are not idempotent). Non-retryable kinds answer
	// as-is; .Terminated in particular recovers on the *next* call.
	if h.clock != nil && !desc.can_edit {
		attempts := 0
		for result.is_error && result.err_kind == .Retryable && attempts < RETRY_MAX_ATTEMPTS {
			if _, fired := platform.token_check(task.token); fired {
				break
			}
			if task.token.deadline > 0 && platform.clock_now(h.clock) + h.retry_poll_ms >= task.token.deadline {
				break // the next attempt could not complete inside the deadline
			}
			platform.clock_wait(h.clock, h.retry_poll_ms)
			if _, fired := platform.token_check(task.token); fired {
				break
			}
			attempts += 1
			child := platform.token_derive(task.token, task.token.deadline, h.cancel_alloc)
			ctx.cancel = child
			result = desc.apply(&ctx, &args)
			platform.token_destroy(child, h.cancel_alloc)
			ctx.cancel = task.token
		}
	}

	text := result_text(result, arena_alloc)
	// The banner prefixes the one answer it was attached to (error
	// answers stay clean — the failure is the message).
	if task.show_banner && !result.is_error {
		text = strings.concatenate({banner_warning(arena_alloc), text}, arena_alloc)
	}

	if h.audit != nil {
		h.audit(h.user, desc.name, !result.is_error, platform.mono_ms() - started_ms, len(text))
	}

	h.send_response(h.user, task.id, task.id_set, result.is_error, text)
}

// banner_eligible names the calls that can carry the onboarding banner:
// tools that operate on project state, minus the onboarding family itself
// (its answers already explain the state — prefixing them would bury the
// actual result).
banner_eligible :: proc(tid: Tool_ID) -> bool {
	table := TOOLS
	desc := &table[int(tid)]
	return .Project in desc.needs && desc.category != .Onboarding
}

// onboarding_pending evaluates the session gate through the same
// predicate onboarding_check uses (project-scoped memories exist). The
// caller guarantees the parent link and memory capability; a failed probe
// counts as done — the banner never substitutes for the tool.
onboarding_pending :: proc(h: ^Dispatch_Host) -> bool {
	// Probe scratch: the whole round trip lives and dies on this arena.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, h.allocator)
	a := mem.dynamic_arena_allocator(&scratch)
	deadline := i64(0)
	if h.tool_timeout_ms > 0 {
		// Real-time mint by design: this deadline is consumed by slot_wait,
		// which counts down on the process monotonic clock — minting it
		// from the injected (possibly virtual) clock would diverge under
		// tests.
		deadline = platform.mono_ms() + h.tool_timeout_ms
	}
	sync.mutex_lock(&h.mu)
	svc_conn := h.svc_conn
	sync.mutex_unlock(&h.mu)
	call := svc.client_memory_list(svc_conn, "", a, deadline, nil)
	pending := false
	if call.call_err == .None {
		pending = memory_project_count(call.result) == 0
	}
	mem.dynamic_arena_destroy(&scratch)
	return pending
}

// deadline_fire_token is the Clock timer body for per-call deadlines.
deadline_fire_token :: proc(data: rawptr) {
	platform.token_fire(cast(^platform.Cancel_Token)data, .Deadline)
}

result_text :: proc(result: Tool_Result, a: mem.Allocator) -> string {
	parts := make([dynamic]string, 0, a)
	for c in result.contents {
		if c.kind == .Text && c.text != "" {
			append(&parts, c.text)
		}
	}
	out := strings.join(parts[:], "\n", a)
	delete(parts)
	return out
}

free_task :: proc(task: ^Call_Task) {
	h := task.host
	if task.id_string != "" {
		delete(task.id_string, h.allocator)
	}
	if task.raw_json != "" {
		delete(task.raw_json, h.allocator)
	}
	free(task, h.allocator)
}

// abandon_task releases a queued-but-never-run task. run_task's defers
// never fired for it, so the registration, the armed timer, and the
// derived token are released here, in run_task's order (deregister and
// timer/token release read the task's fields; free_task goes last).
abandon_task :: proc(task: ^Call_Task) {
	h := task.host
	h.deregister(h.user, task.id, task.token)
	if task.timer != nil {
		if !platform.clock_timer_cancel(h.clock, task.timer) {
			platform.token_wait(task.token)
		}
	}
	platform.token_destroy(task.token, h.cancel_alloc)
	free_task(task)
}
