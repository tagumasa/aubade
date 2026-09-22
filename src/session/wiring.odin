// Host wiring: the bridge between the mcp server callbacks, the tools
// dispatch chain, and the App state (visibility announcements, cancel
// registry, worker pool).
package session

import "core:fmt"
import "core:mem"
import "core:sync"
import "core:thread"
import "src:jsonrpc"
import "src:jsonutil"
import "src:mcp"
import "src:platform"
import "src:tools"
import "src:util"

setup_dispatch :: proc(a: ^App) {
	a.dispatch = {
		user            = a,
		submit          = host_submit,
		send_response   = host_send_response,
		send_error      = host_send_error,
		register        = host_register,
		deregister      = host_deregister,
		audit           = host_audit,
		root            = a.root,
		clock           = a.clock,
		tool_timeout_ms = a.cfg.tool_timeout_ms,
		retry_poll_ms   = tools.RETRY_POLL_MS,
		session         = &a.session_info,
		allocator       = a.allocator,
		cancel_alloc    = a.cancel_alloc,
		safety          = a.safety,
		project_root    = a.cfg.project_root,
		default_max_chars = a.default_max_chars,
		context_name    = a.active_context,
		mode_names      = a.cfg.modes,
		banner          = &a.banner,
	}
}

// host_audit is the measurement stage of the dispatch chain: one info
// line per completed call, a warning past ten seconds, and a warning
// for responses past 64 KiB (the message strings live on the thread's
// temp scratch).
host_audit :: proc(user: rawptr, tool: string, ok: bool, duration_ms: i64, result_bytes: int) {
	_ = user
	if util.log_enabled(.Info) {
		util.log_info(fmt.aprintf("tool application completed tool=%s ok=%v result_length=%d elapsed_ms=%d",
			tool, ok, result_bytes, duration_ms, allocator = context.temp_allocator))
	}
	if duration_ms > 10_000 {
		util.log_warning(fmt.aprintf("slow tool execution tool=%s elapsed_ms=%d",
			tool, duration_ms, allocator = context.temp_allocator))
	}
	if result_bytes > 64 * 1024 {
		util.log_warning(fmt.aprintf("large tool response tool=%s result_length=%d",
			tool, result_bytes, allocator = context.temp_allocator))
	}
}

// fold_visible is the one place this host folds visibility: the config
// stack's inclusion layers over the capability base (nil layers = no
// stack loaded; the read-only strip runs inside the fold). Warnings are
// surfaced once at startup instead of per fold.
fold_visible :: proc(a: ^App, caps: bit_set[tools.Cap], read_only: bool) -> tools.Visibility {
	return tools.fold_visibility(caps, read_only, a.layers, nil)
}

// ---------------------------------------------------------------------------
// mcp callbacks
// ---------------------------------------------------------------------------

host_list_tools :: proc(host: rawptr, arena: mem.Allocator) -> []mcp.Tool_Entry {
	a := cast(^App)host
	sync.mutex_lock(&a.parent_mu)
	caps := a.available_caps
	read_only := a.read_only
	sync.mutex_unlock(&a.parent_mu)

	entries := make([dynamic]mcp.Tool_Entry, arena)
	vis := fold_visible(a, caps, read_only)
	// Materialize the constant table and walk it by index (the compiler
	// rejects variable indexing straight into constant data); the schema
	// projection takes &table[i].
	table := tools.TOOLS
	for i in 0..<len(table) {
		if cast(tools.Tool_ID)i not_in vis {
			continue
		}
		entry := mcp.Tool_Entry{
			name             = table[i].name,
			title            = table[i].title,
			description      = table[i].description,
			input_schema     = tools.schema_for_tool(&table[i], arena),
			read_only_hint   = !table[i].can_edit,
			destructive_hint = table[i].destructive, // can_edit AND destructive category
		}
		append(&entries, entry)
	}
	return entries[:]
}

host_call_tool :: proc(host: rawptr, call: ^mcp.Call_Info) -> mcp.Call_Outcome {
	a := cast(^App)host
	// The dispatch trio is written under the host's own mutex: pool
	// workers read it per task on the other side (Dispatch_Host.mu). The
	// write sits INSIDE the parent_mu section that read a.parent so the
	// publication serializes with parent-link teardown (which swaps the
	// link out under parent_mu, then withdraws dispatch.svc_conn under
	// dispatch.mu before destroying the conn): a copy captured from a
	// retiring link can never be published after the withdrawal. Lock
	// order parent_mu -> dispatch.mu, never reversed.
	sync.mutex_lock(&a.parent_mu)
	caps := a.available_caps
	// The folded set is maintained by announce_visibility (initialized at
	// session start, re-folded on every capability change) — copying it is
	// equivalent to re-folding without repeating that work per call.
	visible := a.visible
	parent := a.parent
	sync.mutex_lock(&a.dispatch.mu)
	a.dispatch.available_caps = caps
	a.dispatch.visible = visible
	a.dispatch.svc_conn = parent
	sync.mutex_unlock(&a.dispatch.mu)
	sync.mutex_unlock(&a.parent_mu)

	raw := ""
	if call.args != nil {
		raw = jsonutil.marshal_value_unsorted(call.args, context.temp_allocator)
	}
	tools.dispatch_call(&a.dispatch, call.name, call.args, raw, call.id, call.id_set)
	// Every response flows through the dispatch host callbacks (worker
	// pool or immediate error); mcp itself never sends for this server.
	return {deferred = true}
}

