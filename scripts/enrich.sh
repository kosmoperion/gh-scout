#!/usr/bin/env bash
#
# enrich.sh — fills in stars/pushedAt/license/description for records that
# arrived without them (github_code.sh, awesome_extract.sh, npm.sh, crates.sh
# all emit star-less records — only search.sh's native output has stars).
# Also adds the deps.dev OpenSSF scorecard, an opportunistic health signal:
# present for some repos (kubernetes/kubernetes -> 7.6), null for others
# (qdrant/qdrant -> null) — this is normal, not an error, and every downstream
# consumer must handle scorecard:null.
#
# This is the rate-limit-heavy step: one `gh api` + one deps.dev call per repo
# with a resolvable slug. Cap input to your real shortlist (~25 records) before
# calling this — don't enrich a raw, unfiltered source dump.
#
# Usage: enrich.sh normalized.json   (reads a JSON array, writes an enriched
#        JSON array of the same records to stdout)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$DIR/lib/common.sh"

INPUT="${1:-}"
if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo "error: usage: enrich.sh normalized.json" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

n_total=$(jq 'length' "$INPUT")
i=0

jq -c '.[]' "$INPUT" | while read -r row; do
  i=$((i+1))
  slug="$(jq -r '.repo // ""' <<<"$row")"

  if [[ -n "$slug" ]]; then
    gh_json="$(gh api "repos/$slug" \
      --jq '{stars: .stargazers_count, pushedAt: .pushed_at, language: .language, license: (.license.spdx_id // "none"), description: .description, archived: .archived}' \
      2>/dev/null)"
    [[ -z "$gh_json" ]] && gh_json='{}'

    enc_slug="$(printf '%s' "$slug" | sed 's#/#%2F#')"
    sc_json="$(gs_get "https://api.deps.dev/v3/projects/github.com%2F$enc_slug" 2>/dev/null)"
    scorecard="$(jq '.scorecard.overallScore // null' <<<"$sc_json" 2>/dev/null)"
    [[ -z "$scorecard" ]] && scorecard=null

    echo "  [$i/$n_total] enriched $slug" >&2
  else
    gh_json='{}'
    scorecard=null
    echo "  [$i/$n_total] no repo slug, skipped (package-only record)" >&2
  fi

  jq -n --argjson row "$row" --argjson gh "$gh_json" --argjson sc "$scorecard" '
    $row
    + { stars:       ($row.stars       // $gh.stars       // null),
        pushedAt:    ($row.pushedAt    // $gh.pushedAt    // null),
        language:    ($row.language    // $gh.language    // null),
        description: ($row.description // $gh.description // null),
        scorecard:   ($row.scorecard   // $sc),
        archived:    ($row.archived    // $gh.archived    // false) }
  '
done | jq -s '.'
