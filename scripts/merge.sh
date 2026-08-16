#!/usr/bin/env bash
#
# merge.sh — dedupes normalized records across sources (search.sh mapped to
# normalized form, github_code.sh, awesome_extract.sh, npm.sh, crates.sh, …)
# and re-scores.
#
# Adoption-aware scoring: popularity = max(ln(stars+1), ln(downloads+1)*0.5),
# so a heavily-downloaded package with few stars (e.g. a 400-star lib pulling
# 2M downloads/month) still outranks a stale high-star repo — stars alone
# measure hype and age, not current use. scorecard (OpenSSF health, 0-10,
# often null — see enrich.sh) is a mild multiplier, never a gate.
#
# Usage: merge.sh normalized1.json normalized2.json …   (each a JSON array
#        of records in the gh-scout normalized shape; records with repo=null
#        are dropped — they can't be deduped or scored against GitHub data)
#
# Output: single ranked JSON array on stdout.

set -uo pipefail

if [[ $# -eq 0 ]]; then
  echo "error: no input files given" >&2
  echo "usage: merge.sh normalized1.json normalized2.json ..." >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

jq -s '
  add
  | map(select(.repo != null and .repo != ""))
  | group_by(.repo)
  | map(
      (map(.source) | unique) as $sources
      | .[0]
      + { sources: $sources, source_hits: ($sources | length) }
      + { stars:        ([.[].stars]        | map(select(. != null)) | max) }
      + { downloads30d: ([.[].downloads30d] | map(select(. != null)) | max // null) }
      + { scorecard:    ([.[].scorecard]    | map(select(. != null)) | max // null) }
      + { pushedAt:     ([.[].pushedAt]     | map(select(. != null)) | first // null) }
      + { description:  ([.[].description]  | map(select(. != null)) | first // null) }
      + { language:     ([.[].language]     | map(select(. != null)) | first // null) }
    )
  | map(. + {
      ageDays: (if .pushedAt then
          ((now - (.pushedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400)
        else 9999 end)
    })
  | map(. + {
      recency: (
        if   .ageDays < 183 then 1.0
        elif .ageDays < 365 then 0.7
        elif .ageDays < 730 then 0.4
        else 0.15 end)
    })
  | map(. + {
      popularity: (
        [ (((.stars // 0) + 1) | log),
          (((.downloads30d // 0) + 1 | log) * 0.5) ]
        | max
      )
    })
  | map(. + {
      score: (
        (.popularity * .recency * .source_hits
          * (if .scorecard then (1 + (.scorecard / 10) * 0.2) else 1 end))
        * 100 | round / 100
      )
    })
  | sort_by(-.score)
' "$@"
