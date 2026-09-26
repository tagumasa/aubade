// aubade daemon status|stop: the daemon control plane. status reads the
// project's endpoint.json and asks the daemon through svc.status; stop
// authenticates with the root token and fires the daemon's shutdown token
// (refused while other child sessions are still connected).
package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "src:daemon"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:rpc"
import "src:safety"
import "src:svc"
import "src:util"

// The control verbs, one declaration: the switch dispatches and the
// refusals spell the alternatives from the table.
DAEMON_CTL_VERBS :: []string{"status", "stop"}

// The two refusal paths answer with the same line — one declaration.
daemon_ctl_usage :: proc(a := context.allocator) -> string {
	return strings.concatenate(
		{"usage: aubade daemon ", util.quoted_join(DAEMON_CTL_VERBS, " | aubade daemon ", "", a)},
		a,
	)
}

run_daemon_ctl :: proc(args: []string, g: ^Globals, version: string) -> int {
	if len(args) == 0 {
		return usage_error("daemon", daemon_ctl_usage(context.temp_allocator))
	}
	// Globals may appear anywhere (strip_globals' contract), including
	// between `daemon` and the verb — strip from the full arg list first
	// and read the verb from the remainder.
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)
	if !strip_globals(args, g, &rest) {
		return usage_error("daemon", "invalid global flag value")
	}
	if len(rest) == 0 {
		return usage_error("daemon", daemon_ctl_usage(context.temp_allocator))
	}
	verb := rest[0]
	if len(rest) > 1 {
		return usage_error("daemon", fmt.aprintf("unexpected argument %q", rest[1], allocator = context.temp_allocator))
	}

	switch verb {
	case "status":
		return daemon_status(g)
	case "stop":
		return daemon_stop(g)
	case:
		return usage_error(
			"daemon",
			fmt.aprintf(
				"unknown verb %q (%s)",
				verb,
				util.quoted_join(DAEMON_CTL_VERBS, ", ", "", context.temp_allocator),
				allocator = context.temp_allocator,
			),
		)
	}
}

// resolve_control_target maps the global project flags to the daemon's
// endpoint.json path. The second return is an exit code.
resolve_control_target :: proc(cmd: string, g: ^Globals) -> (endpoint_path: string, id: string, code: int) {
	root, rcode := resolve_project_root(cmd, g)
	if rcode != 0 {
		return "", "", rcode
	}
	// Canonical spelling, matching daemon_init: the daemon dir id hashes
	// the resolved root, so control commands must derive it from the
	// same spelling (macOS /var vs /private/var temp roots).
	root = safety.pathguard_resolve_root(root, context.temp_allocator)
	home := platform.aubade_home(context.temp_allocator)
	project := platform.project_id(root, context.temp_allocator)
	dir := platform.daemon_dir(home, project, context.temp_allocator)
	path := platform.daemon_endpoint_path(dir, context.temp_allocator)
	return path, project, 0
}

Control_Box :: struct {
	conn: ^jsonrpc.Conn,
}

control_reader_entry :: proc(data: rawptr) {
	b := cast(^Control_Box)data
	jsonrpc.conn_read_loop(b.conn)
}

Control_Link :: struct {
	conn:   ^jsonrpc.Conn,
	stream: ^rpc.Stream,
	box:    ^Control_Box,
	reader: ^thread.Thread,
	token:  string, // borrowed from the caller's Endpoint_Info
}

// connect_control dials the daemon and completes the token-checked hello.
connect_control :: proc(info: daemon.Endpoint_Info) -> (^Control_Link, bool) {
	stream, ok := rpc.tcp_dial(info.port)
	if !ok {
		return nil, false
	}
	c := new(jsonrpc.Conn, context.allocator)
	reader := rpc.to_reader(stream, jsonrpc.RPC_MAX_FRAME)
	writer := rpc.to_writer(stream)
	jsonrpc.conn_init(c, reader, writer, context.allocator)

	box := new(Control_Box, context.allocator)
	box^ = {conn = c}
	rthr := thread.create_and_start_with_data(box, control_reader_entry, self_cleanup = false)

	params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&params, "client_pid", jsonutil.json_int(i64(daemon.own_pid())))
	jsonutil.obj_set(&params, "token", jsonutil.json_string(info.token))
	_, code, msg, cerr := jsonrpc.conn_call(
		c, svc.METHOD_HELLO, json.Value(json.Object(params)), context.temp_allocator,
		platform.mono_ms() + svc.CONTROL_CALL_DEADLINE_MS,
	)
	if cerr != .None {
		fmt.eprintf(
			"aubade: control svc.hello failed: %v code=%d msg=%q\n",
			cerr, i32(code), msg,
		)
		close_control_link(c, stream, box, rthr)
		return nil, false
	}

	link := new(Control_Link, context.allocator)
	link^ = {conn = c, stream = stream, box = box, reader = rthr, token = info.token}
	return link, true
}