// Call_Entry owns its key clone so deregister can free the heap string
// (the lookup key on the deregister path is a stack buffer), and carries
// one token slot per registration: a protocol-violating peer can run two
// concurrent tools/call under one id, and each task's deregister must
// retire only its own registration or the teardown drain unblocks while
// the other task still runs.
Call_Entry :: struct {
	key:    string, // owned clone (a.allocator)
	tokens: [dynamic]^platform.Cancel_Token,
}

host_on_cancel :: proc(host: rawptr, id: jsonrpc.Id) {
	a := cast(^App)host
	lookup := id_key_alloc(id, context.temp_allocator)
	// The fire happens under the registry mutex and the entry is left in
	// place, mirroring the daemon's cancel_call: the task's deregister
	// (host_deregister) removes and frees it under the same mutex, and the
	// token_destroy defer runs strictly after — so a fire either completes
	// before that destroy or finds nothing. Removing the entry here and
	// firing after the unlock raced the worker's unconditional destroy.
	sync.mutex_lock(&a.calls_mu)
	if entry, found := a.calls[lookup]; found && entry != nil {
		for t in entry.tokens {
			if t != nil {
				platform.token_fire(t, .Cancelled)
			}
		}
	}
	sync.mutex_unlock(&a.calls_mu)
	delete(lookup, context.temp_allocator)
}

// announce_visibility re-folds visibility after capability changes and
// sends tools/list_changed when the set changed (XOR-nonzero case; for a
// boolean decision that is exactly set inequality).
announce_visibility :: proc(a: ^App) {
	sync.mutex_lock(&a.parent_mu)
	caps := a.available_caps
	read_only := a.read_only
	sync.mutex_unlock(&a.parent_mu)

	current := fold_visible(a, caps, read_only)
	sync.mutex_lock(&a.parent_mu)
	changed := current != a.visible
	a.visible = current
	sync.mutex_unlock(&a.parent_mu)

	// Spec discipline: never notify before the client initialized.
	if changed && a.server != nil && mcp.server_is_initialized(a.server) {
		mcp.send_list_changed(a.server)
	}
}

// ---------------------------------------------------------------------------
// dispatch host callbacks
// ---------------------------------------------------------------------------

host_submit :: proc(user: rawptr, task: ^tools.Call_Task) {
	a := cast(^App)user
	thread.pool_add_task(&a.pool, a.allocator, tools.task_proc, task)
}

// The deferred reply hosts serialize on this thread's temp scratch: the
// body is transient (the outbound queue clones it, the synchronous writer
// consumes it before the send returns), and task_proc / the reader frame
// loop reset temp right after the callback — nothing downstream would ever
// free a body parked on the session allocator.
host_send_response :: proc(user: rawptr, id: jsonrpc.Id, id_set: bool, is_error: bool, text: string) {
	a := cast(^App)user
	mcp.send_tool_response(a.server, id, id_set, is_error, text, context.temp_allocator)
}

host_send_error :: proc(user: rawptr, id: jsonrpc.Id, id_set: bool, code: jsonrpc.Err_Code, msg: string) {
	a := cast(^App)user
	mcp.send_tool_error(a.server, id, id_set, code, msg, context.temp_allocator)
}

host_register :: proc(user: rawptr, id: jsonrpc.Id, token: ^platform.Cancel_Token) {
	a := cast(^App)user
	sync.mutex_lock(&a.calls_mu)
	if a.calls == nil {
		a.calls = make(map[string]^Call_Entry, 8, a.allocator)
	}
	key := id_key_alloc(id, a.allocator)
	if entry, found := a.calls[key]; found && entry != nil {
		// Duplicate id: the second task rides the existing entry as one
		// more token slot — freeing the predecessor here (the old
		// overwrite) handed the first task's deregister a victim it did
		// not own.
		append(&entry.tokens, token)
		delete(key, a.allocator)
		sync.cond_broadcast(&a.calls_cond)
		sync.mutex_unlock(&a.calls_mu)
		return
	}
	entry := new(Call_Entry, a.allocator)
	entry^ = {
		key    = key,
		tokens = make([dynamic]^platform.Cancel_Token, 0, 1, a.allocator),
	}
	append(&entry.tokens, token)
	a.calls[key] = entry
	sync.cond_broadcast(&a.calls_cond)
	sync.mutex_unlock(&a.calls_mu)
}

host_deregister :: proc(user: rawptr, id: jsonrpc.Id, token: ^platform.Cancel_Token) {
	a := cast(^App)user
	lookup := id_key_alloc(id, context.temp_allocator)
	sync.mutex_lock(&a.calls_mu)
	if entry, found := a.calls[lookup]; found && entry != nil {
		for t, i in entry.tokens {
			if t == token {
				// Swap-remove this task's slot only: a sibling
				// registration under the same id keeps the entry alive.
				entry.tokens[i] = entry.tokens[len(entry.tokens) - 1]
				pop(&entry.tokens)
				break
			}
		}
		if len(entry.tokens) == 0 {
			delete_key(&a.calls, lookup)
			delete(entry.tokens)
			delete(entry.key, a.allocator)
			free(entry, a.allocator)
		}
	}
	// retire_link's drain waits for the registry to empty; a task that
	// just finished is the usual reason it can proceed now.
	sync.cond_broadcast(&a.calls_cond)
	sync.mutex_unlock(&a.calls_mu)
	delete(lookup, context.temp_allocator)
}
