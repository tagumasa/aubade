#!/usr/bin/env python3
"""Daemon lifecycle E2E for the Odin aubade binary: multi-child sessions,
heartbeat fan-in, the childless grace exit, stale-endpoint takeover, and
child self-healing after a daemon crash. Throwaway project + isolated
AUBADE_HOME; the installed binary, client registrations, and the live
~/.aubade are never touched.

Verified behaviors:
1. Two MCP children spawned simultaneously against a fresh project share
   ONE daemon (the flock race has exactly one winner; both children answer
   svc-backed tools through the same endpoint pid).
2. Heartbeat fan-in: SIGKILL of one child leaves the daemon alive while
   another child lives — past both the misses window and the grace window.
3. Childless grace exit: a clean close of the last child exits the daemon
   and removes endpoint.json.
4. Cold-start stale-endpoint takeover: an endpoint.json naming a dead pid
   and a closed port blocks nothing — the next child spawns a fresh daemon
   and answers; the publication is replaced.
5. Daemon SIGKILL with a live child: the child detects the dead link
   (heartbeat reconnect), respawns a NEW daemon, and answers tools again.
6. No fold false-warnings in any child's stderr.

Children run with shrunken timing (--hb-ping-ms 1000 --hb-timeout-ms 5000
--grace-ms 3000) so every window is observable in seconds; the spawned
daemon inherits the same values through its argv.

Usage:  python3 tools/e2e/daemon_e2e.py [--binary ./aubade] [--keep]
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

PY_MAIN = '''class Greeter:
    def greet(self):
        return "hi"


def main():
    g = Greeter()
    return g.greet()
'''

# Shrunken lifecycle windows (milliseconds) shared by every child; the
# daemon inherits them through the spawn argv.
HB_PING_MS = "1000"
HB_TIMEOUT_MS = "5000"
GRACE_MS = "3000"

FAILURES = []


def fail(check, detail):
    FAILURES.append(check)
    print(f"  FAIL {check}: {detail}", flush=True)


def ok(check):
    print(f"  PASS {check}", flush=True)


def proc_state(pid):
    """Process state letter from /proc, "" when the pid is gone. A zombie
    counts as gone: an exited flock-loser or killed daemon waits on its
    spawner's reap and must not be mistaken for a live daemon."""
    if pid is None or pid <= 0:
        return ""
    try:
        for line in open(f"/proc/{pid}/status").read().splitlines():
            if line.startswith("State:"):
                return line.split()[1]
    except OSError:
        return ""
    return ""


def pid_alive(pid):
    return proc_state(pid) not in ("", "Z")


def daemon_pids(binary, home):
    """`aubade _daemon` processes for THIS home, zombies excluded."""
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            exe = os.readlink(f"/proc/{entry}/exe")
            cmdline = open(f"/proc/{entry}/cmdline", "rb").read().decode(
                "utf-8", "replace")
        except OSError:
            continue
        if (os.path.abspath(exe) == binary and "_daemon" in cmdline
                and str(home) in cmdline and proc_state(int(entry)) != "Z"):
            out.append(int(entry))
    return out


def read_endpoint(home):
    """The first endpoint.json under <home>/daemon/ -> (path, dict)."""
    daemon_dir = home / "daemon"
    if not daemon_dir.is_dir():
        return None, None
    for run in daemon_dir.iterdir():
        endpoint = run / "endpoint.json"
        if endpoint.exists():
            try:
                return endpoint, json.loads(endpoint.read_text())
            except (json.JSONDecodeError, OSError):
                continue
    return None, None


