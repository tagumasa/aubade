#!/usr/bin/env python3
"""Tracker/memory MCP-family E2E for the Odin aubade binary. One MCP child
over stdio against a throwaway project with an isolated AUBADE_HOME; the
installed binary, client registrations, and the live ~/.aubade are never
touched. The CLI surface of these families is covered by cli_battery; this
driver exercises the MCP wire path (param gates, event fold, answers).

Verified behaviors:
1. Incident lifecycle over the wire: create (labels/priority stick in
   list filters) → verify confirmed (state gate visible in get) →
   resolve REFUSED before root_cause → root_cause → resolve fixed →
   gone from open lists. A rejected verdict stays queryable, and
   delete removes a throwaway from the lists.
2. Sprint lifecycle: start with must rows → close REFUSED while a must
   task lacks verification → record_verification → typed defer
   (descope) for the other → close succeeds → outcome revision on the
   closed sprint → list/get/export see it.
3. Memory family: write/read/list round trip, literal replace, rename
   (old name stops resolving) with mem: reference propagation into a
   second memory, delete, and not-found refusals.
4. Negatives: unknown incident IDs and missing memories are typed
   errors, not crashes.

Usage:  python3 tools/e2e/tracker_e2e.py [--binary ./aubade] [--keep]
Run from the repo root.
"""

