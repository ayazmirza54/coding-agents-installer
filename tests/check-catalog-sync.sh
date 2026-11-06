#!/usr/bin/env bash
# Fails when install.sh and install.ps1 disagree on tool keys, Windows package
# IDs or version. Run from the repository root: bash tests/check-catalog-sync.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# install.sh catalog lines: 'key|group|Name|kind|package|scope|command'
sh_entries() { grep -E "^[[:space:]]*'[a-z0-9-]+\|(cli|app)\|" install.sh | sed -E "s/^[[:space:]]*'//; s/'.*$//"; }
sh_keys=$(sh_entries | cut -d'|' -f1 | sort -u)
sh_ids=$(sh_entries | awk -F'|' '$4 == "winget" || $4 == "claude-win" { print $5 }' | sort -u)
sh_version=$(sed -n 's/^CAI_VERSION=//p' install.sh)

ps_lines() { grep -E "Key = '" install.ps1; }
ps_keys=$(ps_lines | sed -E "s/.*Key = '([^']+)'.*/\1/" | sort -u)
ps_ids=$(ps_lines | grep -E "Kind = '(winget|claude)'" | sed -E "s/.*Package = '([^']+)'.*/\1/" | sort -u)
ps_version=$(sed -n "s/.*\$caiVersion = '\([^']*\)'.*/\1/p" install.ps1)

fail=0
compare() {   # label a b
  if [[ "$2" != "$3" ]]; then
    echo "MISMATCH: $1"
    diff <(echo "$2") <(echo "$3") | sed 's/^/  /' || true
    fail=1
  else
    echo "ok: $1 ($(echo "$2" | wc -l | tr -d ' ') entries)"
  fi
}
compare 'tool keys (install.sh vs install.ps1)' "$sh_keys" "$ps_keys"
compare 'Windows winget IDs (install.sh vs install.ps1)' "$sh_ids" "$ps_ids"
compare 'version' "$sh_version" "$ps_version"
exit "$fail"