close_control :: proc(link: ^Control_Link) {
	close_control_link(link.conn, link.stream, link.box, link.reader)
	free(link, context.allocator)
}

close_control_link :: proc(c: ^jsonrpc.Conn, stream: ^rpc.Stream, box: ^Control_Box, rthr: ^thread.Thread) {
	jsonrpc.conn_close(c)
	stream.close(stream)
	if rthr != nil {
		thread.join(rthr)
		free(rthr, context.allocator)
	}
	free(box, context.allocator)
	jsonrpc.conn_destroy(c)
	free(c, context.allocator)
}

daemon_status :: proc(g: ^Globals) -> int {
	path, id, code := resolve_control_target("daemon status", g)
	if code != 0 {
		return code
	}

	info, ok := daemon.read_endpoint(path, context.temp_allocator)
	if !ok {
		fmt.eprintf("aubade daemon status: no daemon endpoint for project %s (nothing is running)\n", id)
		return 1
	}

	link, connected := connect_control(info)
	if !connected {
		fmt.eprintf(
			"aubade daemon status: endpoint exists but the daemon is not responding (stale endpoint?): pid %d port %d\n",
			info.pid, info.port,
		)
		return 1
	}

	result, err_code, msg, cerr := jsonrpc.conn_call(
		link.conn, svc.METHOD_STATUS, nil, context.temp_allocator, platform.mono_ms() + svc.CONTROL_CALL_DEADLINE_MS,
	)
	close_control(link)
	if cerr != .None || result == nil {
		fmt.eprintf(
			"aubade daemon status: svc.status failed: %v code=%d msg=%q\n",
			cerr, i32(err_code), msg,
		)
		return 1
	}

	pid := jsonutil.obj_get_int(result, "pid")
	port := jsonutil.obj_get_int(result, "port")
	started := jsonutil.obj_get_int(result, "started_at_ms")
	live := jsonutil.obj_get_int(result, "children_live")
	total := jsonutil.obj_get_int(result, "children_total")

	fmt.printf("daemon running: pid=%d port=%d started_at_ms=%d\n", pid, port, started)
	fmt.printf("children: live=%d total=%d\n", live, total)
	return 0
}

daemon_stop :: proc(g: ^Globals) -> int {
	path, id, code := resolve_control_target("daemon stop", g)
	if code != 0 {
		return code
	}

	info, ok := daemon.read_endpoint(path, context.temp_allocator)
	if !ok {
		fmt.eprintf("aubade daemon stop: no daemon endpoint for project %s (nothing is running)\n", id)
		return 1
	}

	link, connected := connect_control(info)
	if !connected {
		fmt.eprintf(
			"aubade daemon stop: endpoint exists but the daemon is not responding (stale endpoint?): pid %d port %d\n",
			info.pid, info.port,
		)
		return 1
	}

	params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&params, "token", jsonutil.json_string(info.token))
	_, _, msg, cerr := jsonrpc.conn_call(
		link.conn, svc.METHOD_SHUTDOWN, json.Value(json.Object(params)), context.temp_allocator,
		platform.mono_ms() + svc.CONTROL_CALL_DEADLINE_MS,
	)
	if cerr == .Error_Response {
		// The daemon answered with a refusal (other children connected).
		fmt.eprintf("aubade daemon stop: %s\n", msg)
		close_control(link)
		return 1
	}
	// .None or a dropped connection (the daemon may tear the link down
	// before the reply flushes): both proceed to the endpoint check.
	close_control(link)

	// The control connection is gone, so the daemon's drain completes; wait
	// for cleanup to remove endpoint.json (through the real clock — one
	// time discipline for every wait).
	clock: platform.Clock
	platform.clock_init(&clock, false)
	deadline := platform.clock_now(&clock) + svc.CONTROL_CALL_DEADLINE_MS
	for platform.clock_now(&clock) < deadline {
		if !os.exists(path) {
			fmt.println("aubade daemon stop: daemon stopped.")
			return 0
		}
		platform.clock_wait(&clock, 50)
	}
	fmt.eprintln("aubade daemon stop: daemon did not exit within 5s")
	return 1
}
