// Tests for the session host's config wiring (audit C.1.2/C.1.3): the
// stack-to-layers projection through the real fold — a custom context's
// exclusions land and unknown names warn-and-skip — the shell-guard
// feeding from the merged config lists, and the dispatch fields the
// wiring now sets (safety, project root, answer-size default).
package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

import "src:config"
import "src:jsonrpc"
import "src:mcp"
import "src:platform"
import "src:safety"
import "src:session"
import "src:tools"

write_home_file :: proc(t: ^testing.T, home: string, name: string, content: string) {
	path, _ := filepath.join([]string{home, name}, context.temp_allocator)
	os.make_directory_all(filepath.dir(path))
	fp, err := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil {
		testing.fail_now(t, "home file open failed")
	}
	os.write(fp, transmute([]u8)content)
	os.close(fp)
}

@(test)
session_layers_apply_context_exclusions :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-sesswire-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	// A custom context excluding one real tool and one nonexistent
	// name: the fold must drop the former and warn-and-skip the latter.
	write_home_file(t, tmp, "contexts/custom.jsonc",
		`{"excluded_tools": ["file_read", "memory_write"]}`)

	sel := config.Stack_Selection{context_name = "custom"}
	stack, serr := config.stack_build(sel, tmp, context.allocator)
	testing.expectf(t, serr == nil, "stack_build: %s", platform.err_message(serr, context.temp_allocator))
	if serr != nil {
		return
	}
	defer config.stack_destroy(stack)

	layers := session.visibility_layers(stack, context.allocator)
	defer delete(layers, context.allocator)
	testing.expect_value(t, len(layers), 3 + len(stack.modes)) // global + context + modes + project

	warnings: [dynamic]string
	warnings = make([dynamic]string, 0, 8, context.allocator)
	// The fold's notice strings are caller-owned (same contract as the
	// session startup pass) — each one must be freed with the list.
	defer {
		for w in warnings {
			delete(w)
		}
		delete(warnings)
	}
	vis := tools.fold_visibility({.Project, .Svc, .Editor}, false, layers, &warnings)

	_, fw_ok := tools.find_by_name("file_write")
	testing.expect_value(t, fw_ok, true)
	testing.expect(t, .File_Write in vis, "file_write must stay visible")
	testing.expect(t, .File_Read not_in vis, "context exclusion must remove file_read")

	warned := false
	for w in warnings {
		if strings_contains(w, "memory_write") {
			warned = true
		}
	}
	testing.expect(t, warned, "unknown tool name must warn-and-skip")
}

@(test)
session_feed_shell_config :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-sesswire-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	write_home_file(t, tmp, "config.jsonc",
		`{"blocked_shell_commands": ["^forbidden.*"], "allowed_shell_commands": ["^safe.*"]}`)

	stack, serr := config.stack_build({}, tmp, context.allocator)
	testing.expectf(t, serr == nil, "stack_build: %s", platform.err_message(serr, context.temp_allocator))
	if serr != nil {
		return
	}
	defer config.stack_destroy(stack)

	sc: safety.Safety_Checker
	safety.safety_checker_init(&sc, context.allocator)
	defer safety.safety_checker_destroy(&sc)
	session.feed_shell_config(&sc, stack)

	blocked, _ := safety.shellguard_is_blocked(&sc.shell_guard, "forbidden-tool --flag")
	testing.expect_value(t, blocked, true)
	allowed := safety.shellguard_executable_allowed(&sc.shell_guard, "safe-runner")
	testing.expect_value(t, allowed, true)
	allowed = safety.shellguard_executable_allowed(&sc.shell_guard, "anything-else")
	testing.expect_value(t, allowed, false)
}

@(test)
session_dispatch_carries_safety_and_limits :: proc(t: ^testing.T) {
	sc: safety.Safety_Checker
	safety.safety_checker_init(&sc, context.allocator)
	defer safety.safety_checker_destroy(&sc)

	a: session.App
	a.allocator = context.allocator
	a.cancel_alloc = context.allocator
	a.cfg.project_root = "/proj"
	a.default_max_chars = 1234
	a.safety = &sc

	session.setup_dispatch(&a)
	testing.expect(t, a.dispatch.safety == &sc, "dispatch must carry the safety checker")
	testing.expect_value(t, a.dispatch.project_root, "/proj")
	testing.expect_value(t, a.dispatch.default_max_chars, 1234)

	// No stack loaded: the fold runs layer-less (same as visibility_set),
	// and read-only still strips the editing tools. Symbol tools need the
	// parent's project capability on top of .Svc.
	a.read_only = true
	vis := session.fold_visible(&a, {.Project, .Svc}, true)
	testing.expect(t, .File_Write not_in vis, "read-only must strip editors")
	testing.expect(t, .Symbol_List in vis, "read-only keeps readers")
}

