#!/usr/bin/env bash
#
# Hacker News (Algolia) adapter — "Show HN" traction and comment volume are a
# community-validation signal GitHub's own index doesn't have, and surface
# tools that are talked about more than they're keyword-matched. Only story
# posts that link directly to a GitHub repo are kept; everything else (blog
# posts, HN self-posts, non-GitHub links) is discarded here since it can't be
# merged/scored against the rest of the pipeline.
#
# Note: the Algolia HN API requires https — the plain-http endpoint returns
# an empty body (verified), so this always calls the https host.
#
# Usage: hn.sh "query" ["query2" …]
# Output: normalized JSON array on stdout.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
. "$DIR/../lib/common.sh"

QUERIES=("$@")
if [[ ${#QUERIES[@]} -eq 0 ]]; then
  echo "error: no queries given" >&2
  echo "usage: hn.sh \"query\" [\"query2\" ...]" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

i=0
for q in "${QUERIES[@]}"; do
  eq="$(jq -rn --arg s "$q" '$s | @uri')"
  gs_get "https://hn.algolia.com/api/v1/search?query=$eq&tags=story&hitsPerPage=25" \
    > "$tmp/h$i.json" 2>/dev/null
  n=$(jq '.hits | length' "$tmp/h$i.json" 2>/dev/null || echo 0)
  echo "  [$((i+1))/${#QUERIES[@]}] ${n:-0} hits  ·  $q" >&2
  i=$((i+1))
done

jq -s '
  [.[].hits[]]
  | map(select(.url != null and (.url | test("github\\.com/[^/]+/[^/]+"; "i"))))
  | map(. + { _repo: (.url | (capture("github\\.com/(?<s>[^/]+/[^/#?]+)"; "i").s) // null) })
  | map(select(._repo != null))
  | group_by(._repo)
  | map(
      (map(.points // 0) | max) as $maxPoints
      | (map(.num_comments // 0) | max) as $maxComments
      | {
          repo:         .[0]._repo,
          url:          ("https://github.com/" + .[0]._repo),
          source:       "hn",
          description:  .[0].title,
          language:     null,
          stars:        null,
          downloads30d: null,
          scorecard:    null,
          pushedAt:     null,
          package:      null,
          sourceSignals: { hnPoints: $maxPoints, hnComments: $maxComments, hnStoryHits: length }
        }
    )
' "$tmp"/h*.json
