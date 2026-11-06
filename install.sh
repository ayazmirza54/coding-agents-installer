#!/usr/bin/env bash
# coding-agents-installer - install or upgrade AI coding CLIs and desktop apps in one go.
# https://github.com/ayazmirza54/coding-agents-installer
#
# Runs from Git Bash and WSL2 on Windows, and from Linux and macOS (CLIs only).
# Everything is defined in functions and started by the last line, so
# `curl ... | bash` reads the whole script before running any of it.
#
# Compatible with bash 3.2 (macOS) and newer. Keep LF line endings.

# Catalog entries are split into fixed fields; not every loop uses every field.
# shellcheck disable=SC2034
CAI_VERSION=1.0.0
RAW_URL=https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main

usage() {
  cat <<EOF
coding-agents-installer $CAI_VERSION

Usage: install.sh [options]

  --preview              Check every package against its catalog and print the
                         version that would be installed. Changes nothing.
                         Exits 1 if a package ID no longer exists.
  --list                 List tool keys and exit.
  --only KEYS            Install only these tools (comma-separated keys, or the
                         groups "clis" / "apps").
  --skip KEYS            Skip these tools (same format as --only).
  --skip-apps            Same as --skip apps.
  --skip-clis            Same as --skip clis.
  --force-winget-claude  Git Bash: install Claude Code from winget even when
                         Anthropic's native install is present.
  --version              Print the installer version.
  -h, --help             Show this help.

Environment variables (handy with curl | bash):
  CAI_ONLY, CAI_SKIP, CAI_PREVIEW=1, CAI_SKIP_APPS=1, CAI_SKIP_CLIS=1,
  CAI_FORCE_WINGET_CLAUDE=1

Examples:
  curl -fsSL $RAW_URL/install.sh | bash
  curl -fsSL $RAW_URL/install.sh | bash -s -- --preview
  curl -fsSL $RAW_URL/install.sh | bash -s -- --only codex,claude,opencode
EOF
}

warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
truthy() { case $(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]') in 1|true|yes|on) return 0 ;; esac; return 1; }
norm_keys() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' ;' ',,' | sed 's/^,*//; s/,*$//'; }

# ------------------------------------------------------------------ environment
detect_env() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ENV=gitbash ;;
    Darwin) ENV=macos ;;
    Linux)
      if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then ENV=wsl; else ENV=linux; fi ;;
    *) die "Unsupported system: $(uname -s)." ;;
  esac
  # Desktop apps are Windows apps, installed with winget (from WSL2 via interop).
  case $ENV in gitbash|wsl) HAS_WINDOWS=1 ;; *) HAS_WINDOWS=0 ;; esac
}

# ------------------------------------------------------------------ catalog
# key|group|Name|kind|package|scope|command
# Scope 'user' keeps winget from matching a second, machine-wide install of the same ID.
build_catalog() {
  if [[ $ENV == gitbash ]]; then
    CATALOG=(
      'codex|cli|Codex CLI|winget|OpenAI.Codex||codex'
      'claude|cli|Claude Code CLI|claude-win|Anthropic.ClaudeCode||claude'
      'opencode|cli|OpenCode CLI|npm|@opencode/cli||opencode'
      'agy|cli|Antigravity CLI (agy)|winget|Google.AntigravityCLI||agy'
    )
  else
    CATALOG=(
      'codex|cli|Codex CLI|npm|@openai/codex||codex'
      'claude|cli|Claude Code CLI|claude-unix|https://claude.ai/install.sh||claude'
      'opencode|cli|OpenCode CLI|npm|@opencode/cli||opencode'
      'agy|cli|Antigravity CLI (agy)|script|https://antigravity.google/cli/install.sh||agy'
    )
  fi
  CATALOG+=(
    'claude-desktop|app|Claude Desktop|winget|Anthropic.Claude||'
    'codex-desktop|app|Codex Desktop (ChatGPT)|winget|OpenAI.ChatGPT||'
    'vscode|app|VS Code|winget|Microsoft.VisualStudioCode|user|'
    'antigravity-ide|app|Antigravity IDE|winget|Google.AntigravityIDE|user|'
    'cursor|app|Cursor|winget|Anysphere.Cursor|user|'
    't3code|app|T3 Code Desktop|winget|T3Tools.T3Code||'
  )
  KNOWN_KEYS=',clis,apps,'
  local e
  for e in "${CATALOG[@]}"; do KNOWN_KEYS+="${e%%|*},"; done
}