@(test)
session_cancel_leaves_registry_entry_to_the_worker :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ta := mem.dynamic_arena_allocator(&arena)

	a: session.App
	a.allocator = context.allocator
	a.cancel_alloc = context.allocator

	root := new(platform.Cancel_Token, ta)
	platform.token_init_root(root)
	token := platform.token_derive(root, 0, ta)

	id := jsonrpc.Id(i64(41))
	session.host_register(&a, id, token)
	testing.expect_value(t, len(a.calls), 1)

	// Cancel fires under the registry mutex and leaves the entry in
	// place: the worker's deregister owns removal, so its unconditional
	// token_destroy cannot race the fire (the daemon cancel_call
	// invariant, mirrored — firing after removing the entry here is what
	// the fix removes).
	session.host_on_cancel(&a, id)
	testing.expect(t, platform.token_is_fired(token), "cancel fires the token")
	testing.expect_value(t, len(a.calls), 1)

	// The worker path then removes and frees the entry — the tracking
	// allocator proves the key clone and the entry are released exactly
	// once, on this path alone.
	session.host_deregister(&a, id, token)
	testing.expect_value(t, len(a.calls), 0)

	// A late cancel for the finished call finds nothing and is a no-op.
	session.host_on_cancel(&a, id)
	testing.expect_value(t, len(a.calls), 0)

	delete(a.calls)
}

