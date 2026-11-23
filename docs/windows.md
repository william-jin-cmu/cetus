# Windows x64 portable build

Extract the entire Cetus ZIP into a local folder and launch `Cetus.exe`. Settings and conversations live in `%APPDATA%\dev.cetus.app`. The portable build is unsigned. Install Git for Windows if the built-in agent needs Bash or Git tools. Configure a DeepSeek key in Settings or install a supported native agent CLI on PATH.

The main window uses Windows window controls. Workspace terminals and the composer's local command mode use PowerShell. The packaged control CLI is `resources\bin\cetus.exe`. With Cetus running, `resources\bin\cetus.exe version` checks the connection to the backend. External agent sessions receive the CLI on their PATH.

The macOS speech and meeting capture helpers, Accessibility-based context, modifier-only launcher gestures and automatic updates are unavailable in this build.

## Build on macOS

Use the repository's Node and pnpm toolchain, Bun, Rust, MinGW-w64 and zip. Install the Rust target with `rustup target add x86_64-pc-windows-gnu` and MinGW-w64 with `brew install mingw-w64`. From the repository root, run:

```sh
pnpm install --frozen-lockfile
pnpm app:windows
```

The archive is written to `backend/target/electron/Cetus-<version>-windows-x64.zip`. To refresh the bundled runtime after changing its dependencies or extensions, run `scripts/build-pi-sidecar.sh windows-x64` before packaging.

## Check the extracted build

Start Cetus and run the following from the extracted folder in PowerShell:

```powershell
.\resources\bin\cetus.exe ping
.\resources\bin\cetus.exe version
.\resources\bin\cetus.exe cron list
```

For an offline model registry check, open a fresh PowerShell session in the extracted folder and run:

```powershell
$env:DEEPSEEK_API_KEY = 'cetus-build-check'
.\resources\pi-install\pi.exe --extension .\resources\pi-install\cetus-extensions\deepseek-endpoint.ts --list-models deepseek
```

The result should include `deepseek-flash`. A live model turn requires provider credentials.
