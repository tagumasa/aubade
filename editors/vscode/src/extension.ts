// Aubade for VSCode/VSCodium — a thin launcher for `aubade lsp`.
//
// One vscode-languageclient LanguageClient per workspace folder: each folder
// gets its own `aubade lsp` child, and the daemon side is project-neutral
// (one daemon per folder). The server resolves the project root from
// initialize's rootUri, so no --project/--project-from-cwd flags are passed
// and the working directory is irrelevant.
//
// VSCode-specific concerns (launch command, document selectors, settings)
// stay in this file — the LSP protocol surface belongs to the server alone.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  Middleware,
  ServerOptions,
} from "vscode-languageclient/node";

const clients = new Map<string, LanguageClient>();

function serverOptions(command: string): ServerOptions {
  return { command, args: ["lsp"] };
}

// Per-language diagnostics toggle. aubade's diagnostics coexist with those of
// dedicated language-server extensions; for a language listed in
// aubade.diagnostics.disabledLanguages every aubade publication is replaced
// with an empty set instead of duplicated squiggles. The setting resolves per
// resource, so folder-scoped overrides work.
const middleware: Middleware = {
  handleDiagnostics(uri, diagnostics, next) {
    const document = vscode.workspace.textDocuments.find(
      (d) => d.uri.toString() === uri.toString(),
    );
    if (document) {
      const disabled = vscode.workspace
        .getConfiguration("aubade", uri)
        .get<string[]>("diagnostics.disabledLanguages", []);
      if (disabled.includes(document.languageId)) {
        next(uri, []);
        return;
      }
    }
    next(uri, diagnostics);
  },
};

function clientOptions(folder: vscode.WorkspaceFolder): LanguageClientOptions {
  // A protocol RelativePattern anchored at the folder keeps each child to
  // its own folder: only documents under `folder` sync to its server. (The
  // vscode DocumentFilter has no workspaceFolder field; the client library
  // resolves this protocol form into a vscode RelativePattern for matching.)
  const documentSelector = [
    {
      scheme: "file",
      pattern: {
        baseUri: { uri: folder.uri.toString(), name: folder.name },
        pattern: "**/*",
      },
    },
  ];
  return { documentSelector, middleware };
}

// The launch command: an explicit `aubade.path` is used verbatim; the
// unset default resolves instead of trusting the editor process's PATH,
// because a GUI-launched editor often does not inherit the login shell's
// PATH (~/.local/bin), and the spawn failure surfaces only as ENOENT.
// Resolution probes the PATH entries for an executable file, then the
// documented install prefixes of scripts/build_install.sh (Linux/macOS)
// and build_install.ps1 (Windows); with no hit anywhere the bare name
// stays (the start failure then reports it with the hint below).
function isExecutableFile(candidate: string): boolean {
  try {
    fs.accessSync(candidate, fs.constants.X_OK);
    return fs.statSync(candidate).isFile();
  } catch {
    return false;
  }
}

function resolveDefaultCommand(): string {
  const names = process.platform === "win32"
    ? ["aubade.exe", "aubade.cmd", "aubade"]
    : ["aubade"];
  const pathEntries = (process.env.PATH ?? "").split(path.delimiter)
    .filter((entry) => entry !== "");
  for (const entry of pathEntries) {
    for (const name of names) {
      const candidate = path.join(entry, name);
      if (isExecutableFile(candidate)) {
        return candidate;
      }
    }
  }
  const prefixes: string[] = [];
  if (process.platform === "win32") {
    if (process.env.LOCALAPPDATA) {
      prefixes.push(
        path.join(process.env.LOCALAPPDATA, "Programs", "aubade", "aubade.exe"),
      );
    }
  } else {
    prefixes.push(path.join(os.homedir(), ".local", "bin", "aubade"));
  }
  for (const candidate of prefixes) {
    if (isExecutableFile(candidate)) {
      return candidate;
    }
  }
  return "aubade";
}

// launchCommand reports the command to spawn and whether it came from the
// resolution ladder (an explicit setting always wins and is never
// second-guessed).
function launchCommand(): { command: string; fromDefault: boolean } {
  const inspected = vscode.workspace
    .getConfiguration("aubade")
    .inspect<string>("path");
  const explicit = inspected?.globalValue ??
    inspected?.workspaceValue ?? inspected?.workspaceFolderValue;
  if (explicit !== undefined) {
    return { command: explicit, fromDefault: false };
  }
  return { command: resolveDefaultCommand(), fromDefault: true };
}

function startClient(folder: vscode.WorkspaceFolder): void {
  const key = folder.uri.toString();
  if (clients.has(key)) {
    return;
  }
  const { command, fromDefault } = launchCommand();
  const client = new LanguageClient(
    key,
    `Aubade: ${folder.name}`,
    serverOptions(command),
    clientOptions(folder),
  );
  clients.set(key, client);
  // Surface start failures: the usual cause is an unresolvable `aubade.path`,
  // and a client that never started is invisible without an explicit report.
  // An unresolved default (bare `aubade` found nowhere) additionally names
  // the two ways out: set the path or run the install script.
  void client.start().catch((err: unknown) => {
    const detail = err instanceof Error ? err.message : String(err);
    const hint = fromDefault && command === "aubade"
      ? " — no aubade executable was found; set aubade.path or install with scripts/build_install.sh"
      : "";
    void vscode.window.showErrorMessage(
      `Aubade: failed to start the language server for "${folder.name}" ` +
        `(command: ${command}): ` +
        `${detail}${hint}`,
    );
  });
}

async function stopClient(key: string): Promise<void> {
  const client = clients.get(key);
  if (!client) {
    return;
  }
  clients.delete(key);
  await client.stop();
}

export function activate(context: vscode.ExtensionContext): void {
  for (const folder of vscode.workspace.workspaceFolders ?? []) {
    startClient(folder);
  }
  context.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders((event) => {
      for (const folder of event.removed) {
        void stopClient(folder.uri.toString());
      }
      for (const folder of event.added) {
        startClient(folder);
      }
    }),
  );
}

export async function deactivate(): Promise<void> {
  const stopping = [...clients.values()].map((client) => client.stop());
  clients.clear();
  await Promise.all(stopping);
}
