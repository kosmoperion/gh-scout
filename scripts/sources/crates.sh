#!/usr/bin/env bash
#
# crates.io adapter — Rust equivalent of npm.sh. crates.io 403s without a
# User-Agent header (verified), which is why this goes through gs_get rather
# than a bare curl. crates.io also asks API consumers to keep to ~1 req/s.
#
# Usage: crates.sh [--size N] "query" ["query2" …]
# Output: normalized JSON array on stdout.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
. "$DIR/../lib/common.sh"

SIZE=15
QUERIES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE="$2"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  QUERIES+=("$1"); shift ;;
  esac
done

if [[ ${#QUERIES[@]} -eq 0 ]]; then
  echo "error: no queries given" >&2
  echo "usage: crates.sh [--size N] \"query\" ..." >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

i=0
for q in "${QUERIES[@]}"; do
  eq="$(jq -rn --arg s "$q" '$s | @uri')"
  gs_get "https://crates.io/api/v1/crates?q=$eq&per_page=$SIZE" > "$tmp/c$i.json" 2>/dev/null
  n=$(jq '.crates | length' "$tmp/c$i.json" 2>/dev/null || echo 0)
  echo "  [$((i+1))/${#QUERIES[@]}] ${n:-0} hits  ·  $q" >&2
  i=$((i+1))
  [[ $i -lt ${#QUERIES[@]} ]] && sleep 1   # crates.io politeness: ~1 req/s
done

jq -s '
  [.[].crates[]]
  | unique_by(.id)
  | map(((.repository // "") | sub("^git\\+";"") | sub("\\.git$";"")) as $clean
      | {
      repo:         (($clean | (capture("github\\.com[:/]+(?<s>[^/]+/[^/#?]+)"; "i").s)) // null),
      url:          (if $clean == "" then ("https://crates.io/crates/" + .name) else $clean end),
      source:       "crates",
      description:  .description,
      language:     "Rust",
      stars:        null,
      downloads30d: .recent_downloads,
      scorecard:    null,
      pushedAt:     .updated_at,
      package:      { registry: "cargo", name: .name },
      sourceSignals: { totalDownloads: .downloads, newestVersion: .newest_version }
    })
' "$tmp"/c*.json
