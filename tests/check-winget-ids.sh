#!/usr/bin/env bash
# Checks that every winget ID used by the installers still exists in the
# community repository (microsoft/winget-pkgs). Works without winget, so CI on
# any runner catches renamed or removed packages.
# Set GITHUB_TOKEN to avoid the anonymous API rate limit.
set -euo pipefail
cd "$(dirname "$0")/.."

ids=$( { grep -E "Package = '" install.ps1 | sed -E "s/.*Package = '([^']+)'.*/\1/"
         sed -n "s/^\$nodePackage = '\([^']*\)'.*/\1/p" install.ps1; } |
       grep -E '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' | sort -u)

auth=()
[[ -n ${GITHUB_TOKEN-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

missing=0
for id in $ids; do
  first=$(printf '%s' "${id:0:1}" | tr '[:upper:]' '[:lower:]')
  path="manifests/$first/${id//.//}"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" \
         "https://api.github.com/repos/microsoft/winget-pkgs/contents/$path")
  case $code in
    200) echo "ok       $id" ;;
    404) echo "MISSING  $id ($path)"; missing=1 ;;
    *)   echo "ERROR    $id: GitHub API returned HTTP $code"; missing=1 ;;
  esac
done
exit "$missing"