import argparse
import json
import os
import re
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

    tmp = Path(tempfile.mkdtemp(prefix="aubade-tracker-e2e-"))
    home = tmp / "home"
    proj = tmp / "proj"
    home.mkdir()
    proj.mkdir()
    (proj / "README.md").write_text("# fixture project\n")

    env = dict(os.environ)
    env["AUBADE_HOME"] = str(home)

    stderr_log = open(tmp / "stderr.log", "wb")
    proc = subprocess.Popen(
        [binary, "mcp", "--project", str(proj), "--tool-timeout", "60000"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=stderr_log, env=env, text=True,
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

    def check(cond, name, detail):
        if cond:
            ok(name)
        else:
            fail(name, detail)

    try:
        init = call("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "tracker-e2e", "version": "0"},
        })
        server = init.get("result", {}).get("serverInfo", {}).get("name", "")
        check(bool(server), "initialize", f"no serverInfo: {init}")
        call("notifications/initialized", notify=True)

        # --- 1. incident lifecycle ---------------------------------------
        err, text = tool("incident_create", {
            "title": "Driver fixture defect",
            "description": "Body for the e2e round: `fixture.md:1` quotes a line.",
            "priority": "low", "labels": ["e2e", "driver"],
            "created_by": "tracker-e2e"})
        m = re.search(r"INC-\d+", text)
        check(not err and m is not None, "incident_create", f"err={err} text={text[:200]}")
        inc = m.group(0) if m else "INC-0"

        err, text = tool("incident_list", {"status": ["reported"], "label": "e2e"})
        check(not err and inc in text, "incident_list filter", f"err={err} text={text[:200]}")

        err, text = tool("incident_get", {"id": inc})
        check(not err and "reported" in text and inc in text,
              "incident_get reported", f"err={err} text={text[:200]}")

        err, text = tool("incident_update", {"id": inc, "priority": "medium"})
        check(not err, "incident_update priority", f"err={err} text={text[:200]}")
        err, text = tool("incident_list", {"priority": ["medium"], "query": "Driver fixture"})
        check(not err and inc in text, "priority filter sees medium",
              f"err={err} text={text[:200]}")

        # resolve before root_cause is refused (the state gate names the
        # current status and the next required step).
        err, text = tool("incident_resolve", {"id": inc, "resolution": "fixed",
                                              "evidence": "premature"})
        check(err and "use incident_verify first" in text,
              "premature resolve refused",
              f"err={err} text={text[:200]}")

        err, text = tool("incident_verify", {
            "id": inc, "verdict": "confirmed",
            "reason": "the driver reaches the defect over the real wire",
            "evidence": "tools/e2e/tracker_e2e.py:1 — 'Driver fixture defect'"})
        check(not err, "incident_verify confirmed", f"err={err} text={text[:200]}")

        err, text = tool("incident_update", {"id": inc,
                                             "root_cause": "fixture-only root cause"})
        check(not err, "root_cause recorded", f"err={err} text={text[:200]}")

        err, text = tool("incident_resolve", {"id": inc, "resolution": "fixed",
                                              "evidence": "tracker e2e driver run"})
        check(not err, "incident_resolve fixed", f"err={err} text={text[:200]}")

        err, text = tool("incident_list", {"status": ["open"]})
        check(not err and inc not in text, "resolved leaves open lists",
              f"err={err} text={text[:300]}")

        # a rejected verdict is kept and queryable by verdict filter.
        err, text = tool("incident_create", {
            "title": "Driver false positive", "description": "kept for FP stats."})
        m2 = re.search(r"INC-\d+", text)
        fp = m2.group(0) if m2 else "INC-0"
        check(not err and m2 is not None, "second incident created",
              f"err={err} text={text[:200]}")
        err, text = tool("incident_verify", {
            "id": fp, "verdict": "rejected", "reason": "the guard exists",
            "evidence": "tools/e2e/tracker_e2e.py:1 — quoted guard",
            "fp_pattern": "untraced-guard"})
        check(not err, "rejected verdict recorded", f"err={err} text={text[:200]}")
        err, text = tool("incident_list", {"verdict": "rejected"})
        check(not err and fp in text, "rejected filter keeps it",
              f"err={err} text={text[:200]}")

        # delete removes a throwaway from the lists.
        err, text = tool("incident_create", {
            "title": "Driver duplicate", "description": "to be removed."})
        m3 = re.search(r"INC-\d+", text)
        dup = m3.group(0) if m3 else "INC-0"
        err, text = tool("incident_delete", {"id": dup, "reason": "driver cleanup"})
        check(not err, "incident_delete", f"err={err} text={text[:200]}")
        err, text = tool("incident_list", {"query": "Driver duplicate"})
        check(not err and dup not in text, "deleted leaves lists",
              f"err={err} text={text[:200]}")

        # --- 2. sprint lifecycle ----------------------------------------
        err, text = tool("sprint_start", {
            "name": "Driver sprint",
            "goal": "| Task | MoSCoW | Verification |\n|---|---|---|\n"
                    "| T1 | must | driver run |\n| T2 | must | driver run |",
            "must": ["T1", "T2"]})
        ms = re.search(r"SPR-\d+", text)
        check(not err and ms is not None, "sprint_start", f"err={err} text={text[:200]}")
        spr = ms.group(0) if ms else "SPR-0"

        # close is refused while T2 has neither verification nor defer.
        err, text = tool("sprint_record_verification", {
            "task": "T1", "definition": "python3 tools/e2e/tracker_e2e.py",
            "outcome": "passed", "output": "T1 leg: ALL PASS"})
        check(not err, "record_verification T1", f"err={err} text={text[:200]}")
        err, text = tool("sprint_close", {"outcome": "premature"})
        check(err, "close refused on unverified must",
              f"err={err} text={text[:200]}")

        err, text = tool("sprint_update", {
            "id": "current", "defer_type": "descope", "task": "T2",
            "note": "T2 stays outside the driver round."})
        check(not err, "typed defer T2", f"err={err} text={text[:200]}")

        err, text = tool("sprint_close", {"outcome": "driver round outcome"})
        check(not err, "sprint_close", f"err={err} text={text[:200]}")

        err, text = tool("sprint_get", {"id": spr})
        check(not err and "driver round outcome" in text and "closed" in text,
              "sprint_get closed", f"err={err} text={text[:300]}")

        err, text = tool("sprint_update", {"id": spr,
                                           "outcome": "revised driver outcome"})
        check(not err, "outcome revision on closed sprint",
              f"err={err} text={text[:200]}")
        err, text = tool("sprint_list", {"include_closed": True})
        check(not err and "Driver sprint" in text, "sprint_list includes closed",
              f"err={err} text={text[:300]}")

        # Export renders the sprint's report into the tracker store — the
        # answer acknowledges the sprint and the filed count.
        err, text = tool("tracker_export", {"sprint": spr})
        check(not err and "Exported" in text and spr in text, "tracker_export",
              f"err={err} text={text[:300]}")

        # --- 3. memory family -------------------------------------------
        err, text = tool("memory_write", {
            "memory_name": "e2e/topic-one",
            "content": "# one\nfirst memory\n"})
        check(not err, "memory_write", f"err={err} text={text[:200]}")
        err, text = tool("memory_write", {
            "memory_name": "e2e/reader",
            "content": "see mem:e2e/topic-one here\n"})
        check(not err, "second memory written", f"err={err} text={text[:200]}")

        err, text = tool("memory_read", {"memory_name": "e2e/topic-one"})
        check(not err and "first memory" in text, "memory_read",
              f"err={err} text={text[:200]}")

        err, text = tool("memory_list", {"topic": "e2e"})
        check(not err and "e2e/topic-one" in text and "e2e/reader" in text,
              "memory_list topic", f"err={err} text={text[:300]}")

        err, text = tool("memory_replace", {
            "memory_name": "e2e/topic-one", "needle": "first memory",
            "repl": "edited memory", "mode": "literal"})
        check(not err, "memory_replace", f"err={err} text={text[:200]}")
        err, text = tool("memory_read", {"memory_name": "e2e/topic-one"})
        check(not err and "edited memory" in text and "first memory" not in text,
              "replace landed", f"err={err} text={text[:200]}")

        # rename stops the old name (a friendly not-found answer, not an
        # error) and propagates mem: references.
        err, text = tool("memory_rename", {"old_name": "e2e/topic-one",
                                           "new_name": "e2e/topic-two"})
        check(not err, "memory_rename", f"err={err} text={text[:200]}")
        err, text = tool("memory_read", {"memory_name": "e2e/topic-one"})
        check(not err and "not found" in text, "old name stops resolving",
              f"err={err} text={text[:200]}")
        err, text = tool("memory_read", {"memory_name": "e2e/reader"})
        check(not err and "mem:e2e/topic-two" in text, "mem: reference propagated",
              f"err={err} text={text[:200]}")

        err, text = tool("memory_delete", {"memory_name": "e2e/topic-two"})
        check(not err, "memory_delete", f"err={err} text={text[:200]}")
        err, text = tool("memory_list", {"topic": "e2e"})
        check(not err and "e2e/topic-two" not in text, "deleted memory leaves list",
              f"err={err} text={text[:300]}")

        # --- 4. negatives -------------------------------------------------
        err, text = tool("incident_get", {"id": "INC-999999"})
        check(err, "unknown incident refused", f"err={err} text={text[:200]}")
        # A missing memory answers the friendly not-found guidance.
        err, text = tool("memory_read", {"memory_name": "e2e/absent"})
        check(not err and "not found" in text, "missing memory answered",
              f"err={err} text={text[:200]}")
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
        stderr_log.close()
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
        if FAILURES:
            print(f"--- child stderr tail ---\n{stderr_text[-2000:]}", flush=True)
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"fixture kept at {tmp}", flush=True)

    # The startup fold-warning pass folds with every capability: a session
    # naming optional-but-included or mode-excluded tools must not log
    # "tool not available in this session" for tools it serves.
    check("tool not available in this session" not in stderr_text,
          "no fold false-warnings in child stderr", stderr_text[-500:])

    if FAILURES:
        print(f"\nTracker E2E: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nTracker E2E: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
