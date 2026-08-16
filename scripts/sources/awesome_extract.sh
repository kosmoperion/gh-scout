#!/usr/bin/env bash
#
# Awesome-list extractor — human-curated lists are the highest signal-to-noise
# source on GitHub. This is a two-step, mostly model-orchestrated pattern: find
# the list repo yourself (e.g. `gh search repos "awesome <topic>"`), then feed
# its owner/name here to pull out every repo it links to.
#
# Usage: awesome_extract.sh owner/awesome-repo
# Output: normalized JSON array, one record per unique linked GitHub repo.
# Extraction is deliberately greedy (any github.com/x/y link in the README);
# enrich.sh and the model's README pass do the real filtering downstream.

set -uo pipefail

REPO="${1:-}"
MAX=40

if [[ -z "$REPO" ]]; then
  echo "error: no repo given" >&2
  echo "usage: awesome_extract.sh owner/awesome-repo" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }

readme="$(gh api "repos/$REPO/readme" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)"
if [[ -z "$readme" ]]; then
  echo "error: could not fetch README for $REPO" >&2
  echo "[]"
  exit 0
fi

# Exclude the list's own owner and generic "awesome"/"sindresorhus" meta-repos
# so the curator's own profile doesn't pollute its own extracted list.
self_owner="$(cut -d/ -f1 <<<"$REPO" | tr '[:upper:]' '[:lower:]')"

printf '%s\n' "$readme" \
  | grep -oiE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
  | sed -E 's#github\.com/##; s#\.git$##' \
  | grep -viE '^(sindresorhus|awesome)(/|$)' \
  | grep -viE "^${self_owner}/" \
  | sort -u \
  | head -n "$MAX" \
  | jq -R '{
      repo: .,
      url: ("https://github.com/" + .),
      source: "awesome",
      description: null,
      language: null,
      stars: null,
      downloads30d: null,
      scorecard: null,
      pushedAt: null,
      package: null,
      sourceSignals: { curatedBy: "'"$REPO"'" }
    }' \
  | jq -s '.'
