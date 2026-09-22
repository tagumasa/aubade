#!/usr/bin/env python3
"""Editing-tools E2E for the Odin aubade binary. One MCP child over stdio
against a throwaway two-file Go fixture with an isolated AUBADE_HOME; the
installed binary, client registrations, and the live ~/.aubade are never
touched. Every mutation is asserted against the file content on disk, not
against the tool's own answer text.

Verified behaviors:
1. file_write creates a new file and overwrites an existing one.
2. file_replace applies a literal replacement on disk and refuses a
   no-match needle (file unchanged, isError answer).
3. file_insert_lines / file_replace_lines / file_delete_lines apply
   0-based line surgery on disk.
4. file_move renames a file on disk (source gone, target present).
5. symbol_replace_body, symbol_insert_before/after, symbol_move
   (cross-file), symbol_delete, and the docstring trio land their
   effects on disk, in order, through the daemon's editor buffers.
6. symbol_rename rewrites the definition and the call site in main()
   (lazy-starting gopls for references), and the symbol index answers
   the new name right after the edit's save.
7. Negatives: an unknown symbol and an out-of-project path are refused
   with the tree unchanged.

Usage:  python3 tools/e2e/editing_e2e.py [--binary ./aubade] [--keep]
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

MAIN_GO = 'package main\n\nimport "fmt"\n\n// Greet returns a greeting for name.\nfunc Greet(name string) string {\n\treturn "hello " + name\n}\n\nfunc main() {\n\tfmt.Println(Greet("e2e"))\n}\n'

UTIL_GO = 'package main\n\n// Twice doubles n.\nfunc Twice(n int) int {\n\treturn n * 2\n}\n'

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

    tmp = Path(tempfile.mkdtemp(prefix="aubade-editing-e2e-"))
    home = tmp / "home"
    proj = tmp / "proj"
    home.mkdir()
    proj.mkdir()
    (proj / "main.go").write_text(MAIN_GO)
    (proj / "util.go").write_text(UTIL_GO)
    (proj / "go.mod").write_text("module e2e\n\ngo 1.22\n")
    # The line-surgery trio is optional; include it so the driver can
    # exercise it (a default session leaves optional tools out).
    (proj / ".aubade").mkdir()
    (proj / ".aubade" / "project.jsonc").write_text(
        '{"included_optional_tools": ["file_insert_lines",'
        ' "file_replace_lines", "file_delete_lines"]}\n')

    env = dict(os.environ)
    env["AUBADE_HOME"] = str(home)
    # gopls lives in ~/go/bin (symbol_rename lazy-starts it for references).
    env["PATH"] = (str(Path.home() / "go" / "bin") + ":/usr/local/go/bin:"
                   + env.get("PATH", ""))

    stderr_log = open(tmp / "stderr.log", "wb")
    proc = subprocess.Popen(
        [binary, "mcp", "--project", str(proj), "--tool-timeout", "180000"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=stderr_log, env=env, text=True,
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

    def disk(rel):
        return (proj / rel).read_text()

    def order(body, first, second):
        """True when first appears before second and both are present."""
        i, j = body.find(first), body.find(second)
        return i >= 0 and j >= 0 and i < j

    def check(cond, name, detail):
        if cond:
            ok(name)
        else:
            fail(name, detail)

    try:
        init = call("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "editing-e2e", "version": "0"},
        })
        server = init.get("result", {}).get("serverInfo", {}).get("name", "")
        check(bool(server), "initialize", f"no serverInfo: {init}")
        call("notifications/initialized", notify=True)

        # 1. file_write creates, then overwrites.
        err, text = tool("file_write", {"relative_path": "notes.md",
                                        "content": "v1\n"})
        check(not err and disk("notes.md") == "v1\n", "file_write creates",
              f"err={err} text={text[:200]} disk={disk('notes.md')!r}")
        err, text = tool("file_write", {"relative_path": "notes.md",
                                        "content": "v2\n"})
        check(not err and disk("notes.md") == "v2\n", "file_write overwrites",
              f"err={err} disk={disk('notes.md')!r}")

        # 2. file_replace hits and refuses a no-match needle.
        err, text = tool("file_replace", {"relative_path": "util.go",
                                          "needle": "n * 2", "repl": "n + n",
                                          "mode": "literal"})
        body = disk("util.go")
        check(not err and "n + n" in body and "n * 2" not in body,
              "file_replace applies", f"err={err} text={text[:200]}")
        err, text = tool("file_replace", {"relative_path": "util.go",
                                          "needle": "absent-token",
                                          "repl": "x", "mode": "literal"})
        check(err and "absent-token" not in disk("util.go"),
              "file_replace refuses no-match", f"err={err} text={text[:200]}")

        # 3. symbol_replace_body on Twice (still in util.go).
        err, text = tool("symbol_replace_body", {
            "name_path": "Twice", "relative_path": "util.go",
            "body": 'func Twice(n int) int {\n\treturn n * 3\n}'})
        body = disk("util.go")
        check(not err and "n * 3" in body and "n + n" not in body,
              "symbol_replace_body", f"err={err} text={text[:200]}")

        # 4. symbol_insert_before / insert_after around Greet.
        err, text = tool("symbol_insert_before", {
            "name_path": "Greet", "relative_path": "main.go",
            "body": 'func Before() string {\n\treturn "b"\n}'})
        body = disk("main.go")
        check(not err and order(body, "func Before", "func Greet"),
              "symbol_insert_before", f"err={err} text={text[:200]}")
        err, text = tool("symbol_insert_after", {
            "name_path": "Greet", "relative_path": "main.go",
            "body": "func After() int {\n\treturn 4\n}"})
        body = disk("main.go")
        check(not err and order(body, "func Greet", "func After")
              and order(body, "func After", "func main"),
              "symbol_insert_after", f"err={err} text={text[:200]}")

        # 5. symbol_move moves Twice across files, carrying its docstring.
        err, text = tool("symbol_move", {
            "name_path": "Twice", "source_relative_path": "util.go",
            "target_relative_path": "main.go", "target_position": "end"})
        body = disk("main.go")
        check(not err and "Twice" not in disk("util.go")
              and "func Twice" in body and "// Twice doubles n." in body,
              "symbol_move cross-file", f"err={err} text={text[:200]}")

        # 6. symbol_rename rewrites the definition and the call site
        #    (gopls lazy-starts for references); the index must answer
        #    the new name right after the edit's save.
        tool("symbol_list", {"relative_path": "main.go"})  # fill the index
        err, text = tool("symbol_rename", {"name_path": "Greet",
                                           "relative_path": "main.go",
                                           "new_name": "Salute"})
        body = disk("main.go")
        # The doc comment may keep the old spelling — rename rewrites the
        # identifier (definition and call sites), not prose.
        check(not err and "func Salute" in body and 'Salute("e2e")' in body
              and "Greet(" not in body,
              "symbol_rename rewrites call site",
              f"err={err} text={text[:300]} body:\n{body}")
        err, text = tool("symbol_find", {"name_path_pattern": "Salute"})
        check(not err and "main.go" in text,
              "index answers the new name", f"err={err} text={text[:200]}")

        # 7. docstring trio on Twice (now in main.go). Comment text is
        #    written verbatim — markers are the caller's, and marker-less
        #    text is refused.
        err, text = tool("symbol_replace_docstring", {
            "name_path": "Twice", "relative_path": "main.go",
            "comment": "// Twice triples n."})
        body = disk("main.go")
        check(not err and "// Twice triples n." in body and "doubles" not in body,
              "symbol_replace_docstring",
              f"err={err} text={text[:200]} body:\n{body}")
        err, text = tool("symbol_delete_docstring", {
            "name_path": "Twice", "relative_path": "main.go"})
        body = disk("main.go")
        check(not err and "Twice triples" not in body,
              "symbol_delete_docstring",
              f"err={err} text={text[:200]} body:\n{body}")
        err, text = tool("symbol_insert_docstring", {
            "name_path": "Twice", "relative_path": "main.go",
            "comment": "// Twice scales n."})
        body = disk("main.go")
        check(not err and order(body, "// Twice scales n.", "func Twice"),
              "symbol_insert_docstring",
              f"err={err} text={text[:200]} body:\n{body}")
        bare = disk("main.go")
        err, text = tool("symbol_insert_docstring", {
            "name_path": "Twice", "relative_path": "main.go",
            "comment": "Twice scales n."})
        check(err and disk("main.go") == bare,
              "marker-less docstring refused", f"err={err} text={text[:200]}")

        # 8. symbol_delete removes After.
        err, text = tool("symbol_delete", {"name_path_pattern": "After",
                                           "relative_path": "main.go"})
        check(not err and "func After" not in disk("main.go"),
              "symbol_delete", f"err={err} text={text[:200]}")

        # 9. negatives: unknown symbol, out-of-project path — both
        #    refused with the tree unchanged.
        before = disk("main.go")
        err, text = tool("symbol_replace_body", {
            "name_path": "NoSuchSymbol", "relative_path": "main.go",
            "body": "func NoSuch() {}"})
        check(err and disk("main.go") == before,
              "unknown symbol refused", f"err={err} text={text[:200]}")
        err, text = tool("file_replace", {"relative_path": "../outside.md",
                                          "needle": "a", "repl": "b",
                                          "mode": "literal"})
        check(err and not (tmp / "outside.md").exists(),
              "out-of-project path refused", f"err={err} text={text[:200]}")

        # 10. file_move renames on disk.
        err, text = tool("file_move", {"source_relative_path": "notes.md",
                                       "target_relative_path": "readme.md"})
        check(not err and not (proj / "notes.md").exists()
              and disk("readme.md") == "v2\n",
              "file_move", f"err={err} text={text[:200]}")

        # 11. line surgery: 0-based insert / replace / delete.
        tool("file_write", {"relative_path": "scratch.txt",
                            "content": "a\nb\nc\n"})
        err, text = tool("file_insert_lines", {"relative_path": "scratch.txt",
                                               "line": 1, "content": "X"})
        check(not err and disk("scratch.txt") == "a\nX\nb\nc\n",
              "file_insert_lines", f"err={err} disk={disk('scratch.txt')!r}")
        err, text = tool("file_replace_lines", {"relative_path": "scratch.txt",
                                                "start_line": 0, "end_line": 0,
                                                "content": "Z"})
        check(not err and disk("scratch.txt") == "Z\nX\nb\nc\n",
              "file_replace_lines", f"err={err} disk={disk('scratch.txt')!r}")
        err, text = tool("file_delete_lines", {"relative_path": "scratch.txt",
                                               "start_line": 1, "end_line": 1})
        check(not err and disk("scratch.txt") == "Z\nb\nc\n",
              "file_delete_lines", f"err={err} disk={disk('scratch.txt')!r}")
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
        print(f"\nEditing E2E: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nEditing E2E: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