strings_contains :: proc(hay, needle: string) -> bool {
	for i := 0; i + len(needle) <= len(hay); i += 1 {
		match := true
		for j := 0; j < len(needle); j += 1 {
			if hay[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

@(test)
session_default_instructions_carry_manual :: proc(t: ^testing.T) {
	cfg := session.default_config()
	testing.expect(t, strings_contains(cfg.instructions, tools.ONBOARDING_DIRECTIVE),
		"instructions must open with the onboarding directive")
	testing.expect(t, strings_contains(cfg.instructions, tools.STANDALONE_INSTRUCTIONS_MANUAL),
		"instructions must carry the standalone manual")
	testing.expect(t, strings_contains(cfg.instructions, "onboarding_check"),
		"the directive must point at the onboarding check tool")
	// The directive is a constant (the app config folds it into its
	// fallback instructions), so its tool names cannot compose from the
	// registry at runtime — pin them instead: a renamed tool fails here
	// rather than shipping prose that names a tool that no longer exists.
	testing.expect(t, strings_contains(tools.ONBOARDING_DIRECTIVE, tools.tool_name(.Onboarding_Check)),
		"the directive must name the registered onboarding_check tool")
	testing.expect(t, strings_contains(tools.ONBOARDING_DIRECTIVE, tools.tool_name(.Onboarding_Run)),
		"the directive must name the registered onboarding_run tool")
	testing.expect(t, strings_contains(tools.ONBOARDING_DIRECTIVE, tools.tool_name(.Onboarding_Read_Instructions)),
		"the directive must name the registered onboarding_read_instructions tool")
}

@(test)
session_single_project_hides_config_get :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-sesssp-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	// A single-project context: the project-management surface (the
	// config overview) hides between the mode and project folds.
	write_home_file(t, tmp, "contexts/single.jsonc",
		`{"single_project": true}`)

	sel := config.Stack_Selection{context_name = "single"}
	stack, serr := config.stack_build(sel, tmp, context.allocator)
	testing.expectf(t, serr == nil, "stack_build: %s", platform.err_message(serr, context.temp_allocator))
	if serr != nil {
		return
	}
	defer config.stack_destroy(stack)

	layers := session.visibility_layers(stack, context.allocator)
	defer delete(layers, context.allocator)
	// global + context + the default modes + 1 single-project strip + project
	testing.expect_value(t, len(layers), 4 + len(stack.modes))

	caps: bit_set[tools.Cap] = {.Project, .Svc, .Editor, .Memories, .Tracker, .Shell}
	vis := tools.fold_visibility(caps, false, layers, nil)
	testing.expect(t, .Config_Get not_in vis, "single_project must hide config_get")
	testing.expect(t, .File_Write in vis, "file tools stay visible")

	// Without the flag the overview is an ordinary project tool.
	write_home_file(t, tmp, "contexts/multi.jsonc", `{}`)
	sel2 := config.Stack_Selection{context_name = "multi"}
	stack2, serr2 := config.stack_build(sel2, tmp, context.allocator)
	testing.expectf(t, serr2 == nil, "stack_build: %s", platform.err_message(serr2, context.temp_allocator))
	if serr2 != nil {
		return
	}
	defer config.stack_destroy(stack2)
	layers2 := session.visibility_layers(stack2, context.allocator)
	defer delete(layers2, context.allocator)
	testing.expect_value(t, len(layers2), 3 + len(stack2.modes))
	vis2 := tools.fold_visibility(caps, false, layers2, nil)
	testing.expect(t, .Config_Get in vis2, "config_get stays visible without single_project")
}

// The project's initial_prompt must actually reach the served
// instructions — the config key is documented as "given to the model on
// every project activation", and this is the wiring that keeps that true.
@(test)
session_initial_prompt_appends_project_section :: proc(t: ^testing.T) {
	proj := config.Project_Config{initial_prompt = "  Always run the red suite first.  "}
	stack: config.Config_Stack = {project = &proj}
	section := session.initial_prompt_section(&stack, context.temp_allocator)
	testing.expect(t, strings.contains(section, "# Project initial prompt"), section)
	testing.expect(t, strings.contains(section, "Always run the red suite first."), section)
	testing.expect(t, !strings.contains(section, "  Always"), section) // surrounding whitespace trimmed

	blank := config.Project_Config{initial_prompt = " \t "}
	blank_stack: config.Config_Stack = {project = &blank}
	testing.expect_value(t, session.initial_prompt_section(&blank_stack, context.temp_allocator), "")
	testing.expect_value(t, session.initial_prompt_section(nil, context.temp_allocator), "")
}

// A duplicate tools/call id must not leak the registry entry it replaces:
// the tracking allocator's zero-leak discipline is the oracle —
// the old overwrite left the previous Call_Entry and its owned key clone
// stranded.
@(test)
host_register_replaces_duplicate_call_id :: proc(t: ^testing.T) {
	a := new(session.App, context.allocator)
	defer free(a, context.allocator)
	a^ = {allocator = context.allocator}

	token: platform.Cancel_Token
	platform.token_init_root(&token)

	session.host_register(a, 7, &token)
	session.host_register(a, 7, &token) // duplicate id rides the entry as a second slot
	testing.expect_value(t, len(a.calls), 1)

	// The first task's deregister must retire only ITS registration: the
	// entry (and the teardown drain's block) survives until the sibling
	// deregisters too — the pre-fix overwrite let the first deregister
	// free the successor's entry and unblock the drain early.
	session.host_deregister(a, 7, &token)
	testing.expect_value(t, len(a.calls), 1)
	session.host_deregister(a, 7, &token)
	testing.expect_value(t, len(a.calls), 0)
	delete(a.calls) // the map itself (made on a.allocator by the first register)
}

// The retire-link drain: wait_calls_drained must block until
// EVERY registered call has deregistered, and abort_inflight_calls must
// fire exactly the registered tokens so their workers reach the
// deregister. The registry is the bracket around a tool task's whole
// lifetime, so an empty registry is the proof no worker still holds the
// parent conn being destroyed.
Drain_Worker :: struct {
	a:    ^session.App,
	id:   jsonrpc.Id,
	token: ^platform.Cancel_Token,
}

drain_worker_main :: proc(data: rawptr) {
	w := cast(^Drain_Worker)data
	// Stand-in for a pool worker inside conn_call: parked until the abort
	// fires the token, then "finishes" and deregisters.
	platform.token_wait(w.token)
	session.host_deregister(w.a, w.id, w.token)
}

Drain_Flag :: struct {
	app:  ^session.App,
	mu:   sync.Mutex,
	cond: sync.Cond,
	done: bool,
}

drain_waiter_main :: proc(data: rawptr) {
	f := cast(^Drain_Flag)data
	session.wait_calls_drained(f.app)
	sync.mutex_lock(&f.mu)
	f.done = true
	sync.cond_broadcast(&f.cond)
	sync.mutex_unlock(&f.mu)
}

@(test)
retire_drain_waits_for_every_deregister :: proc(t: ^testing.T) {
	a := new(session.App, context.allocator)
	defer free(a, context.allocator)
	a^ = {allocator = context.allocator}

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	workers: [2]Drain_Worker
	handles: [2]^thread.Thread
	for i in 0..<2 {
		token := platform.token_derive(root, 0, context.allocator)
		id: jsonrpc.Id = i64(i + 1)
		session.host_register(a, id, token)
		workers[i] = {a = a, id = id, token = token}
		handles[i] = thread.create_and_start_with_data(
			&workers[i], drain_worker_main, self_cleanup = false, name = "drain-worker",
		)
	}
	// The tokens are the workers' to consume; the registry does not own
	// them, so this test destroys them after the joins.
	defer for i in 0..<2 { platform.token_destroy(workers[i].token, context.allocator) }

	f := new(Drain_Flag, context.allocator)
	defer free(f, context.allocator)
	f^ = {app = a}
	waiter := thread.create_and_start_with_data(f, drain_waiter_main, self_cleanup = false, name = "drain-waiter")

	// Fire only the FIRST call's token, then wait for ITS deregistration
	// through the registry itself (bounded): once it lands, the drain is
	// provably still blocked by the second registration — no timed guess.
	platform.token_fire(workers[0].token, .Cancelled)
	key1 := session.id_key_alloc(workers[0].id, context.temp_allocator)
	defer delete(key1, context.temp_allocator)
	sync.mutex_lock(&a.calls_mu)
	first_done := false
	wait_deadline := platform.mono_ms() + 5000
	for !first_done && platform.mono_ms() < wait_deadline {
		if entry, found := a.calls[key1]; found && entry != nil && len(entry.tokens) == 1 {
			first_done = true
			break
		}
		sync.cond_wait_with_timeout(&a.calls_cond, &a.calls_mu, 20 * 1_000_000)
	}
	sync.mutex_unlock(&a.calls_mu)
	testing.expect(t, first_done, "fired worker never deregistered")

	sync.mutex_lock(&f.mu)
	still_blocked := !f.done
	sync.mutex_unlock(&f.mu)
	testing.expect(t, still_blocked, "drain must wait for the second registration")

	// The abort fires everything registered (here: the remaining one) and
	// the drain completes once its worker deregisters.
	session.abort_inflight_calls(a)
	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&f.mu)
	for !f.done && platform.mono_ms() < deadline {
		sync.cond_wait_with_timeout(&f.cond, &f.mu, 20 * 1_000_000)
	}
	drained := f.done
	sync.mutex_unlock(&f.mu)
	testing.expect(t, drained, "drain completed after the last deregister")

	thread.join(waiter)
	free(waiter, context.allocator)
	for h in handles {
		thread.join(h)
		free(h, context.allocator)
	}
	testing.expect_value(t, len(a.calls), 0)
	delete(a.calls)
}

// The deferred-reply hosts must serialize on this thread's temp scratch,
// never the session allocator: the send path consumes the body
// (the outbound queue clones it, the synchronous writer writes it) and
// nothing downstream frees the original, so a body parked on a.allocator
// would collect one allocation per reply for the session's lifetime. The
// tracking allocator is the oracle — the temp wiring leaves nothing
// outstanding after the sends, while a regression to a.allocator strands
// every body as a leak WARN.
@(test)
host_send_replies_serialize_on_temp_scratch :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)
	defer delete(p.buf)

	conn := new(jsonrpc.Conn, context.allocator)
	defer free(conn, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(conn, r, w, context.allocator)

	server := new(mcp.Server, context.allocator)
	defer free(server, context.allocator)
	server^ = {conn = conn}

	a := new(session.App, context.allocator)
	defer free(a, context.allocator)
	a^ = {
		allocator = context.allocator,
		server    = server,
	}

	// Enough sends for a per-reply leak to be unmissable in the suite log.
	for _ in 0..<8 {
		session.host_send_response(a, 1, true, false, "deferred tool answer payload")
		session.host_send_error(a, 2, true, .Request_Cancelled, "cancelled mid-flight")
	}
}

// compose_instructions must leave exactly one session-owned allocation:
// the whole render cluster — visible tool names, context/mode
// prompt renders, the memories/tracker sections, and the rendered prompt
// itself — runs on a local arena destroyed inside the call, and every
// path (the static-manual fallback included) hands back one
// a.allocator-owned clone the shutdown path can free unconditionally.
// The tracking allocator is the oracle: the old shape parked the entire
// cluster on the session allocator and freed none of it.
@(test)
compose_instructions_returns_one_owned_string :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-sessinstr-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	a := new(session.App, context.allocator)
	defer free(a, context.allocator)
	// The builtin template gates a file_search section on the visible set,
	// so the section's body proves the tool list actually rode along.
	a^ = {
		cfg       = session.default_config(),
		allocator = context.allocator,
		home      = tmp,
		visible   = {.File_Search},
	}

	instructions := session.compose_instructions(a)
	testing.expectf(t, len(instructions) > 0, "instructions must render (builtin template)")
	testing.expect(t, strings_contains(instructions, "are the fallbacks"), "the visible tool list rides along")

	// The shutdown ownership step, verbatim: one delete, no path
	// knowledge — a borrowed fallback spelling would bad-free here.
	delete(instructions, a.allocator)
}
