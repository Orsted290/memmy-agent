/** Codex hook trust tests. */
import { chmodSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveCodexExecutable, trustMemmyCodexHooks } from "../hook-trust.js";

let tempDir: string | undefined;

afterEach(() => {
  if (tempDir) {
    rmSync(tempDir, { recursive: true, force: true });
    tempDir = undefined;
  }
  vi.unstubAllEnvs();
});

describe("Codex hook trust", () => {
  it("persists and verifies trust for only the five Memmy user hooks", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "memmy-codex-hook-trust-"));

    await expect(trustMemmyCodexHooks({
      codexHomeDirectory: tempDir,
      hooksFilePath: join(tempDir, "hooks.json"),
      hookCommand: `node '${join(tempDir, "hooks", "memmy-resume-hook.mjs")}'`,
      codexExecutable: process.execPath,
      appServerArguments: ["-e", FAKE_CODEX_APP_SERVER]
    })).resolves.toBeUndefined();
  });

  it("rejects success when Codex does not discover every Memmy hook", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "memmy-codex-hook-trust-missing-"));

    await expect(trustMemmyCodexHooks({
      codexHomeDirectory: tempDir,
      hooksFilePath: join(tempDir, "hooks.json"),
      hookCommand: `node '${join(tempDir, "hooks", "memmy-resume-hook.mjs")}'`,
      codexExecutable: process.execPath,
      appServerArguments: ["-e", FAKE_CODEX_APP_SERVER, "missing-stop"]
    })).rejects.toThrow("Codex did not discover every installed Memmy hook");
  });
});

describe("Codex executable resolution", () => {
  it("uses an explicit CODEX_CLI_PATH before the other Windows candidates", () => {
    const context = createResolverContext();
    const explicitPath = createExecutable(join(context.tempDir, "custom-cli", "codex.exe"));
    createExecutable(join(context.codexHomeDirectory, "plugins", ".plugin-appserver", "codex.exe"));
    vi.stubEnv("CODEX_CLI_PATH", `"${explicitPath}"`);

    const resolution = runAsWindows(() =>
      resolveCodexExecutable(context.codexHomeDirectory, context.defaultHomeDirectory)
    );

    expect(resolution.command).toBe(explicitPath);
    expect(resolution.checkedPaths).toEqual([explicitPath]);
    expect(resolution.searchedPathFallback).toBe(false);
  });

  it("finds the standalone CLI under the configured CODEX_HOME", () => {
    const context = createResolverContext();
    const standalonePath = createExecutable(join(
      context.codexHomeDirectory,
      "packages",
      "standalone",
      "current",
      "bin",
      "codex.exe"
    ));

    const resolution = runAsWindows(() =>
      resolveCodexExecutable(context.codexHomeDirectory, context.defaultHomeDirectory)
    );

    expect(resolution.command).toBe(standalonePath);
    expect(resolution.searchedPathFallback).toBe(false);
  });

  it("uses CODEX_INSTALL_DIR as the visible bin directory", () => {
    const context = createResolverContext();
    const installDirectory = join(context.tempDir, "codex-install-bin");
    const installPath = createExecutable(join(installDirectory, "codex.exe"));
    vi.stubEnv("CODEX_INSTALL_DIR", installDirectory);

    const resolution = runAsWindows(() =>
      resolveCodexExecutable(context.codexHomeDirectory, context.defaultHomeDirectory)
    );

    expect(resolution.command).toBe(installPath);
    expect(resolution.searchedPathFallback).toBe(false);
  });

  it("finds the newest versioned Codex desktop runtime", () => {
    const context = createResolverContext();
    const runtimeBinDirectory = join(context.localAppData, "OpenAI", "Codex", "bin");
    const olderPath = createExecutable(join(runtimeBinDirectory, "version-old", "codex.exe"));
    const newerPath = createExecutable(join(runtimeBinDirectory, "version-new", "codex.exe"));
    const oldDate = new Date("2020-01-01T00:00:00Z");
    const newDate = new Date("2021-01-01T00:00:00Z");
    utimesSync(olderPath, oldDate, oldDate);
    utimesSync(newerPath, newDate, newDate);

    const resolution = runAsWindows(() =>
      resolveCodexExecutable(context.codexHomeDirectory, context.defaultHomeDirectory)
    );

    expect(resolution.command).toBe(newerPath);
    expect(resolution.searchedPathFallback).toBe(false);
  });

  it("returns codex.exe PATH fallback when no Windows candidate exists", () => {
    const context = createResolverContext();

    const resolution = runAsWindows(() =>
      resolveCodexExecutable(context.codexHomeDirectory, context.defaultHomeDirectory)
    );

    expect(resolution.command).toBe("codex.exe");
    expect(resolution.checkedPaths.length).toBeGreaterThan(0);
    expect(resolution.searchedPathFallback).toBe(true);
  });
});

