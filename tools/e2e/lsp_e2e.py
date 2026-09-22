#!/usr/bin/env python3
"""LSP lifecycle E2E for the Odin aubade binary. One MCP child over stdio
against a throwaway Go fixture with an isolated AUBADE_HOME; the installed
binary, client registrations, and the live ~/.aubade are never touched.

Verified behaviors:
1. initialize handshake (serverInfo).
2. symbol_list answers from the tree-sitter path WITHOUT spawning gopls
   (the language server must not exist yet).
3. symbol_find answers from the index and still never spawns a server —
   a name search only consults already-running servers by design.
4. symbol_find_references lazy-starts gopls, synchronously with the
   request (the first references call carries the whole cold start).
5. The gopls process lives under the daemon's cgroup (equal when
   delegation is unavailable, or in an aubade-ls-go-<pid> sub-group).
6. After kill -9 of gopls: symbol_find still answers (the index path
   never needed the server), and the next references call transparently
   respawns a NEW gopls process (dead servers are replaced on the next
   call, not waited on).

gopls processes are discovered as children of THIS session's daemon pid
(read from the daemon endpoint file) — never via a global pgrep, so an
editor's gopls elsewhere on the machine cannot confuse the assertions.

Usage:  python3 tools/e2e/lsp_e2e.py [--binary ./aubade] [--keep]
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

type Greeter struct {
	Name string
}

func (g Greeter) Greet() string {
	return "hello " + g.Name
}

func main() {
	g := Greeter{Name: "e2e"}
	fmt.Println(g.Greet())
}
'''

FAILURES = []


def fail(check, detail):
    FAILURES.append(check)
    print(f"  FAIL {check}: {detail}", flush=True)


def ok(check):
    print(f"  PASS {check}", flush=True)


def gopls_children(daemon_pid):
    """gopls processes whose parent is this session's daemon."""
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


def cgroup_path_of(pid):
    try:
        for line in open(f"/proc/{pid}/cgroup").read().splitlines():
            if line.startswith("0::"):
                return line[3:]
    except OSError:
        pass
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=str(Path(__file__).resolve().parents[2] / "aubade"))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    binary = os.path.abspath(args.binary)

    tmp = Path(tempfile.mkdtemp(prefix="aubade-lsp-e2e-"))
    home = tmp / "home"
    proj = tmp / "proj"
    home.mkdir()
    proj.mkdir()
    (proj / "main.go").write_text(GO_MAIN)
    (proj / "go.mod").write_text("module e2e\n\ngo 1.22\n")
    (proj / "e2e.json").write_text(
        "{\n  \"name\": \"e2e\",\n  \"steps\": [\"build\", \"test\"]\n}\n")

    env = dict(os.environ)
    env["AUBADE_HOME"] = str(home)
    env["PATH"] = (str(Path.home() / "go" / "bin") + ":/usr/local/go/bin:"
                   + env.get("PATH", ""))

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

    try:
        # 1. initialize handshake
        init = call("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "lsp-e2e", "version": "0"},
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

        # 2. symbol_list must answer tree-sitter-only: no gopls child yet
        err, text = tool("symbol_list", {"relative_path": "main.go"})
        if err:
            fail("symbol_list", text[:200])
        elif gopls_children(dpid):
            fail("symbol_list spawns no server",
                 f"gopls children: {gopls_children(dpid)}")
        else:
            ok("symbol_list answered without spawning gopls")

        # 3. symbol_find hits the index and still spawns nothing
        err, text = tool("symbol_find", {"name_path_pattern": "Greeter"})
        if err or "Greeter" not in text:
            fail("symbol_find", f"err={err} text={text[:200]}")
        elif gopls_children(dpid):
            fail("symbol_find spawns no server",
                 f"gopls children: {gopls_children(dpid)}")
        else:
            ok("symbol_find answered without spawning gopls")

        # 3b. file_read_outline answers structurally over the real binary:
        # key tree without a path, exact value with one.
        err, text = tool("file_read_outline", {"relative_path": "e2e.json"})
        if err or "steps: [2] (L2)" not in text or "\"build\" (L2)" not in text:
            fail("file_read_outline outline", f"err={err} text={text[:200]}")
        else:
            ok("file_read_outline outlined the JSON key tree")
        err, text = tool("file_read_outline", {"relative_path": "e2e.json",
                                          "path": ".steps[1]"})
        if err or "test" not in text:
            fail("file_read_outline path", f"err={err} text={text[:200]}")
        else:
            ok("file_read_outline extracted .steps[1]")

        # 4. references lazy-start gopls, synchronously
        err, text = tool("symbol_find_references",
                         {"name_path": "Greeter/Greet",
                          "relative_path": "main.go"})
        children = gopls_children(dpid)
        if err:
            fail("references lazy-start", text[:300])
        elif not children:
            fail("references lazy-start", "no gopls child after the call")
        else:
            ok(f"references lazy-started gopls (pid {children[0]})")

        # 5. cgroup containment: equal (no delegation) or aubade-ls-go- child
        daemon_cg = cgroup_path_of(dpid)
        gopls_pid = children[0] if children else None
        gopls_cg = cgroup_path_of(gopls_pid) if gopls_pid else None
        if gopls_cg is None or daemon_cg is None:
            fail("cgroup containment", f"daemon={daemon_cg} gopls={gopls_cg}")
        elif gopls_cg == daemon_cg or gopls_cg.startswith(
                daemon_cg + "/aubade-ls-go-"):
            ok(f"cgroup containment ({gopls_cg})")
        else:
            fail("cgroup containment",
                 f"gopls {gopls_cg} outside daemon {daemon_cg}")

        # 6. kill -9 gopls: find survives, references transparently respawn
        os.kill(gopls_pid, signal.SIGKILL)
        time.sleep(1)
        err, text = tool("symbol_find", {"name_path_pattern": "Greeter"})
        if err or "Greeter" not in text:
            fail("find survives gopls death", f"err={err} text={text[:200]}")
        else:
            ok("symbol_find survived kill -9 of gopls")
        err, text = tool("symbol_find_references",
                         {"name_path": "Greeter/Greet",
                          "relative_path": "main.go"})
        respawned = gopls_children(dpid)
        if err:
            fail("references respawn", text[:300])
        elif not respawned:
            fail("references respawn", "no new gopls child after the call")
        elif respawned == [gopls_pid]:
            fail("references respawn", "old pid still listed?")
        else:
            ok(f"references transparently respawned gopls (pid {respawned[0]})")
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
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                exe = os.readlink(f"/proc/{pid}/exe")
                cmdline = open(f"/proc/{pid}/cmdline", "rb").read().decode(
                    "utf-8", "replace")
            except OSError:
                continue
            if os.path.abspath(exe) == binary and str(tmp) in cmdline:
                try:
                    os.kill(int(pid), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(2)
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                exe = os.readlink(f"/proc/{pid}/exe")
                cmdline = open(f"/proc/{pid}/cmdline", "rb").read().decode(
                    "utf-8", "replace")
                if os.path.abspath(exe) == binary and str(tmp) in cmdline:
                    os.kill(int(pid), signal.SIGKILL)
            except OSError:
                continue
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"fixture kept at {tmp}", flush=True)

    if FAILURES:
        print(f"\nLSP E2E: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nLSP E2E: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
