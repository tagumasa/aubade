#!/usr/bin/env python3
"""Shadow-git E2E for the aubade binary. One MCP child over stdio against
a throwaway workspace with an isolated AUBADE_HOME; the installed binary,
client registrations, and the live ~/.aubade are never touched. The six
shadow tools are optional — the fixture's project.jsonc includes them.

Verified behaviors (every workspace mutation is asserted on disk, never
from the tool answer alone):
1. shadow_snapshot commits the workspace and answers "Snapshot created:
   <hash>"; an UNCHANGED workspace returns the same hash (no empty
   commit).
2. shadow_log lists the hashes newest-first.
3. shadow_diff renders the unified diff between two snapshots.
4. shadow_patch lists the files changed between two snapshots, and
   answers "No files changed..." for a self-diff.
5. shadow_revert_file restores one file to its snapshot state and leaves
   siblings untouched.
6. shadow_restore rewrites the whole tree: modified files revert, files
   deleted after the snapshot resurrect, files created after the snapshot
   disappear.
7. An out-of-root file_path is refused before any git conversation
   ("path escapes project root"); a malformed hash is refused as
   "invalid git hash".
8. The startup fold pass false-warns nothing for the included optional
   shadow tools (no "tool not available in this session", no "unknown
   tool name" in the child's stderr).

Usage:  python3 tools/e2e/shadow_e2e.py [--binary ./aubade] [--keep]
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

FAILURES = []


def fail(check, detail):
    FAILURES.append(check)
    print(f"  FAIL {check}: {detail}", flush=True)


def ok(check):
    print(f"  PASS {check}", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=str(Path(__file__).resolve().parents[2] / "aubade"))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    binary = os.path.abspath(args.binary)

    tmp = Path(tempfile.mkdtemp(prefix="aubade-shadow-e2e-"))
    home = tmp / "home"
    proj = tmp / "proj"
    (home / ".aubade").mkdir(parents=True)
    (proj / ".aubade").mkdir(parents=True)
    (proj / "sub").mkdir()
    (proj / "a.txt").write_text("alpha\n")
    (proj / "sub" / "b.txt").write_text("beta\n")
    (proj / ".aubade" / "project.jsonc").write_text(
        '{"included_optional_tools": ["shadow_snapshot", "shadow_log",'
        ' "shadow_diff", "shadow_patch", "shadow_restore",'
        ' "shadow_revert_file"]}\n')

    env = dict(os.environ)
    env["AUBADE_HOME"] = str(home)

    proc = subprocess.Popen(
        [binary, "mcp", "--project", str(proj), "--tool-timeout", "60000"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=open(tmp / "stderr.log", "wb"), env=env, text=True,
        encoding="utf-8", errors="replace")

    next_id = 0

    def call(method, params=None, notify=False, timeout=120.0):
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

    def tool(name, tool_args, timeout=120.0):
        resp = call("tools/call", {"name": name, "arguments": tool_args},
                    timeout=timeout)
        result = resp.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", [])
                         if isinstance(c, dict) and c.get("type") == "text")
        return bool(result.get("isError", False)), text

    def read(rel):
        return (proj / rel).read_text()

    def snapshot(message=""):
        err, text = tool("shadow_snapshot", {"message": message} if message else {})
        if err or "Snapshot created:" not in text:
            fail("snapshot", f"err={err} text={text[:300]}")
            return None
        return text.split()[-1]

    try:
        # 1. initialize handshake
        init = call("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "shadow-e2e", "version": "0"},
        })
        server = init.get("result", {}).get("serverInfo", {}).get("name", "")
        if not server:
            fail("initialize", f"no serverInfo: {init}")
        else:
            ok(f"initialize (server {server})")
        call("notifications/initialized", notify=True)

        # 2. first snapshot (with a message); unchanged → same hash
        h1 = snapshot("first")
        if h1 is None:
            raise SystemExit(1)
        ok(f"snapshot created {h1[:12]}")
        h1b = snapshot()
        if h1b != h1:
            fail("unchanged snapshot", f"{h1b} != {h1}")
        else:
            ok("unchanged workspace returns the same hash (no empty commit)")

        # 3. mutate: modify, delete, create — then snapshot again
        (proj / "a.txt").write_text("alpha-two\n")
        (proj / "sub" / "b.txt").unlink()
        (proj / "c.txt").write_text("gamma\n")
        h2 = snapshot("second")
        if h2 is None:
            raise SystemExit(1)
        if h2 == h1:
            fail("changed snapshot", "hash unchanged after edits")
        else:
            ok(f"changed workspace snapshot {h2[:12]}")

        # 4. log is newest-first
        err, text = tool("shadow_log", {"count": 10})
        lines = [l for l in text.splitlines() if l.strip()]
        if err or len(lines) < 2 or lines[0] != h2 or h1 not in lines:
            fail("log", f"err={err} text={text[:300]}")
        else:
            ok("log lists snapshots newest-first")

        # 5. diff shows both sides of the change
        err, text = tool("shadow_diff", {"from": h1, "to": h2})
        if (err or "-alpha" not in text or "+alpha-two" not in text
                or "b.txt" not in text):
            fail("diff", f"err={err} text={text[:400]}")
        else:
            ok("diff rendered the unified change")

        # 6. patch lists exactly the changed files
        err, text = tool("shadow_patch", {"from": h1, "to": h2})
        files = {l.strip() for l in text.splitlines() if l.strip()}
        want = {"a.txt", "sub/b.txt", "c.txt"}
        if err or files != want:
            fail("patch", f"err={err} files={sorted(files)} want={sorted(want)}")
        else:
            ok("patch listed the three changed files")
        err, text = tool("shadow_patch", {"from": h1, "to": h1})
        if err or "No files changed" not in text:
            fail("patch self-diff", f"err={err} text={text[:200]}")
        else:
            ok("patch self-diff answered no changes")

        # 7. revert_file restores one file, siblings untouched
        (proj / "a.txt").write_text("alpha-three\n")
        err, text = tool("shadow_revert_file", {"hash": h2, "file_path": "a.txt"})
        if err or read("a.txt") != "alpha-two\n" or read("c.txt") != "gamma\n":
            fail("revert_file", f"err={err} a={read('a.txt')!r}")
        else:
            ok("revert_file restored a.txt and left c.txt alone")

        # 8. restore rewrites the whole tree to h1
        err, text = tool("shadow_restore", {"hash": h1})
        b_back = (proj / "sub" / "b.txt").exists()
        if (err or read("a.txt") != "alpha\n" or not b_back
                or (proj / "c.txt").exists()):
            fail("restore", f"err={err} a={read('a.txt')!r} b={b_back} "
                 f"c={(proj / 'c.txt').exists()}")
        else:
            ok("restore reverted, resurrected, and removed the new file")

        # 9. refusals: out-of-root path and malformed hash
        err, text = tool("shadow_revert_file",
                         {"hash": h1, "file_path": "../outside.txt"})
        if not err or "escapes project root" not in text:
            fail("revert_file escape", f"err={err} text={text[:300]}")
        else:
            ok("out-of-root revert_file refused")
        err, text = tool("shadow_diff", {"from": "nothex!", "to": h1})
        if not err or "invalid git hash" not in text:
            fail("diff bad hash", f"err={err} text={text[:300]}")
        else:
            ok("malformed hash refused")
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
        print(f"\nSHADOW E2E: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nSHADOW E2E: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
