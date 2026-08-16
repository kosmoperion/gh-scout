#!/usr/bin/env bash
#
# gh-scout search core — the deterministic, token-heavy half of the skill.
# Takes a list of search queries, runs each against GitHub, then merges,
# dedupes, scores, and returns a ranked JSON shortlist. All the *judgment*
# (which queries to run, reading READMEs, categorizing) lives in SKILL.md;
# this script only does the mechanical part so results are reproducible.
#
# Usage:
#   search.sh [--limit N] [--min-stars N] [--top N] [--pushed-after YYYY-MM-DD] \
#             "query one" "query two" ...
#
# Each positional arg is a full GitHub search query and may include qualifiers,
# e.g.  "vector database language:python stars:>200"
#
# Output: JSON array on stdout, ranked best-first. A short run log goes to stderr.

set -uo pipefail

LIMIT=30          # results fetched per query
MIN_STARS=0       # drop repos below this before ranking
TOP=15            # size of the final shortlist
PUSHED_AFTER=""   # optional recency floor applied to every query
EXCLUDE=""        # case-insensitive regex; drop repos whose name/description match

QUERIES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)         LIMIT="$2"; shift 2 ;;
    --min-stars)     MIN_STARS="$2"; shift 2 ;;
    --top)           TOP="$2"; shift 2 ;;
    --pushed-after)  PUSHED_AFTER="$2"; shift 2 ;;
    --exclude)       EXCLUDE="$2"; shift 2 ;;
    --) shift; QUERIES+=("$@"); break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  QUERIES+=("$1"); shift ;;
  esac
done

if [[ ${#QUERIES[@]} -eq 0 ]]; then
  echo "error: no queries given" >&2
  echo "usage: search.sh [--limit N] [--min-stars N] [--top N] [--pushed-after DATE] \"query\" ..." >&2
  exit 2
fi

for pair in "limit:$LIMIT" "min-stars:$MIN_STARS" "top:$TOP"; do
  if ! [[ "${pair#*:}" =~ ^[0-9]+$ ]]; then
    echo "error: --${pair%%:*} must be a non-negative integer (got '${pair#*:}')" >&2
    exit 2
  fi
done

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

FIELDS="fullName,description,stargazersCount,pushedAt,createdAt,url,language,license,isArchived,forksCount,openIssuesCount"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

i=0
for q in "${QUERIES[@]}"; do
  fullq="$q"
  [[ -n "$PUSHED_AFTER" ]] && fullq="$q pushed:>$PUSHED_AFTER"
  if gh search repos "$fullq" --sort stars --limit "$LIMIT" --json "$FIELDS" \
        > "$tmp/r$i.json" 2>"$tmp/e$i.log"; then
    n=$(jq 'length' "$tmp/r$i.json" 2>/dev/null || echo 0)
    echo "  [$((i+1))/${#QUERIES[@]}] ${n:-0} hits  ·  $fullq" >&2
  else
    echo "[]" > "$tmp/r$i.json"
    echo "  [$((i+1))/${#QUERIES[@]}] FAILED       ·  $fullq  ($(head -1 "$tmp/e$i.log"))" >&2
  fi
  i=$((i+1))
done

# Merge every query's results, dedupe by repo, score, and flag for review.
#   score = ln(stars+1) × recency × query_hits × archived_penalty × spam_penalty
# query_hits = how many distinct queries surfaced the repo (cross-referencing
# is a strong relevance signal), so a repo found by 4 angles outranks a
# higher-starred repo found by only 1. On niche domains expect hits=1 across
# the board — that's normal; judge those by README, not by score.
#
# reviewFlags are cheap numeric hints, not verdicts — they mark repos worth a
# human/model glance in the README-enrich step, they never silently drop a repo.
result="$(jq -s --arg ex "$EXCLUDE" --argjson minStars "$MIN_STARS" --argjson top "$TOP" '
  add
  | map(select(.stargazersCount >= $minStars))
  | ( if $ex == "" then .
      else map(select(((.fullName // "") + " " + (.description // "")) | test($ex; "i") | not))
      end )
  | group_by(.fullName)
  | map({
      fullName:    .[0].fullName,
      description: .[0].description,
      url:         .[0].url,
      stars:       .[0].stargazersCount,
      forks:       .[0].forksCount,
      openIssues:  .[0].openIssuesCount,
      language:    .[0].language,
      license:     (.[0].license.key // "none"),
      archived:    .[0].isArchived,
      pushedAt:    .[0].pushedAt,
      createdAt:   .[0].createdAt,
      hits:        length
    })
  | map(. + {
      ageDays:  ((now - ((.pushedAt  // "1970-01-01T00:00:00Z") | fromdateiso8601)) / 86400),
      lifeDays: ((now - ((.createdAt // "1970-01-01T00:00:00Z") | fromdateiso8601)) / 86400)
    })
  | map(. + {
      recency:      (if .ageDays < 183 then 1.0 elif .ageDays < 365 then 0.7 elif .ageDays < 730 then 0.4 else 0.15 end),
      forkRatio:    ((.forks / (.stars + 1)) * 100 | round / 100),
      starVelocity: ((.stars / (if .lifeDays < 1 then 1 else .lifeDays end)) * 10 | round / 10)
    })
  | map(. + {
      reviewFlags: (
        []
        + (if .starVelocity > 25 and .stars > 300 then ["fast-star-growth"] else [] end)
        + (if .forkRatio > 1.0                     then ["unusual-fork-ratio"] else [] end)
        + (if .recency == 0.15                     then ["stale"] else [] end)
        + (if .archived                            then ["archived"] else [] end)
      )
    })
  | map(. + {
      score: (
        ((.stars + 1) | log) * .recency * .hits
        * (if .archived then 0.3 else 1 end)
        * (if (.reviewFlags | map(. == "fast-star-growth" or . == "unusual-fork-ratio") | any) then 0.6 else 1 end)
        * 100 | round / 100
      )
    })
  | sort_by(-.score)
  | .[0:$top]
' "$tmp"/r*.json)"

printf '%s\n' "$result"

printf '%s' "$result" | jq -r '
  "  summary: \(length) repos · max query_hits \([.[].hits] | max // 0) (1 = no cross-referencing, judge by README) · \([.[] | select(.reviewFlags | length > 0)] | length) flagged for review"
' >&2
