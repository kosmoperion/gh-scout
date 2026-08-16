#!/usr/bin/env bash
#
# npm registry adapter — npm's own popularity/maintenance scores and real
# monthly download counts are a truer adoption signal than GitHub stars.
#
# Usage: npm.sh [--size N] "query" ["query2" …]
# Output: normalized JSON array on stdout. Records with a resolvable GitHub
# repo get repo/url pointed at GitHub; otherwise they point at the npm page
# and repo stays null (merge.sh drops repo=null records, so package-only
# hits are visible here but won't survive into the merged shortlist yet).

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
  echo "usage: npm.sh [--size N] \"query\" ..." >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

i=0
for q in "${QUERIES[@]}"; do
  eq="$(jq -rn --arg s "$q" '$s | @uri')"
  gs_get "https://registry.npmjs.org/-/v1/search?text=$eq&size=$SIZE" > "$tmp/s$i.json" 2>/dev/null
  n=$(jq '.objects | length' "$tmp/s$i.json" 2>/dev/null || echo 0)
  echo "  [$((i+1))/${#QUERIES[@]}] ${n:-0} hits  ·  $q" >&2
  i=$((i+1))
done

# Flatten + dedupe by package name before hitting the downloads endpoint —
# no point fetching the same package's downloads twice across queries.
jq -s '[.[].objects[]] | unique_by(.package.name)' "$tmp"/s*.json > "$tmp/pkgs.json"
pkg_count=$(jq 'length' "$tmp/pkgs.json")
echo "  fetching downloads for $pkg_count unique packages…" >&2

jq -c '.[]' "$tmp/pkgs.json" | while read -r row; do
  pkg="$(jq -r '.package.name' <<<"$row")"
  dl_raw="$(gs_get "https://api.npmjs.org/downloads/point/last-month/$pkg" 2>/dev/null)"
  dl="$(jq '.downloads // null' <<<"$dl_raw" 2>/dev/null)"
  [[ -z "$dl" || "$dl" == "null" ]] && dl=null
  repo_url="$(jq -r '.package.links.repository // ""' <<<"$row")"
  slug="$(gs_repo_slug "$repo_url")"
  jq -n --argjson row "$row" --arg slug "$slug" --argjson dl "${dl:-null}" '
    ($row.package) as $p
    | {
        repo:         (if $slug == "" then null else $slug end),
        url:          (if $slug == "" then ("https://www.npmjs.com/package/" + $p.name) else ("https://github.com/" + $slug) end),
        source:       "npm",
        description:  $p.description,
        language:     "JavaScript",
        stars:        null,
        downloads30d: $dl,
        scorecard:    null,
        pushedAt:     $p.date,
        package:      { registry: "npm", name: $p.name },
        sourceSignals: { npmPopularity: $row.score.detail.popularity, npmMaintenance: $row.score.detail.maintenance }
      }'
done | jq -s '.'
