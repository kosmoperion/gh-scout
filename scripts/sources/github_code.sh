#!/usr/bin/env bash
#
# GitHub code-search adapter — finds repos that *use or implement* a capability
# without describing it in their README, which repo search misses entirely.
# Code search has a tighter rate limit than repo search, so keep --limit low
# and callers to 3-4 queries per run.
#
# Usage: github_code.sh [--limit N] "query" ["query2" …]
# Output: normalized JSON array on stdout, one record per unique repo, with
#         sourceSignals.codeHits = number of matching files seen for that repo.

set -uo pipefail

LIMIT=20
QUERIES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  QUERIES+=("$1"); shift ;;
  esac
done

if [[ ${#QUERIES[@]} -eq 0 ]]; then
  echo "error: no queries given" >&2
  echo "usage: github_code.sh [--limit N] \"query\" ..." >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

i=0
for q in "${QUERIES[@]}"; do
  if gh search code "$q" --limit "$LIMIT" --json repository,path \
        > "$tmp/r$i.json" 2>"$tmp/e$i.log"; then
    n=$(jq 'length' "$tmp/r$i.json" 2>/dev/null || echo 0)
    echo "  [$((i+1))/${#QUERIES[@]}] ${n:-0} hits  ·  $q" >&2
  else
    echo "[]" > "$tmp/r$i.json"
    echo "  [$((i+1))/${#QUERIES[@]}] FAILED       ·  $q  ($(head -1 "$tmp/e$i.log"))" >&2
  fi
  i=$((i+1))
done

jq -s '
  add
  | map({ repo: .repository.nameWithOwner, path: .path })
  | group_by(.repo)
  | map({
      repo:         .[0].repo,
      url:          ("https://github.com/" + .[0].repo),
      source:       "github-code",
      description:  null,
      language:     null,
      stars:        null,
      downloads30d: null,
      scorecard:    null,
      pushedAt:     null,
      package:      null,
      sourceSignals: { codeHits: length }
    })
' "$tmp"/r*.json
