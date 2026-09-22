#!/usr/bin/env python3
"""Real-binary CLI battery: drives every CLI family of the Odin aubade
binary against a throwaway fixture — a temp project copy, a temp
AUBADE_HOME, and (for the setup legs only) a redirected HOME — and
asserts exit codes and stable stdout markers. Nothing here touches the
installed binary, the live $HOME, client registrations, or the live
~/.aubade; teardown deletes the fixture.

Conventions verified per family (exit 0 success / 1 runtime failure /
2 usage error; usage errors print `aubade <cmd>: ...` on stderr).
`setup claudecode` / `setup codex` are excluded: they execute the real
client binaries (`claude mcp add` / `codex mcp add`); the zcode and
opencode legs are pure file writes and run under the redirected HOME,
and the written opencode entry is booted once (stdio initialize) to
prove the registered command actually starts.

Usage:  python3 tools/e2e/cli_battery.py [--binary ./aubade] [--keep]
Run from the repo root.
"""

import argparse
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

GO_MAIN = '''package main

import "fmt"

type Greeter struct {
	Name string
}

func (g Greeter) Greet() string {
	return "hello " + g.Name
}

func main() {
	g := Greeter{Name: "battery"}
	fmt.Println(g.Greet())
}
'''

FAILURES = []


def run(binary, args, env, stdin=None, expect=0, marker=None,
        marker_stream="stdout", timeout=180, cwd=None):
    """Runs one CLI invocation and asserts exit code + marker."""
    label = " ".join(args)
    try:
        # errors="replace": a battery must fail loudly on bad exit codes
        # and markers, never crash decoding a binary's stray bytes
        p = subprocess.run([binary] + args, capture_output=True, text=True,
                           encoding="utf-8", errors="replace",
                           env=env, input=stdin, timeout=timeout, cwd=cwd)
    except subprocess.TimeoutExpired:
        fail(label, f"timeout after {timeout}s")
        return None
    stream = p.stdout if marker_stream == "stdout" else p.stderr
    if p.returncode != expect:
        fail(label, f"exit {p.returncode} (expected {expect})\n"
                    f"  stdout: {p.stdout[-400:]}\n  stderr: {p.stderr[-400:]}")
        return p
    if marker is not None and marker not in stream:
        fail(label, f"marker {marker!r} missing from {marker_stream}\n"
                    f"  stdout: {p.stdout[-400:]}\n  stderr: {p.stderr[-400:]}")
        return p
    print(f"  PASS {' '.join(args[:3])}{' …' if len(args) > 3 else ''}"
          f" (exit {p.returncode})", flush=True)
    return p


def fail(label, detail):
    FAILURES.append((label, detail))
    print(f"  FAIL {label}: {detail}", flush=True)