validate_keys() {   # label keys
  local k IFS=,
  for k in $2; do
    [[ -z $k || $KNOWN_KEYS == *",$k,"* ]] || usage_error "Unknown tool key in $1: '$k'. Run with --list to see keys."
  done
}

is_selected() {   # key group
  local k=$1 g=$2
  if [[ -n $ONLY ]]; then
    [[ ",$ONLY," == *",$k,"* || ",$ONLY," == *",${g}s,"* ]] || return 1
  fi
  [[ ",$SKIP," == *",$k,"* || ",$SKIP," == *",${g}s,"* ]] && return 1
  return 0
}

# ------------------------------------------------------------------ Windows bridge
# winget runs through powershell.exe: bash only sees the low 8 bits of an exit
# code, so PowerShell prints the full 32-bit code as a marker line instead.
find_powershell() {
  PS=''
  local c
  for c in powershell.exe /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
           /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
    if command -v "$c" >/dev/null 2>&1; then PS=$(command -v "$c"); return 0; fi
  done
  return 1
}

win_ps() {
  local enc
  enc=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  (
    if [[ $ENV == wsl ]]; then cd /mnt/c 2>/dev/null || exit 1; fi   # avoid "UNC paths are not supported"
    MSYS_NO_PATHCONV=1 "$PS" -NoProfile -NonInteractive -EncodedCommand "$enc" </dev/null
  )
}

winget_run() {   # winget_run [-q] args...   sets WG_HEX and WG_OUT
  local quiet=0 a tmp cmd
  [[ ${1-} == -q ]] && { quiet=1; shift; }
  cmd="\$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; & winget.exe"
  for a in "$@"; do cmd+=" '${a//\'/\'\'}'"; done
  cmd+="; '__WGEXIT__{0:X8}' -f \$LASTEXITCODE"
  tmp=$(mktemp)
  if (( quiet )); then
    win_ps "$cmd" 2>&1 | sed 's/\r$//' >"$tmp"
  else
    win_ps "$cmd" 2>&1 | sed -u 's/\r$//' | tee "$tmp" | grep --line-buffered -v '^__WGEXIT__'
  fi
  WG_HEX=$(sed -n 's/^__WGEXIT__//p' "$tmp" | tail -n1)
  WG_OUT=$(grep -v '^__WGEXIT__' "$tmp")
  rm -f "$tmp"
  [[ -n $WG_HEX ]] || WG_HEX=FFFFFFFF
}

wg_ok_status() {
  case $1 in
    00000000) echo 'OK' ;;
    8A15002B) echo 'Up to date' ;;              # UPDATE_NOT_APPLICABLE
    8A150061) echo 'Already installed' ;;       # PACKAGE_ALREADY_INSTALLED
    8A150109) echo 'OK (restart to finish)' ;;  # INSTALL_REBOOT_REQUIRED_TO_FINISH
    *) return 1 ;;
  esac
}

winget_is_installed() {   # pkg [scope]   sets WG_OUT
  local list=(list --id "$1" --exact --disable-interactivity --accept-source-agreements)
  [[ -n ${2-} ]] && list+=(--scope "$2")
  winget_run -q "${list[@]}"
  [[ $WG_HEX == 00000000 ]]
}

