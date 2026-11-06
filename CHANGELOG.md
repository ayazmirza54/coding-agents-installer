# Changelog

## 1.0.0 - 2026-11-06

First public release.

- One command installs or upgrades four coding CLIs (Codex, Claude Code,
  OpenCode, Antigravity `agy`) and six desktop apps (Claude, Codex/ChatGPT,
  VS Code, Antigravity IDE, Cursor, T3 Code).
- `install.ps1` for PowerShell 5.1 and 7; `install.sh` for Git Bash, WSL2,
  Linux and macOS (bash 3.2+).
- `--only` / `--skip` / `--list`, plus `CAI_*` environment variables for
  piped one-liners.
- `--preview` shows the version each catalog would install and fails when a
  package ID disappears.
- Upgrades installed packages instead of reinstalling; treats harmless winget
  results (up to date, already installed, restart pending) as success.
- Keeps an existing native Claude Code install and runs `claude update`.
- Leaves a Node.js managed by nvm, nvm-windows, fnm or Volta alone.
- Renames orphaned npm launchers aside instead of failing with `EEXIST`.
- Reports which binary each CLI command resolves to and warns about shadowed
  copies.
