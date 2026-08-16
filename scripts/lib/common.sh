#!/usr/bin/env bash
#
# Shared helpers for gh-scout source adapters: a polite cached GET, and the
# repo-URL normalizer every adapter needs (npm/crates give back messy URLs
# like git+https://github.com/owner/repo.git#readme).

GH_SCOUT_UA="gh-scout/1.0 (+github repo recon skill)"
CACHE_DIR="${GH_SCOUT_CACHE:-$HOME/.claude/skills/gh-scout/.cache}"
GH_SCOUT_CACHE_TTL="${GH_SCOUT_CACHE_TTL:-21600}"   # cache lifetime in seconds (default 6h)
mkdir -p "$CACHE_DIR"

# Hash a string to a stable hex key, using whichever hasher exists. shasum is
# present on macOS and most Linux (via perl); sha1sum/md5sum cover the rest, and
# cksum is the POSIX last resort — so this works on a bare box with none of the
# above installed.
_gs_hash() {
  if   command -v shasum   >/dev/null 2>&1; then shasum          | cut -d' ' -f1
  elif command -v sha1sum  >/dev/null 2>&1; then sha1sum         | cut -d' ' -f1
  elif command -v md5sum   >/dev/null 2>&1; then md5sum          | cut -d' ' -f1
  else                                           cksum           | cut -d' ' -f1
  fi
}

# File modification time as a Unix epoch, portable across macOS (stat -f) and
# GNU/Linux (stat -c). Prints 0 if the file is missing.
_gs_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Cached GET with a User-Agent, keyed by URL, with a configurable TTL. Only
# successful, non-empty responses are cached — a transient network error or an
# HTTP error (curl -f) never poisons the cache, and a stale entry is served as a
# fallback if a refresh fails. Usage: gs_get "https://…"
gs_get() {
  local url="$1" key file age tmp
  key="$(printf '%s' "$url" | _gs_hash)"
  file="$CACHE_DIR/$key.json"

  if [[ -f "$file" ]]; then
    age=$(( $(date +%s) - $(_gs_mtime "$file") ))
    if [[ $age -lt $GH_SCOUT_CACHE_TTL ]]; then
      cat "$file"
      return 0
    fi
  fi

  tmp="$(mktemp)"
  if curl -sf --max-time 20 -H "User-Agent: $GH_SCOUT_UA" "$url" -o "$tmp" && [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$file"
    cat "$file"
    return 0
  fi

  # Refresh failed: fall back to a stale cache entry if we have one.
  rm -f "$tmp"
  if [[ -f "$file" ]]; then
    cat "$file"
    return 0
  fi
  return 1
}

# Reduce any repo URL/string to owner/name, or print nothing if it's not a
# GitHub URL. Strips git+ prefixes, .git suffixes, and #anchors/query strings.
# Usage: gs_repo_slug "git+https://github.com/lancedb/lancedb.git"
gs_repo_slug() {
  printf '%s' "$1" \
    | sed -E 's#^git\+##; s#\.git$##; s/#.*$//; s/\?.*$//' \
    | sed -nE 's#.*github\.com[:/]+([^/]+)/([^/]+).*#\1/\2#p'
}

# Map search.sh's output shape (fullName/hits/…) into the gh-scout normalized
# record shape that merge.sh expects, so GitHub repo-search results can be
# merged with the other sources. Usage: search.sh ... | gs_to_normalized
gs_to_normalized() {
  jq '
    map({
      repo:         .fullName,
      url:          .url,
      source:       "github-repos",
      description:  .description,
      language:     .language,
      stars:        .stars,
      downloads30d: null,
      scorecard:    null,
      pushedAt:     .pushedAt,
      package:      null,
      sourceSignals: { queryHits: .hits, reviewFlags: (.reviewFlags // []) }
    })
  '
}
