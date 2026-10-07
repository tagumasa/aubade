#!/usr/bin/env python3
"""LSP-server E2E for the aubade binary. One `aubade lsp` child over
Content-Length stdio against a throwaway Go fixture with an isolated
AUBADE_HOME; the installed binary, client registrations, and the live
~/.aubade are never touched. The project resolves from the initialize
rootUri — the child's cwd is parked at the repo root on purpose.
A deterministic python "language server" (no gopls anywhere) is wired in
through language_server_commands (sys.executable, so the wiring survives
hosts without a "python3" on PATH) so LS readiness is not machine-dependent.

Verified behaviors:
1. initialize over stdio LSP: serverInfo (aubade + version), positionEncoding
   utf-8 chosen from a ["utf-16", "utf-8"] offer and reported inside
   capabilities (LSP 3.17 ServerCapabilities.positionEncoding), and the
   static capabilities — textDocumentSync Full(1) with openClose and save,
   semanticTokensProvider with a non-empty legend, documentSymbolProvider.
2. semanticTokens/full on an open go document: non-empty data, a multiple of
   5, non-negative deltas, every reconstructed (line, col) inside the
   document, token types inside the legend (pipeline shape, not content).
3. documentSymbol answers hierarchical DocumentSymbol[] (the client declared
   hierarchicalDocumentSymbolSupport): Greeter present with a range, a
   selectionRange, and children.
4. The broken file (bash, whose language_server_commands entry points at a
   nonexistent binary — the start fails on every machine) publishes >= 1
   tree-sitter syntax diagnostic with an in-document range inside the
   debounce window (the static face answers before any language server
   exists).
5. The fake LS starts out-of-band on the go didOpen, and the child
   dynamic-registers the go relay batch over client/registerCapability:
   definition, references + declaration (the fake declared both providers),
   formatting, codeAction, inlayHint, prepareCallHierarchy — ids
   aubade.relay.go.*, each with a {language: go} documentSelector.
6. textDocument/definition at the Greeter identifier answers one location in
   the same file whose range covers the definition (the documentSymbol ->
   symbol-face relay, headless).
7. After readiness a didChange degrades to a didOpen on the now-live fake
   (the next-change recovery), whose pushed diagnostic surfaces through the
   relayed publishDiagnostics for the clean file under the view's uri and
   version (live-server diagnostics replace the tree-sitter answer).
8. shutdown answers null, exit terminates the process with code 0 within a
   deadline; teardown sweeps the throwaway project's daemon and fake server,
   and deletes the temp tree.

URI comparisons go through same_doc(): the server renders document uris
against the daemon's symlink-resolved root, which on macOS differs from the
client's spelling (/var -> /private/var).

Usage:  python3 tools/e2e/lspserver_e2e.py [--binary ./aubade] [--keep]
Run from the repo root.
"""

import argparse
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

# Cribbed from lsp_e2e.py: type + method + main. Line 4 (0-based) holds the
# Greeter identifier at byte column 5 — the definition relay's target; line
# 13 holds a usage of the type.
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

# A missing `fi`: the tree-sitter walk (ERROR/MISSING nodes) must report it.
# The language is bash with a language_server_commands entry pointing at a
# nonexistent binary — the start fails identically on every machine, so the
# publish pass never sees a live server and the syntax answer is
# deterministic (a real bash LS on the host cannot interfere).
SH_BROKEN = '''#!/bin/sh
if [ -n "$AU" ]; then
    echo oops
'''

# A minimal push-diagnostics LSP, based on langserver_e2e.py's proven
# wire-compatible fake. Extended initialize answer: referencesProvider and
# declarationProvider — the daemon's handshake reads both spellings
# (src/lsp/handshake.odin) and the child's registration batch turns them
# into the references/declaration registrations. Every didOpen gets one
# pushed error (source "fake") — the deterministic relay-diagnostic payload.
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
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {
            "textDocumentSync": 1,
            "referencesProvider": True,
            "declarationProvider": True,
        }}})
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

