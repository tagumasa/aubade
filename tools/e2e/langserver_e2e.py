#!/usr/bin/env python3
"""Language-server active-tools E2E for the aubade binary. One MCP child
over stdio against a throwaway Go fixture with an isolated AUBADE_HOME; the
installed binary, client registrations, and the live ~/.aubade are never
touched.

Verified behaviors (the request tools are the point — the lifecycle spawn
side is e2e-lsp's; this driver exercises the management answers and every
query against a real gopls):
1. langserver_list on an unconfigured project answers the setup hint, not
   dozens of not-running registry rows.
2. langserver_start starts gopls (a child of this session's daemon);
   an unknown language is refused naming the language.
3. langserver_restart replaces the server atomically — the gopls pid
   changes.
4. langserver_get_diagnostics surfaces pushed diagnostics from the store:
   the fixture's minimal python LSP (no diagnosticProvider — the pull gate
   must skip such servers) pushes one error per didOpen, and the gopls
   file's real diagnostics answer through the same store path.
5. langserver_get_code_actions returns quickfix-kind actions grounded in
   the stored push diagnostics (unused import / undefined var).
6. langserver_format returns text edits and NEVER applies them — the file
   on disk is byte-identical after the call.
7. langserver_get_inlay_hints answers gopls's hints over a range.
8. langserver_find_calls returns the incoming edge (main -> add) with
   call-site ranges.
9. langserver_reload stops the running servers (list falls back to the
   hint; the next query restarts one on demand), and langserver_stop
   refuses a stopped language by name.
10. The startup fold pass false-warns nothing for the included optional
   management tools (no "tool not available in this session", no
   "unknown tool name" in the child's stderr).

gopls processes are discovered as children of THIS session's daemon pid
(read from the daemon endpoint file) — never via a global pgrep.

Usage:  python3 tools/e2e/langserver_e2e.py [--binary ./aubade] [--keep]
Run from the repo root.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

GO_MAIN = '''package main

import "fmt"

func add(a, b int) int {
return a + b
}

func main() {
s := add(1, 2)
fmt.Println(s)
}
'''

# "os" is imported and unused (a quickfix); undefinedVar is undefined (the
# diagnostics error). Lines (0-based):
#   2: import "os"
#   5: <tab>return undefinedVar
GO_BROKEN = '''package main

import "os"

func useUndefined() int {
	return undefinedVar
}
'''

# A minimal push-diagnostics LSP: no diagnosticProvider in its caps (the
# daemon's pull gate must skip it), and every didOpen gets one pushed
# error — the deterministic store-path verification.
FAKE_LS = r'''
import sys, json

def read_msg():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        k, _, v = line.partition(b":")
        headers[k.strip().lower()] = v.strip()
    n = int(headers.get(b"content-length", b"0"))
    return json.loads(sys.stdin.buffer.read(n))

def send(msg):
    body = json.dumps(msg).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()

while True:
    msg = read_msg()
    if msg is None:
        break
    m = msg.get("method", "")
    if m == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"],
              "result": {"capabilities": {}}})
    elif m == "textDocument/didOpen":
        uri = msg["params"]["textDocument"]["uri"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
              "params": {"uri": uri, "diagnostics": [{
                  "range": {"start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 1}},
                  "severity": 1, "source": "fake",
                  "message": "fake: undefinedVar is not defined"}]}})
    elif m == "shutdown":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
    elif m == "exit":
        break
    elif "id" in msg:
        send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
'''

FAILURES = []


def fail(check, detail):
    FAILURES.append(check)
    print(f"  FAIL {check}: {detail}", flush=True)


def ok(check):
    print(f"  PASS {check}", flush=True)


def gopls_children(daemon_pid):
    """gopls processes whose parent is this session's daemon. Zombies
    count separately: a teardown that kills but never reaps leaves the
    pid listed forever, so callers that assert absence use
    gopls_alive (State != Z)."""
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            status = open(f"/proc/{entry}/status").read()
            comm = open(f"/proc/{entry}/comm").read().strip()
        except OSError:
            continue
        for line in status.splitlines():
            if line.startswith("PPid:"):
                if int(line.split()[1]) == daemon_pid and comm == "gopls":
                    out.append(int(entry))
                break
    return out


def proc_state(pid):
    try:
        for line in open(f"/proc/{pid}/status").read().splitlines():
            if line.startswith("State:"):
                return line.split()[1]
    except OSError:
        pass
    return ""


def gopls_alive(daemon_pid):
    return [p for p in gopls_children(daemon_pid) if proc_state(p) != "Z"]


def daemon_pid_from_home(home: Path):
    """Reads the daemon pid from the endpoint file under AUBADE_HOME."""
    daemon_dir = home / "daemon"
    for run in daemon_dir.iterdir():
        endpoint = run / "endpoint.json"
        if endpoint.exists():
            try:
                info = json.loads(endpoint.read_text())
                return int(info["pid"]), info
            except (json.JSONDecodeError, KeyError, ValueError):
                continue
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=str(Path(__file__).resolve().parents[2] / "aubade"))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    binary = os.path.abspath(args.binary)

    tmp = Path(tempfile.mkdtemp(prefix="aubade-ls-e2e-"))
    home = tmp / "home"
    proj = tmp / "proj"
    (home / ".aubade").mkdir(parents=True)
    (proj / ".aubade").mkdir(parents=True)
    (proj / "main.go").write_text(GO_MAIN)
    (proj / "broken.go").write_text(GO_BROKEN)
    (proj / "app.py").write_text("x = undefined_var\n")
    (proj / "go.mod").write_text("module e2e\n\ngo 1.22\n")
    fake_ls = tmp / "fake_ls.py"
    fake_ls.write_text(FAKE_LS)
    # The management half (start/stop/restart/reload) is optional by
    # default; the queries (list/diagnostics/code_actions/format/
    # inlay_hints/find_calls) are always visible. gopls's inlay hints are
    # not on by default — the options object turns the standard categories
    # on so the tool has something to answer with. The python command
    # override wires the push-diagnostics fake for the store-path legs.
    (proj / ".aubade" / "project.jsonc").write_text(
        '{"included_optional_tools": ["langserver_start",'
        ' "langserver_stop", "langserver_restart", "langserver_reload"],'
        ' "language_server_options": {"go": {"hints":'
        ' {"parameterNames": true, "assignVariableTypes": true,'
        ' "compositeLiteralTypes": true}}},'
        ' "language_server_commands":'
        f' {{"python": ["python3", "{fake_ls}"]}}}}\n')

    env = dict(os.environ)
    env["AUBADE_HOME"] = str(home)
    env["PATH"] = (str(Path.home() / "go" / "bin") + ":/usr/local/go/bin:"
                   + env.get("PATH", ""))

    main_go_before = (proj / "main.go").read_text()

    proc = subprocess.Popen(
        [binary, "mcp", "--project", str(proj), "--tool-timeout", "180000"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=open(tmp / "stderr.log", "wb"), env=env, text=True,
        encoding="utf-8", errors="replace")

    next_id = 0

    def call(method, params=None, notify=False, timeout=300.0):
        nonlocal next_id
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        rid = None
        if not notify:
            next_id += 1
            rid = next_id
            msg["id"] = rid
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        if notify:
            return None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = proc.stdout.readline()
            if not line:
                raise SystemExit("server closed stdout")
            line = line.strip()
            if not line:
                continue
            try:
                resp = json.loads(line)
            except json.JSONDecodeError:
                continue
            if resp.get("id") == rid:
                return resp
        raise SystemExit(f"timeout waiting for id={rid}")

    def tool(name, tool_args, timeout=300.0):
        resp = call("tools/call", {"name": name, "arguments": tool_args},
                    timeout=timeout)
        result = resp.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", [])
                         if isinstance(c, dict) and c.get("type") == "text")
        return bool(result.get("isError", False)), text

    def poll(name, tool_args, want, tries=45, delay=2.0):
        """Retries a query until `want(text)` holds — gopls publishes its
        diagnostics asynchronously, so first answers can be empty."""
        err, text = True, ""
        for _ in range(tries):
            err, text = tool(name, tool_args)
            if not err and want(text):
                return err, text
            time.sleep(delay)
        return err, text

    try:
        # 1. initialize handshake
        init = call("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "ls-e2e", "version": "0"},
        })
        server = init.get("result", {}).get("serverInfo", {}).get("name", "")
        if not server:
            fail("initialize", f"no serverInfo: {init}")
        else:
            ok(f"initialize (server {server})")
        call("notifications/initialized", notify=True)

        dpid, _ = daemon_pid_from_home(home)
        if dpid is None:
            time.sleep(2)
            dpid, _ = daemon_pid_from_home(home)
        if dpid is None:
            fail("daemon endpoint", "no endpoint.json under the temp home")
            raise SystemExit(1)
        ok(f"daemon endpoint (pid {dpid})")

        # 2. list on an unconfigured project: the setup hint, not registry rows
        err, text = tool("langserver_list", {})
        if err or "No language servers are configured or running" not in text:
            fail("list hint", f"err={err} text={text[:200]}")
        else:
            ok("list answered the setup hint")

        # 3. start go: a real gopls child of this daemon
        err, text = tool("langserver_start", {"language": "go"})
        children = gopls_children(dpid)
        if err or "started" not in text:
            fail("start go", f"err={err} text={text[:300]}")
        elif not children:
            fail("start go", "no gopls child after langserver_start")
        else:
            ok(f'start go answered and spawned gopls (pid {children[0]})')
        pid_after_start = (gopls_children(dpid) or [None])[0]

        # 4. list shows the running row
        err, text = tool("langserver_list", {})
        if (err or "go" not in text or "running" not in text
                or "No language servers" in text):
            fail("list running", f"err={err} text={text[:300]}")
        else:
            ok("list shows the running go server")

        # 5. unknown language refused by name
        err, text = tool("langserver_start", {"language": "nosuchlang"})
        if not err or "no language server is registered for language" not in text:
            fail("start unknown", f"err={err} text={text[:300]}")
        else:
            ok("start of an unknown language refused")

        # 6. restart replaces the server: the pid changes and the OLD
        # server is gone (teardown is synchronous; allow a short grace and
        # distinguish a reaping zombie from a still-running leak).
        err, text = tool("langserver_restart", {"language": "go"})
        if err or "restarted" not in text:
            fail("restart go", f"err={err} text={text[:300]}")
        else:
            gone = False
            for _ in range(10):
                if gopls_alive(dpid) and pid_after_start not in gopls_alive(dpid):
                    gone = True
                    break
                time.sleep(1)
            alive = gopls_alive(dpid)
            if not alive:
                fail("restart go", f"no live replacement server: "
                     f"{gopls_children(dpid)}")
            elif not gone or pid_after_start in alive:
                fail("restart go",
                     f"old pid {pid_after_start} still alive (state "
                     f"{proc_state(pid_after_start)}): {gopls_children(dpid)}")
            else:
                ok(f"restart go swapped gopls (pid {alive[0]}); old server gone")

        # 7. code actions grounded in the stored push diagnostics — this
        # also warms the push store the diagnostics leg reads below.
        err, text = poll("langserver_get_code_actions", {
            "relative_path": "broken.go",
            "start_line": 2, "start_col": 0,
            "end_line": 5, "end_col": 20,
        }, lambda t: "quickfix" in t)
        if err or "quickfix" not in text:
            fail("code actions", f"err={err} text={text[:400]}")
        else:
            ok("code actions returned quickfix-kind items")

        # 8. diagnostics through the push store: the fake (no
        # diagnosticProvider — the pull gate must skip it) pushes one error
        # per didOpen; the gopls file answers its real pushed items through
        # the same path.
        err, text = poll("langserver_get_diagnostics",
                         {"relative_path": "app.py"},
                         lambda t: "fake: undefinedVar" in t)
        if err or "fake: undefinedVar" not in text or "error" not in text:
            fail("diagnostics store path", f"err={err} text={text[:400]}")
        else:
            ok("diagnostics surfaced the pushed error through the store")
        err, text = tool("langserver_get_diagnostics",
                         {"relative_path": "broken.go"})
        try:
            items = json.loads(text) if not err else None
        except json.JSONDecodeError:
            items = None
        if err or not isinstance(items, list):
            fail("diagnostics gopls answer", f"err={err} text={text[:300]}")
        else:
            ok(f"diagnostics answered for the gopls file ({len(items)} item(s))")

        # 9. format returns edits WITHOUT applying them
        err, text = tool("langserver_format", {"relative_path": "main.go"})
        edits = []
        try:
            edits = json.loads(text) if not err else []
        except json.JSONDecodeError:
            edits = []
        disk = (proj / "main.go").read_text()
        if err or not edits:
            fail("format edits", f"err={err} text={text[:300]}")
        elif disk != main_go_before:
            fail("format does not apply", "main.go changed on disk")
        elif not any("\t" in e.get("new_text", "") for e in edits):
            fail("format edits", f"no tab-restoring edit: {text[:300]}")
        else:
            ok("format returned gofmt edits and left the disk untouched")

        # 10. inlay hints over the whole badly-formatted file
        err, text = tool("langserver_get_inlay_hints", {
            "relative_path": "main.go",
            "start_line": 0, "start_col": 0, "end_line": 11, "end_col": 0,
        })
        if err:
            fail("inlay hints", f"err={err} text={text[:300]}")
        else:
            try:
                hints = json.loads(text)
            except json.JSONDecodeError:
                hints = None
            if not isinstance(hints, list):
                fail("inlay hints", f"not an items list: {text[:300]}")
            elif not hints:
                fail("inlay hints", "gopls answered no hints at all")
            elif '"parameter"' not in text and '"type"' not in text:
                fail("inlay hints", f"no kind rendered: {text[:300]}")
            else:
                ok(f"inlay hints answered ({len(hints)} hint(s))")

        # 11. call hierarchy: incoming calls of add come from main
        err, text = tool("langserver_find_calls", {
            "relative_path": "main.go", "line": 4, "col": 5,
            "direction": "incoming",
        })
        if err or "main" not in text or "main.go" not in text:
            fail("find calls incoming", f"err={err} text={text[:400]}")
        elif "from_ranges" not in text:
            fail("find calls incoming", f"no call-site ranges: {text[:400]}")
        else:
            ok("find calls incoming named main with call-site ranges")

        # 12. reload stops the running servers; the next query restarts one
        err, text = tool("langserver_reload", {})
        if (err or "reloaded" not in text or "servers stopped" not in text
                or "1 command overrides" not in text):
            fail("reload", f"err={err} text={text[:300]}")
        else:
            ok(f"reload answered ({text.strip()})")
        err, text = tool("langserver_list", {})
        if err or "No language servers are configured or running" not in text:
            fail("reload stopped servers", f"list still shows rows: {text[:300]}")
        else:
            ok("reload stopped the servers (list back to the hint)")

        # 13. a query after reload lazily restarts the servers on demand:
        # the fake answers deterministically, and the gopls respawn is
        # asserted through the process table.
        err, text = poll("langserver_get_diagnostics",
                         {"relative_path": "app.py"},
                         lambda t: "fake: undefinedVar" in t)
        err2, _ = tool("langserver_get_diagnostics",
                       {"relative_path": "broken.go"})
        children_after = gopls_alive(dpid)
        if err or "fake: undefinedVar" not in text:
            fail("query restarts on demand", f"err={err} text={text[:400]}")
        elif err2 or not children_after:
            fail("query restarts on demand",
                 f"gopls not respawned (err2={err2}): {gopls_children(dpid)}")
        else:
            ok(f"queries restarted the servers on demand (gopls pid {children_after[0]})")

        # 13b. stop both languages; each refuses a second stop by name
        err, text = tool("langserver_stop", {"language": "python"})
        if err or "stopped" not in text:
            fail("stop python", f"err={err} text={text[:300]}")
        else:
            ok("stop python answered")

        # 14. stop, then stop again refuses by name
        err, text = tool("langserver_stop", {"language": "go"})
        if err or "stopped" not in text:
            fail("stop go", f"err={err} text={text[:300]}")
        else:
            ok("stop go answered")
        for _ in range(10):
            if not gopls_alive(dpid):
                break
            time.sleep(1)
        alive = gopls_alive(dpid)
        if alive:
            fail("stop go", f"gopls still alive: "
                 f"{[(p, proc_state(p)) for p in gopls_children(dpid)]}")
        else:
            ok("stop go killed the server")
        err, text = tool("langserver_stop", {"language": "go"})
        if not err or "no running language server for language" not in text:
            fail("stop when stopped", f"err={err} text={text[:300]}")
        else:
            ok("stop of a stopped language refused by name")
    finally:
        try:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.close()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        except OSError:
            pass
        # sweep the daemon for this throwaway project only
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid in os.listdir("/proc"):
                if not pid.isdigit():
                    continue
                try:
                    exe = os.readlink(f"/proc/{pid}/exe")
                    cmdline = open(f"/proc/{pid}/cmdline", "rb").read().decode(
                        "utf-8", "replace")
                    if os.path.abspath(exe) == binary and str(tmp) in cmdline:
                        os.kill(int(pid), sig)
                except OSError:
                    continue
            time.sleep(2)

        stderr_text = (tmp / "stderr.log").read_text(errors="replace")
        if "tool not available in this session" in stderr_text:
            fail("no fold false-warnings", "stderr: tool not available")
        elif "unknown tool name" in stderr_text:
            fail("no fold false-warnings", "stderr: unknown tool name")
        else:
            ok("no fold false-warnings in child stderr")

        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"fixture kept at {tmp}", flush=True)

    if FAILURES:
        print(f"\nLS E2E: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nLS E2E: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