class Child:
    """One MCP child over stdio NDJSON."""

    def __init__(self, binary, project, tmp, name, env):
        self.name = name
        self.log = open(tmp / f"{name}.stderr.log", "wb")
        self.proc = subprocess.Popen(
            [binary, "mcp", "--project", str(project),
             "--tool-timeout", "120000",
             "--hb-ping-ms", HB_PING_MS, "--hb-timeout-ms", HB_TIMEOUT_MS,
             "--grace-ms", GRACE_MS],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, env=env, text=True,
            encoding="utf-8", errors="replace")
        self.next_id = 0

    def call(self, method, params=None, notify=False, timeout=60.0):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        rid = None
        if not notify:
            self.next_id += 1
            rid = self.next_id
            msg["id"] = rid
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        if notify:
            return None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise SystemExit(f"[{self.name}] server closed stdout")
            line = line.strip()
            if not line:
                continue
            try:
                resp = json.loads(line)
            except json.JSONDecodeError:
                continue
            if resp.get("id") == rid:
                return resp
        raise SystemExit(f"[{self.name}] timeout waiting for id={rid}")

    def initialize(self):
        init = self.call("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "daemon-e2e", "version": "0"},
        })
        server = init.get("result", {}).get("serverInfo", {}).get("name", "")
        if not server:
            fail(f"{self.name} initialize", f"no serverInfo: {init}")
            return False
        self.call("notifications/initialized", notify=True)
        ok(f"{self.name} initialize (server {server})")
        return True

    def tool(self, name, tool_args, timeout=60.0):
        resp = self.call("tools/call", {"name": name, "arguments": tool_args},
                         timeout=timeout)
        result = resp.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", [])
                         if isinstance(c, dict) and c.get("type") == "text")
        return bool(result.get("isError", False)), text

    def symbol_list_ok(self):
        err, text = self.tool("symbol_list", {"relative_path": "main.py"})
        if err or "Greeter" not in text:
            fail(f"{self.name} symbol_list", f"err={err} text={text[:200]}")
            return False
        return True

    def close_and_wait(self, timeout=20.0):
        try:
            if self.proc.stdin and not self.proc.stdin.closed:
                self.proc.stdin.close()
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()

    def kill_and_wait(self):
        self.proc.kill()
        self.proc.wait()
        self.log.close()


def wait_gone(pid, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.2)
    return not pid_alive(pid)