def boot_opencode_entry(cfg_path, project_dir, env):
    """Boots the command array `setup opencode` registered, the way the
    client would: cwd=project, stdio MCP, one initialize round-trip. An
    entry that dies at startup (missing flags, bad path) is a setup bug —
    this guard exists because a flag-less command array once shipped and
    only failed at the client."""
    entry = json.loads(cfg_path.read_text())["mcp"]["aubade"]
    cmd = entry.get("command")
    if not isinstance(cmd, list) or not cmd:
        fail("boot opencode entry", f"no command array in {cfg_path}")
        return
    req = (json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"protocolVersion": "2025-11-25",
                                  "capabilities": {},
                                  "clientInfo": {"name": "cli-battery",
                                                 "version": "0"}}})
           + "\n").encode()
    p = subprocess.Popen(cmd, cwd=str(project_dir), env=env,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    try:
        p.stdin.write(req)
        p.stdin.flush()
        ready, _, _ = select.select([p.stdout], [], [], 60)
        if not ready:
            fail("boot opencode entry",
                 f"no initialize response within 60s (command {cmd})")
            return
        line = p.stdout.readline()
        if b"serverInfo" not in line:
            try:
                p.stdin.close()
                err = p.stderr.read()[:400]
            except OSError:
                err = b""
            fail("boot opencode entry",
                 f"registered command {cmd} did not answer initialize: "
                 f"rc={p.poll()} out={line[:200]!r} err={err!r}")
            return
        print("  PASS boot opencode entry … (initialize answered)",
              flush=True)
    finally:
        try:
            p.stdin.close()
        except OSError:
            pass
        try:
            p.terminate()
            p.wait(timeout=15)
        except (subprocess.TimeoutExpired, OSError):
            p.kill()
            p.wait()


def child_pids_of(pid):
    """Direct children of a pid via /proc (PPid scan)."""
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            status = open(f"/proc/{entry}/status").read()
        except OSError:
            continue
        for line in status.splitlines():
            if line.startswith("PPid:"):
                if int(line.split()[1]) == pid:
                    out.append(int(entry))
                break
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=str(REPO_ROOT / "aubade"))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    binary = os.path.abspath(args.binary)

    tmp = Path(tempfile.mkdtemp(prefix="aubade-cli-battery-"))
    home = tmp / "home"            # AUBADE_HOME
    fakehome = tmp / "fakehome"    # redirected HOME for the setup legs
    proj = tmp / "proj"
    for d in (home, fakehome, proj):
        d.mkdir()

    base_env = dict(os.environ)
    base_env["AUBADE_HOME"] = str(home)
    base_env["EDITOR"] = "/usr/bin/true"
    base_env["PATH"] = (str(Path.home() / "go" / "bin") + ":"
                        + "/usr/local/go/bin:" + base_env.get("PATH", ""))

    try:
        (proj / "main.go").write_text(GO_MAIN)
        (proj / "go.mod").write_text("module battery\n\ngo 1.22\n")
        (proj / "vendor").mkdir()
        (proj / "vendor" / "note.txt").write_text("ignored\n")

        # --- standalone families ------------------------------------------
        print("== about / version / help ==", flush=True)
        p = run(binary, ["--version"], base_env, marker="aubade")
        run(binary, ["--help"], base_env, marker="global flags:")
        run(binary, ["about"], base_env, marker="Vendored components:")

        # --- init + config -------------------------------------------------
        print("== init / config ==", flush=True)
        run(binary, ["init"], base_env,
            marker="initialised successfully")
        run(binary, ["init"], base_env, expect=1, marker="already exists",
            marker_stream="stderr")
        run(binary, ["config", "edit"], base_env)

        # --- context / mode / prompt overrides ----------------------------
        print("== context / mode / prompt ==", flush=True)
        run(binary, ["context", "list"], base_env)
        run(binary, ["context", "create", "battery-ctx"], base_env,
            marker="Created context")
        run(binary, ["context", "list"], base_env, marker="battery-ctx")
        run(binary, ["context", "edit", "battery-ctx"], base_env)
        run(binary, ["context", "delete", "battery-ctx"], base_env,
            marker="Deleted custom context")
        run(binary, ["context", "delete", "battery-ctx"], base_env, expect=1)

        run(binary, ["mode", "create", "battery-mode"], base_env,
            marker="Created mode")
        run(binary, ["mode", "list"], base_env, marker="battery-mode")
        run(binary, ["mode", "delete", "battery-mode"], base_env,
            marker="Deleted custom mode")

        run(binary, ["prompt", "list"], base_env, marker="Prompts:")
        run(binary, ["prompt", "show", "system_prompt"], base_env,
            marker="Aubade")
        run(binary, ["prompt", "override", "create", "battery-tmpl"], base_env,
            marker="Created override")
        run(binary, ["prompt", "override", "list"], base_env,
            marker="battery-tmpl")
        run(binary, ["prompt", "override", "delete", "battery-tmpl"], base_env,
            marker="Deleted override file")
        run(binary, ["prompt", "override", "delete", "battery-tmpl"], base_env,
            expect=1)

        # --- project family ------------------------------------------------
        print("== project ==", flush=True)
        run(binary, ["project", "create", str(proj), "--name", "battery"],
            base_env, marker="Generated project")
        run(binary, ["project", "create", str(proj)], base_env, expect=2,
            marker="already exists", marker_stream="stderr")
        run(binary, ["project", "list"], base_env, marker="battery")
        # before the ignore rule exists, nothing is ignored — the probed
        # name must NOT be in the built-in ignore list, or the "IS ignored"
        # phase below would pass without any config consumption
        run(binary, ["project", "check-ignore", "generated/note.txt",
                     "--project", str(proj)], base_env, marker="IS NOT ignored")
        run(binary, ["project", "check-ignore", "main.go",
                     "--project", str(proj)], base_env, marker="IS NOT ignored")
        # add an ignore rule and re-check both directions (the generated
        # file is a commented JSONC template whose keys are commented
        # out — replace it wholesale with the equivalent plain JSON)
        cfg_path = proj / ".aubade" / "project.jsonc"
        cfg_path.write_text(json.dumps({
            "project_name": "battery",
            "language_servers": [{"name": "go"}],
            "ignored_paths": ["generated"],
        }, indent=2) + "\n")
        run(binary, ["project", "check-ignore", "generated/note.txt",
                     "--project", str(proj)], base_env, marker="IS ignored")
        run(binary, ["project", "check-ignore", "main.go",
                     "--project", str(proj)], base_env, marker="IS NOT ignored")

        # --- tool / prompt render -----------------------------------------
        print("== tool / prompt render ==", flush=True)
        run(binary, ["tool", "list", "--project", str(proj)], base_env,
            marker="tools visible")
        run(binary, ["tool", "show", "symbol_find", "--project", str(proj)],
            base_env, marker="caps:")
        run(binary, ["prompt", "render", str(proj)], base_env,
            marker="symbolic tools")

        # --- memory family ---------------------------------------------------
        print("== memory ==", flush=True)
        run(binary, ["memory", "write", "battery/mem", "--content",
                     "battery note", "--project", str(proj)], base_env,
            marker="written")
        run(binary, ["memory", "list", "--project", str(proj)], base_env,
            marker="battery/mem")
        run(binary, ["memory", "show", "battery/mem", "--project", str(proj)],
            base_env, marker="battery note")
        run(binary, ["memory", "write", "battery/dangling", "--content",
                     "see mem:no_such_memory", "--project", str(proj)],
            base_env, marker="written")
        run(binary, ["memory", "check", "--project", str(proj)], base_env,
            expect=1, marker="references unknown memory")
        run(binary, ["memory", "fix-references", "--dry-run",
                     "--project", str(proj)], base_env)

        # --- tracker (empty DB) ----------------------------------------------
        print("== tracker ==", flush=True)
        run(binary, ["tracker", "list", "--project", str(proj)], base_env,
            marker="0 incidents")
        out_file = tmp / "report.tsv"
        run(binary, ["tracker", "report", "--format", "tsv", "--output",
                     str(out_file), "--project", str(proj)], base_env)
        if not out_file.exists() or out_file.stat().st_size == 0:
            fail("tracker report", "output file missing or empty")

        # --- daemon-spawning legs --------------------------------------------
        print("== index / doctor / daemon / export ==", flush=True)
        run(binary, ["project", "index", "--project", str(proj)], base_env,
            marker="Indexed", timeout=300)
        run(binary, ["project", "doctor", "--project", str(proj)], base_env,
            marker="Health check passed", timeout=300)
        run(binary, ["daemon", "status", "--project", str(proj)], base_env,
            marker="daemon running")
        run(binary, ["tracker", "export", "--project", str(proj)], base_env,
            marker="Exported")

        # --- hook family (stdin JSON) ----------------------------------------
        print("== hook ==", flush=True)
        activate = json.dumps({"session_id": "e2e-activate"})
        run(binary, ["hook", "activate"], base_env, stdin=activate,
            marker="SessionStart")
        run(binary, ["hook", "activate"], base_env, stdin="", expect=1,
            marker="parsing hook input JSON", marker_stream="stderr")
        run(binary, ["hook", "activate"], base_env,
            stdin=json.dumps({"tool_name": "x"}), expect=1,
            marker="session ID", marker_stream="stderr")
        # remind denies the tool use that crosses the grep threshold (3),
        # resets the counter, and stays quiet on the next call
        remind = json.dumps({"session_id": "e2e-remind", "tool_name": "grep"})
        for _ in range(2):
            run(binary, ["hook", "remind"], base_env, stdin=remind)
        p = run(binary, ["hook", "remind"], base_env, stdin=remind)
        if p is not None:
            body = p.stdout + p.stderr
            if 'permissionDecision":"deny' not in body:
                fail("hook remind (3rd use)",
                     f"expected the deny decision, got: {body[:200]}")
            else:
                print("  PASS hook remind … (denied on 3rd use)", flush=True)
        p = run(binary, ["hook", "remind"], base_env, stdin=remind)
        if p is not None and 'permissionDecision":"deny' in p.stdout:
            fail("hook remind (post-deny)",
                 "counter must reset after a deny")
        auto = json.dumps({"session_id": "e2e-auto",
                           "tool_name": "mcp__aubade__file_read",
                           "permission_mode": "acceptEdits"})
        run(binary, ["hook", "auto-approve"], base_env, stdin=auto)
        run(binary, ["hook", "cleanup"], base_env,
            stdin=json.dumps({"session_id": "e2e-remind"}))

        # --- setup (redirected HOME) -----------------------------------------
        print("== setup (redirected HOME) ==", flush=True)
        setup_env = dict(base_env)
        setup_env["HOME"] = str(fakehome)
        run(binary, ["setup", "zcode"], setup_env, timeout=300)
        zcode_cfg = fakehome / ".zcode" / "cli" / "config.json"
        if not zcode_cfg.exists():
            fail("setup zcode", f"{zcode_cfg} was not created")
        else:
            print("  PASS setup zcode … (config written)", flush=True)
        if shutil.which("opencode") is None:
            print("  SKIP setup opencode … (client binary not installed)",
                  flush=True)
        else:
            # Seed the flag-less entry shape that once shipped:
            # setup must repair a stale registration, not call it
            # configured, and the repaired command must actually boot.
            oc_dir = fakehome / ".config" / "opencode"
            oc_dir.mkdir(parents=True, exist_ok=True)
            oc_cfg = oc_dir / "opencode.json"
            oc_cfg.write_text(json.dumps({
                "mcp": {"aubade": {"type": "local",
                                   "command": [str(binary), "mcp"]}},
                "theme": "dark"}))
            run(binary, ["setup", "opencode"], setup_env, timeout=300,
                marker="Updated aubade MCP server")
            if "--project-from-cwd" not in oc_cfg.read_text():
                fail("setup opencode",
                     f"stale entry was not repaired ({oc_cfg} still lacks "
                     "--project-from-cwd)")
            elif "dark" not in oc_cfg.read_text():
                fail("setup opencode", "repair dropped the sibling members")
            else:
                boot_opencode_entry(oc_cfg, proj, base_env)
                print("  PASS setup opencode … (stale entry repaired)",
                      flush=True)
        run(binary, ["setup", "zcode"], setup_env, timeout=300,
            marker="already configured")

        # --- teardown legs -----------------------------------------------------
        print("== daemon stop / project delete ==", flush=True)
        run(binary, ["daemon", "stop", "--project", str(proj)], base_env,
            marker="daemon stopped", timeout=60)
        run(binary, ["daemon", "status", "--project", str(proj)], base_env,
            expect=1)
        # the registry stores project roots; delete by path
        run(binary, ["project", "delete", str(proj)], base_env,
            marker="removed")
        run(binary, ["project", "delete", str(proj)], base_env, expect=1)
    finally:
        # Any daemon still holding the temp home gets swept by binary+path.
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
                    os.kill(int(pid), 15)
                except OSError:
                    pass
        time.sleep(2)
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"fixture kept at {tmp}", flush=True)

    if FAILURES:
        print(f"\nCLI BATTERY: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nCLI BATTERY: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
