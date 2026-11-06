# coding-agents-installer

[![CI](https://github.com/ayazmirza54/coding-agents-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/ayazmirza54/coding-agents-installer/actions/workflows/ci.yml)

One command to install, or bring up to date, the AI coding agents and editors you use:

| Key | Tool | Windows (PowerShell, Git Bash) | WSL2, Linux, macOS |
|---|---|---|---|
| `codex` | Codex CLI | winget `OpenAI.Codex` | npm `@openai/codex` |
| `claude` | Claude Code CLI | `claude update` if natively installed, else winget `Anthropic.ClaudeCode` | `claude update`, else [claude.ai/install.sh](https://claude.ai/install.sh) |
| `opencode` | OpenCode CLI | npm `@opencode/cli` | npm `@opencode/cli` |
| `agy` | Antigravity CLI | winget `Google.AntigravityCLI` | [antigravity.google/cli/install.sh](https://antigravity.google/cli/install.sh) |
| `claude-desktop` | Claude Desktop | winget `Anthropic.Claude` | WSL2: winget on the Windows side |
| `codex-desktop` | Codex Desktop (ships as "ChatGPT") | winget `OpenAI.ChatGPT` | WSL2: winget on the Windows side |
| `vscode` | VS Code | winget `Microsoft.VisualStudioCode` | WSL2: winget on the Windows side |
| `antigravity-ide` | Antigravity IDE | winget `Google.AntigravityIDE` | WSL2: winget on the Windows side |
| `cursor` | Cursor | winget `Anysphere.Cursor` | WSL2: winget on the Windows side |
| `t3code` | T3 Code Desktop | winget `T3Tools.T3Code` | WSL2: winget on the Windows side |

Desktop apps are Windows apps. On plain Linux and macOS the installer handles the CLIs and skips the apps.

## Quick start

Preview first. It shows what would be installed and changes nothing.

**Windows, PowerShell**

```powershell
$env:CAI_PREVIEW = 1; irm https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.ps1 | iex; Remove-Item Env:CAI_PREVIEW
```

```powershell
irm https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.ps1 | iex
```

**Git Bash, WSL2, Linux, macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.sh | bash -s -- --preview
```

```bash
curl -fsSL https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.sh | bash
```

Run it again any time to upgrade everything. Use a regular, non-elevated terminal, and close the apps being upgraded first.

## Pick what to install

```bash
curl -fsSL https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.sh | bash -s -- --only codex,claude,opencode
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.ps1))) -Only clis
```

| `install.sh` | `install.ps1` | Environment variable | Effect |
|---|---|---|---|
| `--preview` | `-Preview` | `CAI_PREVIEW=1` | Show versions; change nothing. Exits 1 if a package ID no longer exists. |
| `--list` | `-List` | | List tool keys. |
| `--only KEYS` | `-Only KEYS` | `CAI_ONLY` | Only these keys, or the groups `clis` / `apps`. |
| `--skip KEYS` | `-Skip KEYS` | `CAI_SKIP` | Skip these keys or groups. |
| `--skip-apps` | `-SkipApps` | `CAI_SKIP_APPS=1` | CLIs only. |
| `--skip-clis` | `-SkipClis` | `CAI_SKIP_CLIS=1` | Desktop apps only. |
| `--force-winget-claude` | `-ForceWinGetClaude` | `CAI_FORCE_WINGET_CLAUDE=1` | Windows: use winget for Claude Code even if the native install exists. |

`irm | iex` cannot pass parameters, so use the environment variables or the `[scriptblock]::Create` form there.

## What "latest" means

- **winget packages:** the newest version in the winget community catalog. The installer refreshes the source first. The catalog usually trails a vendor release by hours to a few days.
- **npm packages:** the `latest` dist-tag on npmjs.com.
- **Vendor installers** (`claude.ai/install.sh`, `antigravity.google/cli/install.sh`) and `claude update`: the vendor's newest release.
- **Desktop apps** also update themselves. If an app is newer than the catalog, winget reports *Up to date* and leaves it alone.

## What it changes on your machine

- Installs or upgrades the packages above. Installed packages are upgraded in place, never reinstalled.
- **Node.js** (needed for npm-based CLIs):
  - Windows: installs `OpenJS.NodeJS.LTS` from winget only when npm is missing, and upgrades it only if winget manages it. A Node from nvm-windows, fnm or Volta is left alone.
  - Unix: uses an existing Node that can install global packages without sudo. Otherwise it installs [nvm](https://github.com/nvm-sh/nvm) in `~/.nvm` (which edits your shell rc file) and the current LTS. It never uses sudo.
- **Orphaned npm launchers:** `codex`/`opencode` launchers left behind by an uninstalled package are renamed to `*.orphan-<timestamp>`, not deleted. Otherwise they would shadow the real install or make npm fail with `EEXIST`.
- **`opencode-ai`:** the older global package is uninstalled when present, because `@opencode/cli` replaces it and owns the same `opencode` command.
- **Log:** a transcript is written to your temp folder (`coding-agents-<timestamp>-<pid>.log`).

At the end, it prints which file each CLI command will run in a new terminal and warns when another copy shadows it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Installer is in use` (winget `0x8A150101`) | Close the app and rerun. |
| `... has 2 installs` warning, or the app step fails | You have two copies (often an old machine-wide one). Uninstall the stale copy in Settings > Apps. |
| `'agy' has more than one copy` | You installed it two ways (vendor installer and winget). Keep one and uninstall the other. |
| WSL2: `'codex' runs a Windows binary from WSL` | Windows PATH is appended inside WSL. Open a new WSL shell so the Linux install comes first, or set `appendWindowsPath=false` in `/etc/wsl.conf`. |
| WSL2: `powershell.exe not reachable` | Enable interop (`[interop] enabled=true` in `/etc/wsl.conf`) or use `--skip-apps`. |
| `winget not found` | Install or update [App Installer](https://aka.ms/getwinget). |
| Script won't run locally (`.\install.ps1`) | `powershell -ExecutionPolicy Bypass -File .\install.ps1`, or `Unblock-File .\install.ps1`. |
| `install.sh: $'\r': command not found` | The file was saved with CRLF. Re-download it or run `sed -i 's/\r$//' install.sh`. |

Exit codes: `0` success, `1` at least one item failed, `2` usage error.

## Security

Piping a script into a shell runs it with your permissions. Read [install.sh](install.sh) and [install.ps1](install.ps1) first, or pin a reviewed release instead of `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/v1.0.0/install.sh | bash
```

The scripts install only from winget, npm, and the vendors' own installer URLs listed above.

## Contributing

To add a tool, add one entry to the catalog in **both** `install.sh` and `install.ps1` with the same key, then run:

```bash
bash tests/check-catalog-sync.sh
```

```bash
bash tests/check-winget-ids.sh
```

```bash
bash install.sh --preview
```

CI runs ShellCheck and PSScriptAnalyzer, checks that both catalogs match, checks every winget ID against `microsoft/winget-pkgs`, and installs every CLI on Ubuntu and macOS. It also runs weekly to catch packages renamed upstream.

See [CHANGELOG.md](CHANGELOG.md) for release notes. Licensed under [MIT](LICENSE).