update_winget_pkg() {   # pkg [scope]   sets STATUS
  local pkg=$1 scope=${2-} rows
  local common=(--id "$pkg" --exact --source winget --silent --disable-interactivity
                --accept-package-agreements --accept-source-agreements)
  [[ -n $scope ]] && common+=(--scope "$scope")

  if winget_is_installed "$pkg" "$scope"; then
    # Warn-only: winget truncates long IDs in narrow consoles, so this count can miss.
    rows=$(grep -cE "[[:space:]]${pkg//./\\.}[[:space:]]" <<<"$WG_OUT")
    (( rows > 1 )) && warn "$pkg has $rows installs${scope:+ in $scope scope}. winget may refuse or pick one; uninstall the stale copy."
    winget_run upgrade "${common[@]}" --include-unknown
  else
    winget_run install "${common[@]}"
  fi
  if STATUS=$(wg_ok_status "$WG_HEX"); then return 0; fi
  STATUS=Failed
  case $WG_HEX in 8A150101|8A15010B) warn "$pkg: installer is in use. Close the app and rerun." ;; esac
  warn "$pkg: winget exit 0x$WG_HEX. See output above."
  return 1
}

winget_version() {   # newest catalog version, or NOT FOUND
  winget_run -q show --id "$1" --exact --source winget --disable-interactivity --accept-source-agreements
  if [[ $WG_HEX == 00000000 ]]; then sed -n 's/^Version:[[:space:]]*//p' <<<"$WG_OUT" | head -n1
  else echo 'NOT FOUND'; fi
}

require_winget() {
  find_powershell || { warn 'powershell.exe not reachable. In WSL, enable interop ([interop] enabled=true in /etc/wsl.conf).'; return 1; }
  winget_run -q --version
  [[ $WG_HEX == 00000000 ]] || { warn 'winget not found. Install App Installer from https://aka.ms/getwinget.'; return 1; }
}