interface CodexResolverContext {
  tempDir: string;
  codexHomeDirectory: string;
  defaultHomeDirectory: string;
  localAppData: string;
}

function createResolverContext(): CodexResolverContext {
  tempDir = mkdtempSync(join(tmpdir(), "memmy-codex-executable-resolution-"));
  const context = {
    tempDir,
    codexHomeDirectory: join(tempDir, "custom-codex-home"),
    defaultHomeDirectory: join(tempDir, "default-user-home"),
    localAppData: join(tempDir, "local-app-data")
  };
  vi.stubEnv("CODEX_CLI_PATH", "");
  vi.stubEnv("CODEX_INSTALL_DIR", "");
  vi.stubEnv("LOCALAPPDATA", context.localAppData);
  return context;
}

function createExecutable(filePath: string): string {
  mkdirSync(dirname(filePath), { recursive: true });
  writeFileSync(filePath, "simulated codex executable");
  chmodSync(filePath, 0o755);
  return filePath;
}

function runAsWindows<T>(callback: () => T): T {
  const platformDescriptor = Object.getOwnPropertyDescriptor(process, "platform");
  if (!platformDescriptor) {
    throw new Error("Unable to inspect process.platform descriptor");
  }
  Object.defineProperty(process, "platform", { ...platformDescriptor, value: "win32" });
  try {
    return callback();
  } finally {
    Object.defineProperty(process, "platform", platformDescriptor);
  }
}

const FAKE_CODEX_APP_SERVER = String.raw`
const readline = require("node:readline");
const path = require("node:path");
const home = process.env.CODEX_HOME;
const sourcePath = path.join(home, "hooks.json");
const scriptPath = path.join(home, "hooks", "memmy-resume-hook.mjs");
const missingStop = process.argv.includes("missing-stop");
let trusted = false;
const hook = (key, eventName, hash, command = "node '" + scriptPath + "'") => ({
  key,
  eventName,
  handlerType: "command",
  command,
  source: "user",
  sourcePath,
  currentHash: hash,
  trustStatus: trusted ? "trusted" : "untrusted",
  enabled: trusted,
  isManaged: false
});
const hooks = () => [
  hook(sourcePath + ":user_prompt_submit:0:0", "userPromptSubmit", "sha256:prompt"),
  ...(missingStop ? [] : [hook(sourcePath + ":stop:0:0", "stop", "sha256:stop")]),
  hook(sourcePath + ":session_start:0:0", "sessionStart", "sha256:session-start"),
  hook(sourcePath + ":post_compact:0:0", "postCompact", "sha256:post-compact"),
  hook(sourcePath + ":session_end:0:0", "sessionEnd", "sha256:session-end"),
  hook(sourcePath + ":pre_tool_use:0:0", "preToolUse", "sha256:unrelated", "node '/tmp/unrelated.mjs'")
];
const respond = (id, result) => process.stdout.write(JSON.stringify({ id, result }) + "\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    respond(message.id, { userAgent: "fake" });
    return;
  }
  if (message.method === "hooks/list") {
    respond(message.id, { data: [{ cwd: home, hooks: hooks(), warnings: [], errors: [] }] });
    return;
  }
  if (message.method === "config/batchWrite") {
    const edit = message.params.edits[0];
    const keys = Object.keys(edit.value).sort();
    const expected = [
      sourcePath + ":stop:0:0",
      sourcePath + ":user_prompt_submit:0:0",
      sourcePath + ":session_start:0:0",
      sourcePath + ":post_compact:0:0",
      sourcePath + ":session_end:0:0"
    ].sort();
    const valid = edit.keyPath === "hooks.state" &&
      edit.mergeStrategy === "upsert" &&
      message.params.reloadUserConfig === true &&
      JSON.stringify(keys) === JSON.stringify(expected) &&
      edit.value[expected[0]].enabled === true &&
      edit.value[expected[1]].enabled === true &&
      new Set(keys.map((key) => edit.value[key].trusted_hash)).size === 5;
    if (!valid) {
      process.stdout.write(JSON.stringify({ id: message.id, error: { message: "invalid trust write" } }) + "\n");
      return;
    }
    trusted = true;
    respond(message.id, {});
  }
});
`;