# The registration batch lsp_relay_batch issues for a Ready language whose
# server declared both position providers (src/session/lsp_run.odin):
# definition always, references/declaration behind the server's capability
# bits, and the four langserver faces unconditionally — 7 registrations.
EXPECTED_REGS = {
    "aubade.relay.go.definition": "textDocument/definition",
    "aubade.relay.go.references": "textDocument/references",
    "aubade.relay.go.declaration": "textDocument/declaration",
    "aubade.relay.go.formatting": "textDocument/formatting",
    "aubade.relay.go.codeAction": "textDocument/codeAction",
    "aubade.relay.go.inlayHint": "textDocument/inlayHint",
    "aubade.relay.go.prepareCallHierarchy": "textDocument/prepareCallHierarchy",
}

FAILURES = []


def fail(check, detail):
    FAILURES.append(check)
    print(f"  FAIL {check}: {detail}", flush=True)


def ok(check):
    print(f"  PASS {check}", flush=True)


def doc_path(uri):
    """The filesystem path a file:// uri spells."""
    return unquote(urlparse(uri).path)


def same_doc(a, b):
    """Two spellings name the same document (the server renders uris against
    the daemon's symlink-resolved root; the client's spelling may differ)."""
    return os.path.realpath(doc_path(a)) == os.path.realpath(doc_path(b))


