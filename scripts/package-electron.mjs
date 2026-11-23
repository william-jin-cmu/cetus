#!/usr/bin/env node
// Build the release Cetus.app (Electron) — unsigned; scripts/macos-sign.sh
// signs it afterwards. Version and bundle id come from package.json
// (`version`, `cetus.appId`).
//
//   node scripts/package-electron.mjs            # full build
//   node scripts/package-electron.mjs --skip-web # reuse an existing `out/`
//
// Prints the .app path on the last line of stdout.
//
// Bundle layout (Contents/Resources):
//   app.asar      electron/dist (main + preload) + a minimal package.json
//   native/       cetus.node — the Rust backend addon
//   bin/cetus     the `cetus` CLI agents shell out to
//   out/          the static Next export, served as app://cetus/
//   icons/        app icon
//   pi-install/   the bundled pi runtime (scripts/build-pi-sidecar.sh)

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { packager } from "@electron/packager";

const root = path.resolve(import.meta.dirname, "..");
const windows = process.argv.includes("--windows-x64");
const skipWeb = process.argv.includes("--skip-web");
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const electronVersion = JSON.parse(
  fs.readFileSync(path.join(root, "node_modules", "electron", "package.json"), "utf8"),
).version;

function run(cmd, args, opts = {}) {
  console.error(`→ ${cmd} ${args.join(" ")}`);
  const r = spawnSync(cmd, args, { stdio: ["ignore", process.stderr, "inherit"], ...opts });
  if (r.status !== 0) process.exit(r.status ?? 1);
}

const backendDir = path.join(root, "backend");
const piDir = path.join(backendDir, windows ? "target/windows-runtime/pi-install" : "pi-install");
if (!fs.existsSync(path.join(piDir, windows ? "pi.exe" : "pi"))) {
  run(path.join(root, "scripts", "build-pi-sidecar.sh"), windows ? ["windows-x64"] : [], { cwd: root });
}
const target = "x86_64-pc-windows-gnu";
const targetArgs = windows ? ["--target", target] : [];
run("cargo", ["build", "--release", "--lib", ...targetArgs], { cwd: backendDir });
run("cargo", ["build", "--release", ...targetArgs], { cwd: path.join(backendDir, "cli") });
run("node", [path.join(root, "electron", "build.mjs")], {
  env: { ...process.env, CETUS_ELECTRON_RELEASE: "1" },
});
if (!skipWeb) run("pnpm", ["build"], { cwd: root });
if (!fs.existsSync(path.join(root, "out", "index.html"))) {
  console.error("out/index.html missing — run `pnpm build` first");
  process.exit(1);
}

const stage = fs.mkdtempSync(path.join(os.tmpdir(), "cetus-package-"));
const appDir = path.join(stage, "app");
const resDir = path.join(stage, "resources");
fs.mkdirSync(appDir);
fs.mkdirSync(resDir);

fs.cpSync(path.join(root, "electron", "dist"), path.join(appDir, "dist"), { recursive: true });
fs.writeFileSync(
  path.join(appDir, "package.json"),
  JSON.stringify(
    { name: "cetus", productName: "Cetus", version: pkg.version, main: "dist/main.js" },
    null,
    2,
  ),
);

const native = path.join(resDir, "native");
fs.mkdirSync(native);
fs.copyFileSync(
  path.join(backendDir, "target", windows ? target : "", "release", windows ? "cetus_lib.dll" : "libcetus_lib.dylib"),
  path.join(native, "cetus.node"),
);
const bin = path.join(resDir, "bin");
fs.mkdirSync(bin);
const cliName = windows ? "cetus.exe" : "cetus";
fs.copyFileSync(path.join(backendDir, "cli", "target", windows ? target : "", "release", cliName), path.join(bin, cliName));
fs.chmodSync(path.join(bin, cliName), 0o755);
const icons = path.join(resDir, "icons");
fs.mkdirSync(icons);
for (const f of ["icon.png"]) {
  fs.copyFileSync(path.join(backendDir, "icons", f), path.join(icons, f));
}

