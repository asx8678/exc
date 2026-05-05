# Burrito Single-Binary Releases

[Burrito](https://github.com/burrito-elixir/burrito) is an Elixir packaging tool that produces self-contained, single-binary executables for macOS, Linux, and Windows. It bundles the BEAM VM, your compiled application, and the Erlang runtime into a self-extracting archive wrapped by a small Zig binary.

This means end users don't need Erlang, Elixir, or any other runtime installed — they just download and run the binary.

## Prerequisites

### Zig Compiler

Burrito uses [Zig](https://ziglang.org/) to compile the native wrapper binary. You need Zig ≥ 0.11 on your PATH.

| Platform | Install Command | Notes |
|----------|----------------|-------|
| macOS | `brew install zig` | Homebrew tracks latest stable |
| Ubuntu/Debian | `apt install zig` | Verify version ≥ 0.11; some distros ship older versions |
| Arch Linux | `pacman -S zig` | Usually up to date |
| Windows | `choco install zig` | Or download from [ziglang.org](https://ziglang.org/download/) |

### Additional Tools

| Platform | Tool | Purpose |
|----------|------|---------|
| All | XZ (`xz`) | Payload compression |
| Windows targets | 7-Zip (`7z`) | Windows payload handling |

## Building

Use the provided helper script:

```bash
# Build all targets
scripts/build-burrito.sh

# Build only for the current host platform
scripts/build-burrito.sh --host-only

# Build a specific target
scripts/build-burrito.sh --target macos_arm64
scripts/build-burrito.sh --target linux_x86_64
scripts/build-burrito.sh --target linux_musl_x86_64
scripts/build-burrito.sh --target windows_x86_64
```

Or manually:

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release code_puppy_control --overwrite

# Build a single target:
BURRITO_TARGET=macos_arm64 MIX_ENV=prod mix release code_puppy_control --overwrite
```

## Output Layout

Built binaries appear under `burrito_out/`:

```
burrito_out/
├── code_puppy_control_macos_arm64
├── code_puppy_control_macos_x86_64
├── code_puppy_control_linux_x86_64
├── code_puppy_control_linux_arm64
├── code_puppy_control_linux_musl_x86_64
├── code_puppy_control_linux_musl_arm64
└── code_puppy_control_windows_x86_64.exe
```

## First-Run Behavior

On first launch, the Burrito binary extracts its payload (BEAM code + ERTS) to the system user cache directory (`:filename.basedir(:user_cache, "burrito")`):

| Platform | Extraction Path |
|----------|----------------|
| macOS | `~/Library/Caches/burrito/` |
| Linux | `~/.cache/burrito/` |
| Windows | `%LOCALAPPDATA%\burrito\` |

First-run extraction takes ~2-5 seconds. Subsequent launches of the same version are fast (the cached payload is reused).

## Running

```bash
# macOS / Linux
./code_puppy_control_macos_arm64 "explain this code"
./code_puppy_control_linux_x86_64 --help

# Windows
.\code_puppy_control_windows_x86_64.exe --help
```

The binary accepts the same CLI arguments as the escript `pup` command.

### Configuration Defaults

When running as a Burrito binary, `PUP_DATABASE_PATH` and `PUP_SECRET_KEY_BASE` are not required — sensible defaults are auto-generated:

- **Database**: `data.sqlite` under the system user-data directory
  - macOS: `~/Library/Application Support/code_puppy/data.sqlite`
  - Linux: `~/.local/share/code_puppy/data.sqlite`
  - Windows: `%LOCALAPPDATA%\code_puppy\data.sqlite`
- **Secret key base**: Auto-generated via `:crypto.strong_rand_bytes/1` and persisted to `secret_key_base` in the same directory

These paths are intentionally **outside** `~/.code_puppy/` (Python pup's home) to respect ADR-003 config isolation.

## CI/CD Release Automation

Tag-push builds and GitHub Release publishing are automated via `.github/workflows/burrito-release.yml`.

### How it works

| Aspect | Detail |
|--------|--------|
| **Trigger** | Git tag push matching `v*` (e.g. `v1.0.0`) or manual `workflow_dispatch` |
| **Matrix** | 3 platforms: `macos-latest` (arm64), `ubuntu-latest` (x86_64), `windows-latest` (x86_64) |
| **Artifacts** | 3 native binaries + `SHA256SUMS.txt` attached to a GitHub Release |
| **Run history** | `https://github.com/<owner>/<repo>/actions/workflows/burrito-release.yml` |

On a tag push, each platform builds a Burrito binary, uploads it as a workflow artifact, then a `release` job downloads all three, computes SHA-256 checksums, and creates a GitHub Release with all files attached.

`workflow_dispatch` runs build artifacts but **do not** publish a release (the `release` job only runs on tag refs).

### Codesigning

| Platform | Status | Issue |
|----------|--------|-------|
| Windows (Authenticode) | ✅ Signed when secrets configured | |
| macOS (codesign + notarize) | ❌ Unsigned | |

#### Windows Authenticode Signing

The Windows binary is automatically signed with `signtool.exe` during CI when the following **repository secrets** are configured:

| Secret | Description |
|--------|-------------|
| `WINDOWS_CODESIGN_CERT_BASE64` | Base64-encoded PFX code-signing certificate (EV or OV) |
| `WINDOWS_CODESIGN_PASSWORD` | Password protecting the PFX file |

**If either secret is absent, the signing step is silently skipped** — the workflow still succeeds, but the binary will be unsigned and Windows SmartScreen may warn on launch.

##### Setting up the secrets

1. Obtain an **OV or EV code-signing certificate** from a trusted CA (DigiCert, Sectigo, GlobalSign, etc.).
2. Export the certificate as a **PFX** (.pfx / .p12) file with a strong password.
3. Base64-encode the PFX:
   ```bash
   base64 -i codesign.pfx | pbcopy # macOS
   # or: certutil -encode codesign.pfx codesign.b64 # Windows
   ```
4. In GitHub → **Settings → Secrets and variables → Actions**, add:
   - `WINDOWS_CODESIGN_CERT_BASE64` = the base64 content
   - `WINDOWS_CODESIGN_PASSWORD` = the PFX password

##### How it works in CI

The signing step runs **after** the Burrito build and **before** artifact upload:

1. Decode `WINDOWS_CODESIGN_CERT_BASE64` to a temporary `.pfx` file
2. Import the PFX into the current-user "My" certificate store
3. Sign the `.exe` with `signtool.exe sign /sha1 <thumbprint> /fd SHA256 /tr http://timestamp.digicert.com /td SHA256`
4. Verify the signature with `signtool.exe verify /pa`
5. Remove the certificate from the store and delete the `.pfx` file

The timestamp server (`http://timestamp.digicert.com`) ensures the signature remains valid after the certificate expires.

##### Signing locally

If you need to sign a Windows binary outside CI (e.g. a manual release), use the provided helper script:

```powershell
# From the project root, after building the Windows target:
powershell -File scripts/sign-windows.ps1 -ExePath elixir/code_puppy_control/burrito_out/code_puppy_control_windows_x86_64.exe
```

Or directly with `signtool.exe`:
```powershell
signtool sign /f codesign.pfx /p <password> /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 <binary.exe>
signtool verify /pa <binary.exe>
```

### Musl-based Linux (Alpine)

The `linux_musl_x86_64` and `linux_musl_arm64` targets produce binaries linked against musl libc instead of glibc. These run natively on Alpine Linux, Void Linux (musl), OpenWrt, and other musl-based distributions.

Burrito uses Zig's built-in musl cross-compilation support — no separate musl toolchain is needed on the build host. The musl libc runtime is automatically fetched from Burrito's CDN during the build.

```bash
# Build the musl target for Alpine
scripts/build-burrito.sh --target linux_musl_x86_64
```

When using `--host-only` on a musl-based system (detected via `/etc/alpine-release` or `ldd --version` containing "musl"), the script automatically selects the `linux_musl_*` target.

### CI build coverage

The CI workflow (`burrito-release.yml`) builds **host-native** binaries on
3 runner platforms. This covers the most common architectures; additional
targets from `mix.exs` are available via local cross-compilation.

| CI matrix platform | Burrito target | Runner |
|---------------------|----------------|--------|
| `macos-arm64` | `macos_arm64` | `macos-latest` |
| `linux-x86_64` | `linux_x86_64` | `ubuntu-latest` |
| `windows-x86_64` | `windows_x86_64` | `windows-latest` |

Targets **not** built by CI (available via `scripts/build-burrito.sh --target <name>`):

| Target | Notes |
|--------|-------|
| `macos_x86_64` | Cross-compile from arm64 or build locally on Intel Mac |
| `linux_arm64` | Cross-compile from x86_64 or build on ARM hardware |
| `linux_musl_x86_64` | Cross-compile via Zig's musl target |
| `linux_musl_arm64` | Cross-compile via Zig's musl target |

## Known Issues

### macOS Gatekeeper

macOS Gatekeeper blocks unsigned binaries. Workaround until codesigning is implemented:

```bash
xattr -c ./code_puppy_control_macos_arm64
```

> **Future work:** Apple Developer ID codesigning and notarization (tracked as a follow-up).

### Windows SmartScreen

Windows SmartScreen flags unsigned executables with an "unrecognized app" warning.

- **With Authenticode signing**: If the CI secrets `WINDOWS_CODESIGN_CERT_BASE64` and `WINDOWS_CODESIGN_PASSWORD` are configured, the Windows binary is signed and SmartScreen will not warn. An **EV certificate** provides immediate SmartScreen trust; an **OV certificate** requires the binary to build reputation over time.
- **Without signing**: Users can click "More info" → "Run anyway".

See [Windows Authenticode Signing](#windows-authenticode-signing) above for setup instructions.

### Linux (musl/Alpine)

Use the `linux_musl_x86_64` or `linux_musl_arm64` target for musl-based distributions (Alpine, Void musl, etc.). These targets link against musl libc via Zig's cross-compilation toolchain and include a musl libc runtime shim automatically fetched by Burrito.

See [Musl-based Linux (Alpine)](#musl-based-linux-alpine) above for details.

## Troubleshooting

### "Zig compiler not found"

Install Zig (see [Prerequisites](#prerequisites)) and ensure it's on your PATH:

```bash
zig version # should print e.g. 0.13.0
```

### Build fails with linker errors

Common causes:
- **Missing C compiler**: Burrito cross-compiles NIFs which requires a C toolchain. On macOS, install Xcode Command Line Tools (`xcode-select --install`). On Linux, install `build-essential`.
- **Zig version mismatch**: Burrito 1.3 requires Zig 0.13+. Check with `zig version`.

### "NIF compilation failed"

If NIF-bearing dependencies (e.g., `xxhash`, `erlexec`, `exqlite`) fail to compile for a cross-compilation target:
1. Ensure Zig is installed and accessible
2. Try building with `--host-only` first to verify the native build works
3. Cross-compilation of NIFs depends on Zig's cross-compilation support for the target platform

### Binary exits immediately with no output

This usually means the BEAM application failed to start. Check:
1. The binary was built with `MIX_ENV=prod`
2. Required configuration is available (env vars or Burrito auto-defaults)
3. Run with `__BURRITO_DEBUG=1` environment variable for verbose output

## Relationship to Mix Release Overlays

The `rel/overlays/bin/pup`, `rel/overlays/bin/code-puppy`, and `rel/overlays/bin/gac` shell wrappers are used **only** by `mix release` output (the traditional Mix release workflow). They require Elixir/Erlang installed on the target machine.

Those wrappers prefer the Elixir release escript. Legacy Python CLI fallback is disabled by default and is available only as an explicit debug/rollback opt-in with `PUP_ALLOW_LEGACY_PYTHON_CLI=1`.

Burrito binaries are self-contained and do **not** use these overlays. Both workflows coexist:

| Workflow | Command | Output | Requires Erlang on target |
|----------|---------|--------|---------------------------|
| Mix release | `mix release` | `_build/prod/rel/` | Yes |
| Burrito | `scripts/build-burrito.sh` | `burrito_out/` | No |