def wait_for(pred, timeout):
    """Polls pred() until it returns a truthy value or the deadline passes."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = pred()
        if found:
            return found
        time.sleep(0.05)
    return None


class LspConn:
    """One stdio LSP connection: Content-Length framing, a reader thread
    that answers server->client requests with a null result and collects
    notifications, and per-id queues for our own requests."""

    def __init__(self, proc):
        self.proc = proc
        self.next_id = 0
        self.pending = {}
        self.notifications = []
        self.server_requests = []
        self.lock = threading.Lock()
        self.wlock = threading.Lock()
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def send(self, msg):
        data = json.dumps(msg).encode("utf-8")
        with self.wlock:
            self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
            self.proc.stdin.flush()

    def _read_loop(self):
        f = self.proc.stdout
        while True:
            length = None
            while True:
                line = f.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                k, _, v = line.partition(b":")
                if k.strip().lower() == b"content-length":
                    length = int(v.strip() or b"0")
            if length is None:
                continue
            body = f.read(length)
            if len(body) < length:
                return
            try:
                msg = json.loads(body.decode("utf-8", "replace"))
            except json.JSONDecodeError:
                continue
            self._dispatch(msg)

    def _dispatch(self, msg):
        if "method" in msg:
            if "id" in msg:
                with self.lock:
                    self.server_requests.append(msg)
                self.send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
            else:
                with self.lock:
                    self.notifications.append(msg)
        elif "id" in msg:
            q = self.pending.pop(msg["id"], None)
            if q is not None:
                q.put(msg)

    def request(self, method, params=None, timeout=30.0):
        with self.lock:
            self.next_id += 1
            rid = self.next_id
        q = queue.Queue()
        self.pending[rid] = q
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        try:
            return q.get(timeout=timeout)
        except queue.Empty:
            raise SystemExit(f"timeout waiting for {method} id={rid}")
        finally:
            self.pending.pop(rid, None)

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)

    def publications(self, uri=None):
        with self.lock:
            pubs = [n for n in self.notifications
                    if n.get("method") == "textDocument/publishDiagnostics"]
        if uri is not None:
            pubs = [p for p in pubs
                    if same_doc(p.get("params", {}).get("uri", ""), uri)]
        return pubs

    def registrations(self):
        with self.lock:
            return [m for m in self.server_requests
                    if m.get("method") == "client/registerCapability"]


def check_initialize(init):
    result = init.get("result")
    if not isinstance(result, dict):
        fail("initialize", f"no result object: {init}")
        return None
    info = result.get("serverInfo", {})
    if info.get("name") != "aubade" or not info.get("version"):
        fail("initialize serverInfo", f"{info}")
    else:
        ok(f"initialize (server {info.get('name')} {info.get('version')})")

    # Utf-8 offered, utf-8 chosen. LSP 3.17 spells the choice
    # capabilities.positionEncoding (ServerCapabilities.positionEncoding).
    caps = result.get("capabilities")
    if not isinstance(caps, dict):
        fail("capabilities", f"missing: {result}")
        return None
    enc = caps.get("positionEncoding")
    if enc != "utf-8":
        fail("positionEncoding", f"want utf-8 inside capabilities, got {enc!r}")
    else:
        ok("positionEncoding negotiated to utf-8 (inside capabilities)")

    sync = caps.get("textDocumentSync")
    if (not isinstance(sync, dict) or sync.get("change") != 1
            or sync.get("openClose") is not True or "save" not in sync):
        fail("textDocumentSync", f"want Full(1)+openClose+save, got {sync}")
    else:
        ok("textDocumentSync is Full(1) with openClose and save")

    tokens = caps.get("semanticTokensProvider")
    legend = (tokens or {}).get("legend", {})
    types = legend.get("tokenTypes", [])
    mods = legend.get("tokenModifiers", [])
    if (not isinstance(tokens, dict) or tokens.get("full") is not True
            or not types or not mods):
        fail("semanticTokensProvider",
             f"want full + non-empty legend, got types={len(types)} "
             f"mods={len(mods)}")
    else:
        ok(f"semanticTokensProvider with a legend "
           f"({len(types)} types, {len(mods)} modifiers)")

    if caps.get("documentSymbolProvider") is not True:
        fail("documentSymbolProvider", f"{caps.get('documentSymbolProvider')}")
    else:
        ok("documentSymbolProvider advertised")
    return {"types": types}


def check_semantic_tokens(conn, clean_uri, legend):
    resp = conn.request("textDocument/semanticTokens/full",
                        {"textDocument": {"uri": clean_uri}})
    if "error" in resp:
        fail("semanticTokens/full", f"error response: {resp['error']}")
        return
    data = (resp.get("result") or {}).get("data")
    if not isinstance(data, list) or not data or len(data) % 5 != 0:
        fail("semanticTokens data", f"want non-empty multiple of 5, got "
             f"{len(data) if isinstance(data, list) else data}")
        return
    lines = GO_MAIN.split("\n")
    line = col = 0
    for i in range(0, len(data), 5):
        dl, dc, ln, tt, _mods = data[i:i + 5]
        if dl < 0 or dc < 0 or ln < 0:
            fail("semanticTokens deltas", f"negative at token {i // 5}: {data[i:i + 5]}")
            return
        line += dl
        col = dc if dl > 0 else col + dc
        if not (0 <= line < len(lines)) or col > len(lines[line]):
            fail("semanticTokens positions",
                 f"token {i // 5} lands at ({line},{col}) outside the document")
            return
        if not (0 <= tt < len(legend["types"])):
            fail("semanticTokens legend index", f"type {tt} outside the legend")
            return
    ok(f"semanticTokens/full decoded {len(data) // 5} tokens, "
       f"all inside the document")


def find_symbol(symbols, name):
    for s in symbols:
        if not isinstance(s, dict):
            continue
        if s.get("name") == name:
            return s
        hit = find_symbol(s.get("children", []), name)
        if hit is not None:
            return hit
    return None


def check_document_symbol(conn, clean_uri):
    resp = conn.request("textDocument/documentSymbol",
                        {"textDocument": {"uri": clean_uri}})
    if "error" in resp:
        fail("documentSymbol", f"error response: {resp['error']}")
        return
    syms = resp.get("result")
    if not isinstance(syms, list) or not syms:
        fail("documentSymbol", f"want a non-empty DocumentSymbol[], got {syms}")
        return
    greeter = find_symbol(syms, "Greeter")
    if greeter is None:
        fail("documentSymbol", f"no Greeter in: {[s.get('name') for s in syms]}")
        return
    if "range" not in greeter or "selectionRange" not in greeter:
        fail("documentSymbol Greeter", f"missing ranges: {greeter}")
        return
    if "children" not in greeter:
        fail("documentSymbol Greeter", f"no children: {greeter}")
        return
    ok(f"documentSymbol answered hierarchical symbols "
       f"({len(syms)} roots; Greeter with children and ranges)")


def check_registration_batch(conn, timeout=30.0):
    def batch_ready():
        for req in conn.registrations():
            regs = (req.get("params") or {}).get("registrations") or []
            ids = {e.get("id") for e in regs}
            if EXPECTED_REGS.keys() == ids:
                return regs
        return None

    regs = wait_for(batch_ready, timeout)
    if regs is None:
        reqs = conn.registrations()
        seen = [[e.get("id") for e in (r.get("params") or {}).get("registrations") or []]
                for r in reqs]
        fail("dynamic registration",
             f"never saw the full go batch in one request; "
             f"{len(reqs)} request(s): {seen}")
        return
    for e in regs:
        want_method = EXPECTED_REGS.get(e.get("id"))
        selector = ((e.get("registerOptions") or {}).get("documentSelector"))
        if e.get("method") != want_method:
            fail("dynamic registration", f"{e.get('id')}: method "
                 f"{e.get('method')} != {want_method}")
            return
        if selector != [{"language": "go"}]:
            fail("dynamic registration", f"{e.get('id')}: selector {selector}")
            return
    ok(f"registered the go relay batch ({len(regs)} registrations, "
       f"ids aubade.relay.go.*)")


def check_definition(conn, clean_uri):
    # The relay resolves the position through the document outline; the
    # Greeter identifier's own position (line 4, byte column 5 under the
    # utf-8 connection) is the outline-grounded hit.
    resp = conn.request("textDocument/definition", {
        "textDocument": {"uri": clean_uri},
        "position": {"line": 4, "character": 5},
    })
    if "error" in resp:
        fail("definition relay", f"error response: {resp['error']}")
        return
    locs = resp.get("result")
    if not isinstance(locs, list) or len(locs) != 1:
        fail("definition relay", f"want one location, got {locs}")
        return
    loc = locs[0]
    rng = loc.get("range", {})
    start, end = rng.get("start", {}), rng.get("end", {})
    sl = int(start.get("line", 10 ** 9))
    sc = int(start.get("character", 10 ** 9))
    el = int(end.get("line", -(10 ** 9)))
    ec = int(end.get("character", -(10 ** 9)))
    if not same_doc(loc.get("uri", ""), clean_uri):
        fail("definition relay", f"uri {loc.get('uri')} != {clean_uri}")
        return
    # The range must cover the definition identifier (4,5)..(4,12):
    # inclusive start, exclusive end — the relay's own containment rule.
    if (sl, sc) > (4, 5) or (el, ec) <= (4, 5):
        fail("definition relay",
             f"range ({sl},{sc})..({el},{ec}) does not cover the Greeter identifier")
        return
    ok(f"definition relayed to the Greeter definition "
       f"({sl},{sc})..({el},{ec})")


def check_broken_publish(conn, broken_uri, timeout=15.0):
    def first_nonempty():
        for p in conn.publications(broken_uri):
            diags = p.get("params", {}).get("diagnostics") or []
            if diags:
                return p
        return None

    pub = wait_for(first_nonempty, timeout)
    if pub is None:
        fail("tree-sitter publish",
             f"no non-empty publication for {broken_uri} within {timeout}s")
        return
    diags = pub["params"]["diagnostics"]
    lines = SH_BROKEN.split("\n")
    d = diags[0]
    start = d.get("range", {}).get("start", {})
    ln, ch = start.get("line", -1), start.get("character", -1)
    if not (0 <= ln < len(lines)) or not (0 <= ch <= len(lines[ln])):
        fail("tree-sitter publish range",
             f"start ({ln},{ch}) outside the document")
        return
    ok(f"tree-sitter published {len(diags)} diagnostic(s) for the broken "
       f"file (first at line {ln}, severity {d.get('severity')})")


def check_fake_relay(conn, clean_uri, timeout=25.0):
    def fake_pub():
        for p in conn.publications(clean_uri):
            diags = p.get("params", {}).get("diagnostics") or []
            if any(d.get("source") == "fake" for d in diags):
                return p
        return None

    pub = wait_for(fake_pub, timeout)
    if pub is None:
        fail("diagnostics relay",
             f"the fake's pushed diagnostic never surfaced for {clean_uri}")
        return
    params = pub["params"]
    d = next(d for d in params["diagnostics"] if d.get("source") == "fake")
    if params.get("version") != 2:
        fail("diagnostics relay version",
             f"want the view's version 2, got {params.get('version')}")
        return
    if d.get("severity") != 1 or "fake:" not in (d.get("message") or ""):
        fail("diagnostics relay item", f"{d}")
        return
    ok("the fake's push surfaced through the relayed publishDiagnostics "
       f"(version {params['version']}, source {d['source']})")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=str(
        Path(__file__).resolve().parents[2]
        / ("aubade.exe" if os.name == "nt" else "aubade")))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    binary = os.path.abspath(args.binary)
    repo_root = Path(__file__).resolve().parents[2]

    tmp = Path(tempfile.mkdtemp(prefix="aubade-lspserver-e2e-"))
    home = tmp / "home"
    proj = tmp / "proj"
    (proj / ".aubade").mkdir(parents=True)
    home.mkdir()
    (proj / "main.go").write_text(GO_MAIN)
    (proj / "broken.sh").write_text(SH_BROKEN)
    (proj / "go.mod").write_text("module e2e\n\ngo 1.22\n")
    fake_ls = tmp / "fake_ls.py"
    fake_ls.write_text(FAKE_LS)
    # go -> the deterministic fake (readiness legs); bash -> a command that
    # cannot exist anywhere, so the broken file's language never goes live.
    (proj / ".aubade" / "project.jsonc").write_text(
        json.dumps({"language_server_commands": {
            "go": [sys.executable, str(fake_ls)],
            "bash": ["/nonexistent/aubade-e2e-no-ls"]}}) + "\n")

    clean_uri = (proj / "main.go").as_uri()
    broken_uri = (proj / "broken.sh").as_uri()

    env = dict(os.environ)
    env["AUBADE_HOME"] = str(home)

    # cwd is the REPO ROOT on purpose: the project must resolve from
    # the initialize rootUri, never from the working directory.
    proc = subprocess.Popen(
        [binary, "lsp"],
        cwd=str(repo_root),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=open(tmp / "stderr.log", "wb"), env=env)

    conn = LspConn(proc)

    try:
        # 1. initialize: rootUri carries the project; the client offers
        # utf-16 first (utf-8 must still win) and hierarchical symbols.
        init = conn.request("initialize", {
            "processId": os.getpid(),
            "capabilities": {
                "general": {"positionEncodings": ["utf-16", "utf-8"]},
                "textDocument": {"documentSymbol":
                                 {"hierarchicalDocumentSymbolSupport": True}},
            },
            "clientInfo": {"name": "lspserver-e2e", "version": "0"},
            "rootUri": proj.as_uri(),
        }, timeout=60.0)
        legend = check_initialize(init)
        if legend is None:
            raise SystemExit(1)
        conn.notify("initialized")

        # 2/3. the static tree-sitter face over the open clean document
        conn.notify("textDocument/didOpen", {"textDocument": {
            "uri": clean_uri, "languageId": "go", "version": 1,
            "text": GO_MAIN}})
        check_semantic_tokens(conn, clean_uri, legend)
        check_document_symbol(conn, clean_uri)

        # 4. the broken document (bash, whose LS command cannot exist): the
        # publish pass never sees a live server for it, so the tree-sitter
        # answer is deterministic regardless of the fake's progress.
        conn.notify("textDocument/didOpen", {"textDocument": {
            "uri": broken_uri, "languageId": "bash", "version": 1,
            "text": SH_BROKEN}})
        check_broken_publish(conn, broken_uri)

        # 5. the fake (started out-of-band on the go didOpen) went Ready:
        # the registration sweep must have registered the go relay batch.
        check_registration_batch(conn)

        # 6. the definition relay through the symbol face
        check_definition(conn, clean_uri)

        # 7. the mode switch: a change after readiness degrades to a
        # didOpen on the now-live fake, whose push relays back to us.
        touched = GO_MAIN + "// touched so the daemon re-opens the document\n"
        conn.notify("textDocument/didChange", {
            "textDocument": {"uri": clean_uri, "version": 2},
            "contentChanges": [{"text": touched}]})
        check_fake_relay(conn, clean_uri)

        # 8. shutdown -> null, exit -> termination
        conn.notify("textDocument/didClose", {"textDocument": {"uri": clean_uri}})
        conn.notify("textDocument/didClose", {"textDocument": {"uri": broken_uri}})
        resp = conn.request("shutdown", timeout=10.0)
        if "result" not in resp or resp["result"] is not None:
            fail("shutdown null", f"{resp}")
        else:
            ok("shutdown answered null")
        conn.notify("exit")
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            fail("exit terminates", "process still alive 15s after exit")
            proc.kill()
            proc.wait()
        if proc.returncode != 0:
            fail("exit code", f"returncode={proc.returncode} (want 0)")
        else:
            ok("exit terminated the child with code 0")
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
        # Sweep the daemon for this throwaway project, plus any fake-server
        # straggler (its exe is python, so the binary match cannot see it).
        # /proc exists only on Linux; everywhere else the daemon exits on
        # its own once every child is gone, and the rmtree retry below
        # waits it out.
        if sys.platform.startswith("linux"):
            for sig in (signal.SIGTERM, signal.SIGKILL):
                for pid in os.listdir("/proc"):
                    if not pid.isdigit():
                        continue
                    try:
                        exe = os.readlink(f"/proc/{pid}/exe")
                        cmdline = open(f"/proc/{pid}/cmdline", "rb").read().decode(
                            "utf-8", "replace")
                    except OSError:
                        continue
                    ours = os.path.abspath(exe) == binary and str(tmp) in cmdline
                    fake = "fake_ls.py" in cmdline and str(tmp) in cmdline
                    if ours or fake:
                        try:
                            os.kill(int(pid), sig)
                        except OSError:
                            pass
                time.sleep(2)

        if FAILURES:
            # The cleanup below deletes the temp tree, taking the child's
            # stderr with it — the most diagnostic artifact on failure — so
            # echo the head of the log before it is gone.
            try:
                log_bytes = (tmp / "stderr.log").read_bytes()
            except OSError:
                log_bytes = b""
            if log_bytes:
                print("\n--- aubade stderr (first 8 KiB) ---", flush=True)
                print(log_bytes[:8192].decode("utf-8", "replace"), end="",
                      flush=True)
                if len(log_bytes) > 8192:
                    print(f"\n... truncated ({len(log_bytes)} bytes total)",
                          flush=True)
                print("--- end stderr ---", flush=True)

        if not args.keep:
            # A daemon that is still tearing down can hold files open for a
            # few seconds; retry instead of leaving the temp tree behind.
            for _ in range(10):
                try:
                    shutil.rmtree(tmp)
                    break
                except OSError:
                    time.sleep(1)
            if tmp.exists():
                print(f"warning: could not remove {tmp}", flush=True)
        else:
            print(f"fixture kept at {tmp}", flush=True)

    if FAILURES:
        print(f"\nLSP SERVER E2E: {len(FAILURES)} FAILURES", flush=True)
        return 1
    print("\nLSP SERVER E2E: ALL PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