// Notification sounds sit at the top of Resources: macOS resolves a
// notification's sound by file name there, not in a subfolder.
const soundsDir = path.join(backendDir, "sounds");
const sounds = fs
  .readdirSync(soundsDir)
  .filter((f) => f.endsWith(".aiff"))
  .map((f) => path.join(soundsDir, f));

const outDir = path.join(backendDir, "target", "electron");
const [appPath] = await packager({
  dir: appDir,
  out: outDir,
  overwrite: true,
  platform: windows ? "win32" : "darwin",
  arch: windows ? "x64" : "arm64",
  electronVersion,
  name: "Cetus",
  executableName: "Cetus",
  win32metadata: { CompanyName: "Cetus" },
  appBundleId: pkg.cetus.appId,
  appVersion: pkg.version,
  buildVersion: pkg.version,
  appCategoryType: "public.app-category.developer-tools",
  icon: path.join(backendDir, "icons", windows ? "icon.ico" : "icon.icns"),
  asar: true,
  prune: false,
  darwinDarkModeSupport: true,
  extraResource: [
    native,
    bin,
    icons,
    ...sounds,
    path.join(root, "out"),
    ...(windows ? [] : [piDir]),
  ],
  extendInfo: {
    LSMinimumSystemVersion: "13.0",
    NSMicrophoneUsageDescription:
      "Cetus uses your microphone to transcribe speech to text for voice input.",
    NSSpeechRecognitionUsageDescription:
      "Cetus transcribes your speech on-device so you can dictate instead of type.",
    NSAudioCaptureUsageDescription:
      "Cetus transcribes the other meeting participants from your system audio. No audio is stored.",
  },
  // Signing is done by scripts/macos-sign.sh (nested pi binaries need their
  // own entitlements, which the packager's signer doesn't know about).
  osxSign: undefined,
});

if (windows) {
  // The Windows runtime tree must contain regular files, including npm shims.
  const runtime = path.join(appPath, "resources", "pi-install");
  fs.cpSync(piDir, runtime, { recursive: true, dereference: true });
  fs.copyFileSync(path.join(root, "docs", "windows.md"), path.join(appPath, "README.md"));
  const archive = path.join(outDir, `Cetus-${pkg.version}-windows-x64.zip`);
  const stagedArchive = path.join(stage, "Cetus.zip");
  run("zip", ["-qr", stagedArchive, path.basename(appPath)], { cwd: outDir });
  fs.copyFileSync(stagedArchive, archive);
  fs.rmSync(stage, { recursive: true, force: true });
  console.log(archive);
  process.exit(0);
}

const app = path.join(appPath, "Cetus.app");

// The packager rewrites relative symlinks inside extraResource dirs (e.g.
// pi-install/node_modules/.bin/*) into absolute paths pointing back at the
// source tree; codesign rejects those ("invalid destination for symbolic
// link in bundle"). Point them back inside the bundle, relatively.
const bundleRes = path.join(app, "Contents", "Resources");
const resourceSources = new Map([
  [path.join(root, "out"), path.join(bundleRes, "out")],
  [path.join(backendDir, "pi-install"), path.join(bundleRes, "pi-install")],
  [native, path.join(bundleRes, "native")],
  [bin, path.join(bundleRes, "bin")],
  [icons, path.join(bundleRes, "icons")],
]);
(function fixLinks(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isSymbolicLink()) {
      const target = fs.readlinkSync(p);
      if (!path.isAbsolute(target)) continue;
      for (const [src, dst] of resourceSources) {
        if (target === src || target.startsWith(src + path.sep)) {
          const mapped = path.join(dst, path.relative(src, target));
          fs.unlinkSync(p);
          fs.symlinkSync(path.relative(path.dirname(p), mapped), p);
          break;
        }
      }
    } else if (ent.isDirectory()) {
      fixLinks(p);
    }
  }
})(bundleRes);

fs.rmSync(stage, { recursive: true, force: true });
console.log(app);