def dead_pid():
    """A pid that has certainly exited and been reaped."""
    victim = subprocess.Popen(["true"])
    victim.wait()
    return victim.pid


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=str(Path(__file__).resolve().parents[2] / "aubade"))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    binary = os.path.abspath(args.binary)

    tmp = Path(tempfile.mkdtemp(prefix="aubade-daemon-e2e-"))
    home = tmp / "home"
    proj = tmp / "proj"
    home.mkdir()
    proj.mkdir()
    (proj / "main.py").write_text(PY_MAIN)
    env = dict(os.environ)
    env["AUBADE_HOME"] = str(home)

    children = []

    def new_child(name):
        c = Child(binary, proj, tmp, name, env)
        children.append(c)
        return c

    def sweep():
        for c in children:
            try:
                if c.proc.poll() is None:
                    c.proc.stdin.close()
                c.proc.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                c.proc.kill()
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
            time.sleep(1)

    try:
        # 1. simultaneous spawn: one daemon wins the flock race, both answer
        a = new_child("child-a")
        b = new_child("child-b")
        if not (a.initialize() and b.initialize()):
            raise SystemExit(1)
        time.sleep(1.5)  # let a flock loser exit and be reaped
        if not (a.symbol_list_ok() and b.symbol_list_ok()):
            raise SystemExit(1)
        daemons = daemon_pids(binary, home)
        endpoint_path, info = read_endpoint(home)
        if len(daemons) != 1:
            fail("singleton spawn", f"daemon pids: {daemons}")
            raise SystemExit(1)
        if endpoint_path is None or info is None:
            fail("endpoint published", "no endpoint.json under the temp home")
            raise SystemExit(1)
        if info.get("pid") != daemons[0]:
            fail("endpoint matches daemon",
                 f"endpoint pid {info.get('pid')} != running {daemons[0]}")
            raise SystemExit(1)
        ok(f"two children share one daemon (pid {daemons[0]}, "
           f"port {info.get('port')})")
        daemon_pid = daemons[0]

        # 2. heartbeat fan-in: one child SIGKILLed, the daemon must stay
        a.kill_and_wait()
        time.sleep(8)  # > misses window (3 x 1s) and > grace (3s)
        if not pid_alive(daemon_pid):
            fail("fan-in keeps daemon", "daemon exited with a live child left")
        elif not b.symbol_list_ok():
            fail("fan-in keeps daemon", "survivor stopped answering")
        else:
            ok("daemon survived a child's SIGKILL while another child lives")

        # 3. childless grace exit + endpoint removal on the clean path
        b.close_and_wait()
        if not wait_gone(daemon_pid, 20):
            fail("grace exit", f"daemon pid {daemon_pid} still alive after 20s")
        elif endpoint_path.exists():
            fail("grace exit removes endpoint", "endpoint.json survived")
        else:
            ok("daemon exited after the last child and removed endpoint.json")

        # 4. cold-start stale endpoint: dead pid + closed port blocks nothing
        stale_pid = dead_pid()
        endpoint_path.parent.mkdir(parents=True, exist_ok=True)
        endpoint_path.write_text(json.dumps(
            {"pid": stale_pid, "port": 1, "started_at": 0, "token": "stale"}))
        c = new_child("child-c")
        if not c.initialize() or not c.symbol_list_ok():
            fail("stale endpoint takeover", "child never answered")
        else:
            _, fresh = read_endpoint(home)
            daemons = daemon_pids(binary, home)
            if fresh is None or fresh.get("pid") == stale_pid:
                fail("stale endpoint takeover", f"endpoint not replaced: {fresh}")
            elif len(daemons) != 1 or daemons[0] != fresh.get("pid"):
                fail("stale endpoint takeover",
                     f"daemon set {daemons} vs endpoint {fresh and fresh.get('pid')}")
            else:
                ok(f"stale endpoint taken over (dead pid {stale_pid} -> "
                   f"daemon {daemons[0]})")
        c.close_and_wait()
        for pid in daemon_pids(binary, home):
            wait_gone(pid, 20)

        # 5. daemon SIGKILL with a live child: respawn + answer through a NEW pid
        d = new_child("child-d")
        if not d.initialize() or not d.symbol_list_ok():
            fail("daemon crash self-heal", "child never answered before the kill")
        else:
            daemons = daemon_pids(binary, home)
            if len(daemons) != 1:
                fail("daemon crash self-heal", f"daemon set before kill: {daemons}")
            else:
                old_pid = daemons[0]
                os.kill(old_pid, signal.SIGKILL)
                healed = False
                deadline = time.monotonic() + 40
                while time.monotonic() < deadline:
                    err, text = d.tool("symbol_list",
                                       {"relative_path": "main.py"},
                                       timeout=30)
                    _, after = read_endpoint(home)
                    daemons = daemon_pids(binary, home)
                    if (not err and "Greeter" in text and len(daemons) == 1
                            and after is not None
                            and after.get("pid") == daemons[0]
                            and daemons[0] != old_pid):
                        healed = True
                        break
                    time.sleep(1)
                if healed:
                    ok(f"child self-healed through a new daemon "
                       f"(pid {old_pid} -> {daemons[0]})")
                else:
                    fail("daemon crash self-heal",
                         f"no answering child/new daemon within 40s "
                         f"(daemons={daemon_pids(binary, home)})")

        # 6. no fold false-warnings in any child stderr
        guard_bad = ["not available in this session", "unknown tool name"]
        guard_hits = []
        for c_ in children:
            try:
                stderr = (tmp / f"{c_.name}.stderr.log").read_text(
                    errors="replace")
            except OSError:
                continue
            guard_hits += [f"{c_.name}: {s}" for s in guard_bad if s in stderr]
        if guard_hits:
            fail("stderr guard", str(guard_hits))
        else:
            ok("no fold false-warnings in child stderr")
    finally:
        sweep()
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"fixture kept at {tmp}", flush=True)

    if FAILURES:
        print(f"\nDaemon E2E: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nDaemon E2E: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
