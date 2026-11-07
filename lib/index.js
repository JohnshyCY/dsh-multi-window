// dsh-multi-window - Node half.
//
// Serves GET /api/multi-window.open?session=<id>&title=<text>: builds the
// Host's own authenticated URL, then spawns a separate Electron process that
// shows it in a native window. The window loads the real DSH frontend with no
// chrome removed or rewritten.
//
// The window runtime is not shipped in this package and needs no build step.
// DSH's Host runs as `ELECTRON_RUN_AS_NODE=1 <app exe>`, so dirname(process.execPath)
// already contains the whole Electron payload. The first window hard-links that
// payload into a temporary directory and writes a minimal main process into it;
// later windows reuse it.
import { spawn } from "node:child_process";
import { copyFileSync, cpSync, existsSync, linkSync, lstatSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const OPEN_PATH = "/api/multi-window.open";
export const name = "multi-window";
export const inject = ["connection"];

const here = dirname(fileURLToPath(import.meta.url));

/** One runtime shared by every window and every Session of this machine. */
export const RUNTIME_DIR = join(tmpdir(), "dsh-multi-window-runtime");

/** Top-level files a bare Electron process needs next to its executable. */
const PAYLOAD = [
  "chrome_100_percent.pak",
  "chrome_200_percent.pak",
  "d3dcompiler_47.dll",
  "dxcompiler.dll",
  "dxil.dll",
  "ffmpeg.dll",
  "icudtl.dat",
  "resources.pak",
  "snapshot_blob.bin",
  "v8_context_snapshot.bin",
  "vk_swiftshader.dll",
  "vk_swiftshader_icd.json",
  "vulkan-1.dll",
  "version",
];

/** The sidecar's package manifest: Electron only looks for a CommonJS entry. */
const APP_MANIFEST = '{"name":"dsh-window","version":"0.1.0","private":true,"main":"main.js"}\n';

// sessionId -> pid of the window this Host already raised for it. The sidecar
// also takes a Chromium single-instance lock per --user-data-dir, so spawning it
// again for a live Session hands the new arguments to the existing window and
// the new process exits: that is a focus request, not a second window.
const running = new Map();

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Existence that does not follow links, so a dangling junction still counts. */
function exists(path) {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * Place one payload file in the runtime, preferring a hard link.
 *
 * A hard link costs no disk and no copy time, which is what makes shipping no
 * binaries practical. Link creation is nevertheless privileged on Windows: a
 * process running under a restrictive token (an editor or AV holding the
 * directory, or a sandbox that only allows links between approved roots) gets
 * EPERM even though the file is readable. Falling back to a copy keeps the
 * window working there at the price of the payload's size on disk.
 * @returns "link", "copy" or "reused".
 */
function placeFile(from, to) {
  if (exists(to)) return "reused";
  try {
    linkSync(from, to);
    return "link";
  } catch {
    copyFileSync(from, to);
    return "copy";
  }
}

/**
 * Place the `locales` directory: a junction where the OS allows one, else a copy.
 *
 * A junction costs nothing, but Windows refuses it when the target sits on
 * another volume or the caller's token lacks the privilege. A copy is ~50 MB of
 * small catalogues, which is worth paying to keep the window's UI language.
 * @returns "junction", "copy" or "reused".
 */
function placeDirectory(from, to) {
  if (exists(to)) return "reused";
  try {
    symlinkSync(from, to, "junction");
    return "junction";
  } catch {
    cpSync(from, to, { recursive: true });
    return "copy";
  }
}

/** Replace a generated file so a plugin upgrade also upgrades the window shell. */
function writeGenerated(path, content) {
  writeFileSync(path, content);
}

/**
 * Materialise the window runtime from the Electron payload beside this Host.
 *
 * Idempotent: once the sidecar executable exists the call is a no-op, so every
 * window after the first reuses the same payload.
 * @returns the sidecar executable inside {@link RUNTIME_DIR}.
 * @throws when the payload is not where the running executable lives; the
 *   message is user-facing and `hint` says what to do about it.
 */
export function ensureRuntime() {
  const executable = join(RUNTIME_DIR, "dsh-window.exe");
  if (exists(executable)) return executable;

  const source = dirname(process.execPath);
  // `icudtl.dat` is the cheapest reliable marker that this is an Electron payload.
  if (!exists(join(source, "icudtl.dat"))) {
    const error = new Error(`no Electron payload next to ${process.execPath}`);
    error.hint = "start a window from the DSH desktop app, or point DSH_MULTI_WINDOW_EXE at an Electron executable";
    throw error;
  }

  mkdirSync(RUNTIME_DIR, { recursive: true });
  for (const entry of PAYLOAD) {
    const from = join(source, entry);
    // A build may legitimately omit an optional payload file; only the files
    // Electron refuses to start without are required.
    if (!exists(from)) continue;
    placeFile(from, join(RUNTIME_DIR, entry));
  }
  // Hard links have no canonical name, so the sidecar may be called anything.
  placeFile(process.execPath, executable);

  const resources = join(RUNTIME_DIR, "resources");
  mkdirSync(join(resources, "app"), { recursive: true });
  writeGenerated(join(resources, "app", "main.js"), readFileSync(join(here, "window-main.js")));
  writeGenerated(join(resources, "app", "package.json"), APP_MANIFEST);

  // `locales` only decides the UI language of Chromium's own chrome and of the
  // file pickers; a failure here must not cost the window itself.
  try {
    placeDirectory(join(source, "locales"), join(RUNTIME_DIR, "locales"));
  } catch {
    // The window still loads; only native labels may fall back to English.
  }

  if (!exists(executable)) {
    const error = new Error(`cannot build the window runtime in ${RUNTIME_DIR}`);
    error.hint = "check that the temporary directory is writable and has room for the Electron payload";
    throw error;
  }
  return executable;
}

/**
 * The sidecar executable.
 *
 * `DSH_MULTI_WINDOW_EXE` wins so a developer can point at any Electron build;
 * otherwise the shared temporary runtime is bootstrapped on first use.
 * @returns the path to the executable.
 */
export function windowExecutable() {
  const configured = process.env.DSH_MULTI_WINDOW_EXE;
  if (configured !== undefined && configured !== "") return configured;
  return ensureRuntime();
}

/** One Chromium profile per window, so two windows never share a user-data dir. */
export function windowProfile(session) {
  const safe = session.replace(/[^A-Za-z0-9_.-]/gu, "_").slice(0, 64);
  return join(tmpdir(), "dsh-multi-window", safe === "" ? "shell" : safe);
}

export function spawnWindow(executable, url, profile, onExit) {
  mkdirSync(profile, { recursive: true });
  // The Host itself runs under ELECTRON_RUN_AS_NODE=1 (DSH uses one executable
  // for both roles). A child inherits it and would start as Node, fail to load
  // the app and exit silently, so the variable is removed for the sidecar.
  const environment = { ...process.env };
  delete environment.ELECTRON_RUN_AS_NODE;
  const child = spawn(executable, [`--user-data-dir=${profile}`, "--no-sandbox", url], {
    detached: true,
    stdio: "ignore",
    windowsHide: false,
    env: environment,
  });
  if (typeof onExit === "function") child.on("exit", onExit);
  child.unref();
  return child.pid;
}

export function openWindowResponse(ctx, request) {
  const url = new URL(request.url);
  const sessions = url.searchParams.getAll("session");
  if (sessions.length > 1 || sessions[0] === "") {
    return Response.json({ error: "session must appear at most once" }, { status: 400 });
  }
  const titles = url.searchParams.getAll("title");
  if (titles.length > 1) return Response.json({ error: "title must appear once" }, { status: 400 });
  const session = sessions[0];
  const title = titles[0];

  const webServer = ctx.get("webServer");
  const connection = ctx.get("connection");
  if (webServer === undefined || connection === undefined) {
    return Response.json({ error: "the Web host is unavailable" }, { status: 503 });
  }

  let executable;
  try {
    executable = windowExecutable();
  } catch (error) {
    return Response.json(
      { error: `the window runtime is unavailable: ${error.message}`, hint: error.hint ?? "see the plugin README" },
      { status: 503 },
    );
  }
  if (!existsSync(executable)) {
    return Response.json(
      { error: `the window executable is missing: ${executable}`, hint: "clear DSH_MULTI_WINDOW_EXE or reinstall the plugin" },
      { status: 503 },
    );
  }

  const target = new URL(connection.authenticatedUrl(webServer.getOrigin()));
  if (session !== undefined) {
    const anchor = new URLSearchParams({ "dsh-window": session });
    if (title !== undefined && title !== "") anchor.set("title", title);
    target.hash = anchor.toString();
  }

  let pid;
  let focused = false;
  try {
    const known = session === undefined ? undefined : running.get(session);
    if (known !== undefined && alive(known)) {
      // The existing window keeps the record; this spawn only forwards focus, so
      // it gets no exit handler that could clear the live Session's entry.
      spawnWindow(executable, target.href, windowProfile(session ?? "default"));
      focused = true;
      pid = known;
    } else {
      let started;
      const onExit =
        session === undefined
          ? undefined
          : () => {
              // Only clear this attempt: a Session may already have a newer window
              // and a late exit event must not delete that record.
              if (running.get(session) === started) running.delete(session);
            };
      started = spawnWindow(executable, target.href, windowProfile(session ?? "default"), onExit);
      pid = started;
      if (session !== undefined && pid !== undefined) running.set(session, pid);
    }
  } catch (error) {
    return Response.json({ error: `cannot start the window: ${String(error)}` }, { status: 500 });
  }
  return Response.json({ url: target.href, session, pid, focused });
}

export function apply(ctx) {
  ctx.effect(
    () =>
      ctx.connection.fetch.register({
        path: OPEN_PATH,
        methods: ["GET"],
        requestBody: "buffered",
        fetch: (request) => openWindowResponse(ctx, request),
      }),
    "multi-window: open route",
  );
}