# ------------------------------------------------------------------ Node / npm
npm_usable() {   # a Node install this environment can use for -g installs; sets NPM
  local p prefix
  p=$(command -v npm 2>/dev/null) || return 1
  if [[ $ENV != gitbash ]]; then
    [[ $ENV == wsl && $p == /mnt/* ]] && return 1        # Windows npm leaking in via PATH
    prefix=$(npm config get prefix 2>/dev/null) || return 1
    [[ -w $prefix/lib || -w $prefix ]] || return 1     # system Node needs sudo for -g
  fi
  NPM=$p
}

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  [[ -s $NVM_DIR/nvm.sh ]] || return 1
  # shellcheck disable=SC1090,SC1091
  . "$NVM_DIR/nvm.sh"
}

nvm_lts() {
  nvm install --lts --latest-npm || return 1
  nvm alias default 'lts/*' >/dev/null
}

ensure_node() {   # sets STATUS
  if [[ $ENV == gitbash ]]; then
    if npm_usable && ! winget_is_installed OpenJS.NodeJS.LTS; then
      # nvm-windows, fnm, Volta, ...: leave the user's Node manager in charge.
      STATUS="Existing $(node --version 2>/dev/null) (not managed here)"; return 0
    fi
    update_winget_pkg OpenJS.NodeJS.LTS || return 1
    if ! command -v npm >/dev/null 2>&1 && [[ -d '/c/Program Files/nodejs' ]]; then
      PATH="/c/Program Files/nodejs:$PATH"; hash -r
    fi
    npm_usable || { STATUS=Failed; warn 'npm not found after Node.js setup. Open a new Git Bash and rerun.'; return 1; }
    return 0
  fi

  # Linux, macOS, WSL: Node in the user's home with nvm; never sudo.
  if load_nvm; then
    nvm_lts || { STATUS=Failed; return 1; }
    STATUS="OK (nvm, $(node --version))"
  elif npm_usable; then
    STATUS="Existing $(node --version) (not managed here)"; return 0
  else
    local tag
    tag=$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest |
          sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    [[ -n $tag ]] || { STATUS=Failed; warn 'Could not look up the latest nvm release.'; return 1; }
    echo "Installing nvm $tag into ${NVM_DIR:-$HOME/.nvm}..."
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh" | bash || { STATUS=Failed; return 1; }
    load_nvm && nvm_lts || { STATUS=Failed; return 1; }
    STATUS="OK (nvm $tag, $(node --version))"
  fi
  npm_usable || { STATUS=Failed; warn 'npm is still not usable after nvm setup.'; return 1; }
}

# npm launchers whose package is gone shadow real installs and make
# `npm install -g` fail with EEXIST. Rename them (reversible), never delete.
repair_orphan_shim() {   # bindir name
  local bindir=$1 name=$2 target stamp f files=()
  if [[ $ENV == gitbash ]]; then
    [[ -f $bindir/$name.cmd ]] || return 0
    target=$(grep -aoE 'node_modules[\\/][^"%]+' "$bindir/$name.cmd" | head -n1 | tr -d '\r')
    [[ -n $target ]] || return 0
    [[ -e $bindir/${target//\\//} ]] && return 0
    files=("$name" "$name.cmd" "$name.ps1")
  else
    [[ -L $bindir/$name && ! -e $bindir/$name ]] || return 0   # dangling symlink
    files=("$name")
  fi
  stamp=$(date +%Y%m%d%H%M%S)
  for f in "${files[@]}"; do
    if [[ -e $bindir/$f || -L $bindir/$f ]]; then mv -- "$bindir/$f" "$bindir/$f.orphan-$stamp"; fi
  done
  echo "Moved orphaned npm launcher '$name' aside (*.orphan-$stamp in $bindir)."
}

update_npm_pkg() {   # pkg cmd   sets STATUS
  local pkg=$1 cmd=$2 prefix bindir moddir
  [[ -n $NPM ]] || { STATUS=Failed; warn 'npm unavailable (Node.js step failed).'; return 1; }
  prefix=$(npm config get prefix | tr -d '\r')
  if [[ $ENV == gitbash ]]; then
    bindir=$(cygpath -u "$prefix"); moddir=$bindir/node_modules
  else
    bindir=$prefix/bin; moddir=$prefix/lib/node_modules
  fi
  if [[ $pkg == @opencode/cli && -d $moddir/opencode-ai ]]; then
    echo 'Removing old opencode-ai package (replaced by @opencode/cli)...'
    npm uninstall --global opencode-ai
  fi
  repair_orphan_shim "$bindir" "$cmd"
  # A stale npm `codex` launcher would shadow the winget Codex CLI.
  [[ $ENV == gitbash ]] && repair_orphan_shim "$bindir" codex

  # npm 12+ blocks install scripts by default; allow them for this package only
  # (OpenCode's postinstall fetches its platform binary).
  local extra=() major
  major=$(npm --version 2>/dev/null | cut -d. -f1)
  [[ $major =~ ^[0-9]+$ ]] && (( major >= 12 )) && extra=(--allow-scripts="$pkg")

  npm install --global "${extra[@]}" "$pkg@latest" || { STATUS=Failed; warn "$pkg: npm install failed. See output above."; return 1; }
  STATUS="OK ($(npm_latest "$pkg"))"
}

npm_latest() {   # newest version on the npm registry, without needing Node
  curl -fsSL "https://registry.npmjs.org/-/package/$1/dist-tags" 2>/dev/null |
    sed -n 's/.*"latest":"\([^"]*\)".*/\1/p'
}

# ------------------------------------------------------------------ vendor installers
native_claude_path() {
  if [[ $ENV == gitbash ]]; then echo "$(cygpath -u "$USERPROFILE")/.local/bin/claude.exe"
  else echo "$HOME/.local/bin/claude"; fi
}

update_claude() {   # pkg-or-url   sets STATUS
  local native
  native=$(native_claude_path)
  if [[ -x $native ]] && ! (( FORCE_WINGET_CLAUDE )); then
    echo "Native install found at $native; running 'claude update'."
    "$native" update </dev/null || { STATUS=Failed; return 1; }
    STATUS='OK (native self-update)'; return 0
  fi
  if [[ $ENV == gitbash ]]; then update_winget_pkg "$1"; return; fi
  curl -fsSL "$1" | bash -s latest || { STATUS=Failed; return 1; }
  STATUS='OK (native install)'
}

# Google's agy installer refuses to run over an existing install; agy updates
# itself in the background, so an existing native copy is left alone.
native_agy_path() {
  if [[ $ENV == gitbash ]]; then echo "$(cygpath -u "$LOCALAPPDATA")/agy/bin/agy.exe"
  else echo "$HOME/.local/bin/agy"; fi
}

has_native_agy() { [[ -x $(native_agy_path) ]]; }

run_vendor_script() {   # url
  if has_native_agy; then
    echo "Native install found at $(native_agy_path); agy updates itself."
    STATUS='OK (native, self-updating)'; return 0
  fi
  curl -fsSL "$1" | bash || { STATUS=Failed; return 1; }
  STATUS='OK (vendor installer)'
}

# ------------------------------------------------------------------ resolution check
# Every file a command resolves to in a NEW terminal, first one wins.
resolve_cli() {   # name
  local name=$1
  if [[ $ENV != gitbash ]]; then
    # Not `bash -ilc`: a ~/.bashrc may prompt (sudo) and hang. The installers put
    # ~/.local/bin on PATH and nvm (loaded earlier) already set its bin directory.
    local p=$PATH
    [[ ":$p:" == *":$HOME/.local/bin:"* ]] || p="$HOME/.local/bin:$p"
    ( PATH=$p; type -aP "$name" ) 2>/dev/null | awk '!seen[$0]++'
    return
  fi
  local winpath d
  winpath=$(win_ps "[Environment]::ExpandEnvironmentVariables([Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User'))" | tr -d '\r')
  local IFS=:
  for d in $(cygpath -u -p "$winpath"); do
    [[ -n $d ]] || continue
    if   [[ -f $d/$name.exe ]]; then echo "$d/$name.exe"
    elif [[ -f $d/$name && -x $d/$name ]]; then echo "$d/$name"
    fi
  done | awk '!seen[$0]++'
}

report_resolution() {
  local entry key group name kind pkg scope cmd line hits
  echo; echo 'Command resolution in a new terminal:'
  for entry in "${SELECTED[@]}"; do
    IFS='|' read -r key group name kind pkg scope cmd <<<"$entry"
    [[ -n $cmd ]] || continue
    hits=()
    while IFS= read -r line; do hits+=("$line"); done < <(resolve_cli "$cmd")
    if (( ${#hits[@]} == 0 )); then printf '  %-9s NOT ON PATH\n' "$cmd"; continue; fi
    printf '  %-9s %s\n' "$cmd" "${hits[0]}"
    if [[ $ENV == wsl && ${hits[0]} == /mnt/* ]]; then
      warn "'$cmd' runs a Windows binary from WSL. Put the Linux install first on PATH."
    fi
    if (( ${#hits[@]} > 1 )); then
      warn "'$cmd' has more than one copy; '${hits[0]}' wins. Others: ${hits[*]:1}"
    fi
  done
}

# ------------------------------------------------------------------ commands
cmd_list() {
  local entry key group name kind pkg scope cmd
  printf '%-16s %-4s %-25s %-12s %s\n' KEY TYPE NAME SOURCE PACKAGE
  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r key group name kind pkg scope cmd <<<"$entry"
    printf '%-16s %-4s %-25s %-12s %s\n' "$key" "$group" "$name" "$kind" "$pkg"
  done
  echo; echo "Groups: clis, apps. Environment: $ENV"
  (( HAS_WINDOWS )) || echo 'Desktop apps are installed only from Git Bash or WSL2 on Windows.'
}

cmd_preview() {
  local entry key group name kind pkg scope cmd v winget_ok=1 drift=0
  echo "coding-agents-installer $CAI_VERSION  (environment: $ENV)"
  if (( NEEDS_WINGET )); then require_winget || winget_ok=0; fi
  for entry in "${SELECTED[@]}"; do
    IFS='|' read -r key group name kind pkg scope cmd <<<"$entry"
    case $kind in
      winget)
        if [[ $group == app ]] && ! (( HAS_WINDOWS )); then v='skipped (Windows only)'
        elif [[ $key == agy ]] && has_native_agy; then v='native install: updates itself'
        elif (( winget_ok )); then v=$(winget_version "$pkg"); [[ $v == 'NOT FOUND' ]] && drift=$((drift + 1))
        else v='winget unavailable'; drift=$((drift + 1)); fi ;;
      claude-win|claude-unix)
        if [[ -x $(native_claude_path) ]] && ! (( FORCE_WINGET_CLAUDE )); then v='native install: will run claude update'
        elif [[ $kind == claude-unix ]]; then v='vendor installer, latest channel'
        elif (( winget_ok )); then v="$(winget_version "$pkg") (winget)"; [[ $v == 'NOT FOUND'* ]] && drift=$((drift + 1))
        else v='winget unavailable'; drift=$((drift + 1)); fi ;;
      script)
        if has_native_agy; then v='native install: updates itself'
        elif curl -fsSLI -o /dev/null "$pkg"; then v='vendor installer, always latest'
        else v='INSTALLER URL UNREACHABLE'; drift=$((drift + 1)); fi ;;
      npm)
        v=$(npm_latest "$pkg")
        if [[ -z $v ]]; then v='NOT FOUND'; drift=$((drift + 1)); fi ;;
    esac
    printf '%-16s %-25s %-12s %-28s %s\n' "$key" "$name" "$kind" "$pkg" "$v"
  done
  if (( drift )); then warn "$drift package(s) could not be resolved."; return 1; fi
  return 0
}

cmd_install() {
  local entry key group name kind pkg scope cmd i r failed=0 needs_node=0
  local LOG
  LOG="${TMPDIR:-/tmp}/coding-agents-$(date +%Y%m%d-%H%M%S)-$$.log"
  exec > >(tee -a "$LOG") 2>&1
  echo "coding-agents-installer $CAI_VERSION  (environment: $ENV)"

  NAMES=() RESULTS=()
  WINGET_OK=1
  for entry in "${SELECTED[@]}"; do [[ $entry == *'|npm|'* ]] && needs_node=1; done
  (( needs_node )) && [[ $ENV == gitbash ]] && NEEDS_WINGET=1   # Node.js LTS may come from winget

  if (( NEEDS_WINGET )); then
    if require_winget; then
      echo 'Refreshing winget source...'
      winget_run source update --name winget --disable-interactivity
    else
      WINGET_OK=0
    fi
  fi
  if [[ $ENV != gitbash ]] && ! command -v curl >/dev/null 2>&1; then
    die 'curl is required. Install it with your package manager and rerun.'
  fi

  if (( needs_node )); then
    echo; echo '[Node.js] prerequisite for npm-based CLIs'
    STATUS=Failed
    if [[ $ENV == gitbash ]] && ! (( WINGET_OK )) && ! npm_usable; then warn 'winget unavailable.'
    else ensure_node; fi
    NAMES+=('Node.js (prereq)'); RESULTS+=("$STATUS")
  fi

  for entry in "${SELECTED[@]}"; do
    IFS='|' read -r key group name kind pkg scope cmd <<<"$entry"
    echo; echo "[$name] $pkg"
    STATUS=Failed
    if [[ $group == app ]] && ! (( HAS_WINDOWS )); then
      STATUS='Skipped (Windows only)'
    else
      case $kind in
        winget)
          if [[ $key == agy ]] && has_native_agy; then
            echo "Native install found at $(native_agy_path); agy updates itself."
            STATUS='OK (native, self-updating)'
          elif (( WINGET_OK )); then update_winget_pkg "$pkg" "$scope"
          else warn 'winget unavailable.'; fi ;;
        claude-win)  if (( WINGET_OK )) || [[ -x $(native_claude_path) ]]; then update_claude "$pkg"; else warn 'winget unavailable.'; fi ;;
        claude-unix) update_claude "$pkg" ;;
        script)      run_vendor_script "$pkg" ;;
        npm)         update_npm_pkg "$pkg" "$cmd" ;;
      esac
    fi
    NAMES+=("$name"); RESULTS+=("$STATUS")
  done

  echo
  printf '%-26s %s\n' Tool Result '----' '------'
  for i in "${!NAMES[@]}"; do printf '%-26s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}"; done
  report_resolution

  for r in "${RESULTS[@]}"; do [[ $r == Failed ]] && failed=$((failed + 1)); done
  echo; echo "Log: $LOG"
  echo 'Open a new terminal to use the installed CLIs.'
  if (( failed )); then warn "$failed item(s) failed. Check the log, fix the issue and rerun."; return 1; fi
  return 0
}

# ------------------------------------------------------------------ main
main() {
  set -o pipefail
  local mode=install arg
  FORCE_WINGET_CLAUDE=0 SKIP_APPS=0 SKIP_CLIS=0 NPM='' PS='' STATUS='' WG_HEX='' WG_OUT=''
  ONLY=${CAI_ONLY-} SKIP=${CAI_SKIP-}
  truthy "${CAI_PREVIEW-}" && mode=preview
  truthy "${CAI_SKIP_APPS-}" && SKIP_APPS=1
  truthy "${CAI_SKIP_CLIS-}" && SKIP_CLIS=1
  truthy "${CAI_FORCE_WINGET_CLAUDE-}" && FORCE_WINGET_CLAUDE=1

  while (( $# )); do
    arg=$1; shift
    case $arg in
      --preview) mode=preview ;;
      --list) mode=list ;;
      --only) [[ $# -gt 0 ]] || usage_error '--only needs a value'; ONLY=$1; shift ;;
      --only=*) ONLY=${arg#*=} ;;
      --skip) [[ $# -gt 0 ]] || usage_error '--skip needs a value'; SKIP=$1; shift ;;
      --skip=*) SKIP=${arg#*=} ;;
      --skip-apps) SKIP_APPS=1 ;;
      --skip-clis) SKIP_CLIS=1 ;;
      --force-winget-claude) FORCE_WINGET_CLAUDE=1 ;;
      --version) echo "$CAI_VERSION"; return 0 ;;
      -h|--help) usage; return 0 ;;
      *) usage_error "Unknown option: $arg (see --help)" ;;
    esac
  done

  detect_env
  build_catalog
  ONLY=$(norm_keys "$ONLY"); SKIP=$(norm_keys "$SKIP")
  (( SKIP_APPS )) && SKIP="${SKIP:+$SKIP,}apps"
  (( SKIP_CLIS )) && SKIP="${SKIP:+$SKIP,}clis"
  validate_keys --only "$ONLY"
  validate_keys --skip "$SKIP"

  if [[ $mode == list ]]; then cmd_list; return 0; fi

  local entry key group name kind pkg scope cmd
  SELECTED=() NEEDS_WINGET=0
  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r key group name kind pkg scope cmd <<<"$entry"
    is_selected "$key" "$group" || continue
    SELECTED+=("$entry")
    if (( HAS_WINDOWS )); then
      [[ $kind == winget ]] && NEEDS_WINGET=1
      if [[ $kind == claude-win ]] && { [[ ! -x $(native_claude_path) ]] || (( FORCE_WINGET_CLAUDE )); }; then
        NEEDS_WINGET=1
      fi
    fi
  done
  (( ${#SELECTED[@]} )) || usage_error 'Nothing selected. Check --only / --skip (see --list).'

  if [[ $mode == preview ]]; then cmd_preview; return; fi
  cmd_install
}

main "$@"
