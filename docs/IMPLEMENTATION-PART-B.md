# gh-scout — Part B Implementation Plan (more sources)

Part A made the single GitHub-repo-search source smarter. Part B adds **more
sources** so discovery isn't bottlenecked on one keyword index, and so ranking can
use **real adoption signals** (download counts, health scores) instead of stars alone.

Every API shape below was probed live before writing this plan. Where something
did **not** work, it's marked and designed around — not assumed.

---

## Design principle (carried from Part A, extended)

> The script computes cheap objective signals; the model does prose judgment.

Part B adds one more rule:

> **Every source emits the same normalized record.** Discovery sources add
> candidates; enrichment sources add signals to existing candidates. One merge
> step dedupes across all of them and re-scores. No source has a bespoke ranking.

This is what keeps five sources from becoming five special cases.

---

## The normalization contract (keystone — build this first)

Every adapter prints a JSON array of records in this exact shape. Unknown fields
are `null`; the merge/enrich steps fill them in later.

```json
{
  "repo":         "owner/name",        // dedup key; null if source has no repo
  "url":          "https://github.com/owner/name",
  "source":       "github-code",       // provenance: github-repos|github-code|npm|crates|hn|awesome
  "description":  "…",
  "language":     null,
  "stars":        null,
  "downloads30d": null,                // packages: last-30-day downloads (adoption)
  "scorecard":    null,                // OpenSSF 0–10 (health), from deps.dev, often null
  "pushedAt":     null,
  "package":      { "registry": "npm", "name": "foo" },  // null for pure repos
  "sourceSignals": { }                 // freeform per source (codeHits, hnPoints, npmPopularity)
}
```

**Repo-URL normalizer** (needed everywhere — npm gives `git+https://…/owner/repo.git`,
crates gives `https://github.com/owner/repo`): strip `git+`, a trailing `.git`,
any `#readme`/anchor, and reduce to `owner/name`. Ships in `lib/common.sh` (B0).

---

## Verified API reference (probed live 2026-08-16)

| Source | Endpoint | Key fields | Auth | Notes |
|--------|----------|-----------|------|-------|
| npm search | `registry.npmjs.org/-/v1/search?text=Q&size=N` | `objects[].package.{name,links.repository,description}`, `objects[].score.detail.{popularity,quality,maintenance}`, `searchScore` | none | ✅ repo needs normalizing |
| npm downloads | `api.npmjs.org/downloads/point/last-month/PKG` | `.downloads` | none | ✅ adoption signal |
| crates.io | `crates.io/api/v1/crates?q=Q&per_page=N` | `crates[].{name,downloads,recent_downloads,repository,newest_version}` | none | ✅ **requires `User-Agent` header** |
| deps.dev project | `api.deps.dev/v3/projects/github.com%2Fowner%2Frepo` | `.starsCount,.forksCount,.license,.openIssuesCount,.scorecard.overallScore` | none | ✅ scorecard **often null** (present: k8s 7.6; null: qdrant) — treat as opportunistic |
| deps.dev dependents | — | — | — | ❌ **404 on all path variants — dropped from plan** |
| HN Algolia | `hn.algolia.com/api/v1/search?query=Q&tags=story&hitsPerPage=N` | `hits[].{title,url,points,num_comments,objectID}` | none | ✅ **https only** (http returned empty) |
| GitHub code | `gh search code "Q" --limit N --json path,repository,sha` | `[].repository.nameWithOwner`, `.path` | gh auth | ✅ stricter rate limit than repo search |
| Hugging Face | MCP `hub_repo_search` | models/datasets/spaces | MCP | ✅ conditional (ML domains) |

---

## File layout after Part B

```
scripts/
├── search.sh              # (Part A) GitHub repo discovery + scorer — unchanged core
├── lib/
│   └── common.sh          # B0: curl-with-UA+cache, repo-url normalizer, to-normalized mapper
├── sources/
│   ├── github_code.sh     # B1
│   ├── npm.sh             # B3
│   ├── crates.sh          # B4
│   ├── hn.sh              # B6
│   └── awesome_extract.sh # B2
├── enrich.sh              # B5: deps.dev scorecard + download counts + package→repo resolve
└── merge.sh               # B7: dedupe across sources, cross-source source_hits, adoption re-score
```

---

## Change inventory & phasing

Build in three phases. **Phase 1 delivers most of the discovery breadth; Phase 2
delivers the "stars ≠ adoption" fix; Phase 3 is coverage + polish.** Each phase is
independently shippable.

| ID | Item | File | Phase |
|----|------|------|-------|
| B0 | `lib/common.sh` — curl wrapper (UA + cache), repo-URL normalizer, search.sh→normalized mapper | new | 1 |
| B1 | GitHub code-search adapter | sources/github_code.sh | 1 |
| B2 | Awesome-list extractor | sources/awesome_extract.sh | 1 |
| B7a | `merge.sh` — dedupe + cross-source `source_hits` (no adoption yet) | merge.sh | 1 |
| S-B1 | SKILL.md: multi-source orchestration step + source-routing table | SKILL.md | 1 |
| B3 | npm search adapter | sources/npm.sh | 2 |
| B4 | crates.io adapter | sources/crates.sh | 2 |
| B5 | `enrich.sh` — deps.dev scorecard + downloads + package→repo resolve | enrich.sh | 2 |
| B7b | `merge.sh` — adoption-aware scoring (downloads + scorecard) | merge.sh | 2 |
| S-B2 | SKILL.md: digest shows downloads/scorecard/source_hits; adoption-led ranking | SKILL.md | 2 |
| B6 | HN Algolia adapter | sources/hn.sh | 3 |
| S-B3 | SKILL.md: WebSearch orchestration + Hugging Face (conditional) + reverse-discovery step | SKILL.md | 3 |

---

## Phase 1 — discovery breadth

### B0 — `lib/common.sh`

Shared helpers every adapter sources. Politeness + one place for the normalizer.

```bash
#!/usr/bin/env bash
# Shared helpers for gh-scout source adapters.
GH_SCOUT_UA="gh-scout/1.0 (+github repo recon skill)"
CACHE_DIR="${GH_SCOUT_CACHE:-$HOME/.claude/skills/gh-scout/.cache}"
mkdir -p "$CACHE_DIR"

# Cached GET with UA. 6h TTL. Usage: gs_get "https://…"
gs_get() {
  local url="$1" key file age
  key="$(printf '%s' "$url" | shasum | cut -d' ' -f1)"
  file="$CACHE_DIR/$key.json"
  if [[ -f "$file" ]]; then
    age=$(( $(date +%s) - $(stat -f %m "$file") ))
    [[ $age -lt 21600 ]] && { cat "$file"; return 0; }
  fi
  curl -s --max-time 20 -H "User-Agent: $GH_SCOUT_UA" "$url" | tee "$file"
}

# Reduce any repo URL to owner/name (or empty). Handles git+…/…​.git and #anchors.
gs_repo_slug() {
  printf '%s' "$1" \
    | sed -E 's#^git\+##; s#\.git$##; s/#.*$//' \
    | sed -nE 's#.*github\.com[:/]+([^/]+)/([^/]+).*#\1/\2#p'
}
```

**Verify:** `source lib/common.sh; gs_repo_slug 'git+https://github.com/lancedb/lancedb.git'`
→ `lancedb/lancedb`.

### B1 — `sources/github_code.sh`

**Why.** Finds repos that *implement or use* a thing but don't say so in their
README (repo search misses these). Evidence: `gh search code "milvus vector"`
surfaced `zylon-ai/private-gpt`, `nlweb-ai/NLWeb` — integration code, not libraries
that would rank on description alone.

```bash
#!/usr/bin/env bash
# Usage: github_code.sh [--limit N] "query" ["query2" …]
# Emits normalized records: unique repos, with codeHits = matching files seen.
set -uo pipefail
LIMIT=20; QUERIES=()
while [[ $# -gt 0 ]]; do case "$1" in
  --limit) LIMIT="$2"; shift 2;; *) QUERIES+=("$1"); shift;; esac; done

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for q in "${QUERIES[@]}"; do
  gh search code "$q" --limit "$LIMIT" --json repository,path 2>/dev/null >> "$tmp" || true
done
jq -s '
  add // []
  | map({ repo: .repository.nameWithOwner, path: .path })
  | group_by(.repo)
  | map({
      repo:         .[0].repo,
      url:          ("https://github.com/" + .[0].repo),
      source:       "github-code",
      description:  null, language: null, stars: null,
      downloads30d: null, scorecard: null, pushedAt: null, package: null,
      sourceSignals: { codeHits: length }
    })
' "$tmp"
```

**Note.** Code search has a stricter rate limit than repo search — cap `--limit`
low and keep to 3–4 queries. Records come back star-less; `enrich.sh` (Phase 2)
fills stars/pushedAt, so in Phase 1 these ride on `source_hits` corroboration only.

### B2 — `sources/awesome_extract.sh`

**Why.** Human-curated `awesome-*` lists are the highest signal-to-noise source on
GitHub. Two-step, mostly model-orchestrated: the model finds the list repo
(`gh search repos "awesome <topic>"`), this script extracts the repos it links.

```bash
#!/usr/bin/env bash
# Usage: awesome_extract.sh owner/awesome-repo
# Fetches the README and emits a normalized record per linked GitHub repo.
set -uo pipefail
REPO="$1"
gh api "repos/$REPO/readme" --jq '.content' 2>/dev/null | base64 -d \
  | grep -oiE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
  | sed -E 's#github\.com/##; s#\.git$##' \
  | grep -viE '^(sindresorhus|awesome)' \
  | sort -u \
  | jq -R '{
      repo: ., url: ("https://github.com/" + .), source: "awesome",
      description: null, language: null, stars: null, downloads30d: null,
      scorecard: null, pushedAt: null, package: null,
      sourceSignals: { curatedBy: "'"$REPO"'" }
    }' | jq -s '.'
```

**Note.** Extraction is deliberately greedy then deduped; `enrich.sh` + the model's
README pass filter the noise. Cap total extracted repos (e.g. `head -40`) so a
giant list doesn't blow up enrichment.

### B7a — `merge.sh` (Phase-1 form: dedupe + cross-source hits)

Consumes any number of normalized JSON arrays (from `search.sh` mapped through
`gs_to_normalized`, plus the adapters) and produces one ranked array. Phase 1 keeps
the Part-A scoring but swaps `query_hits` → `source_hits` (found across N *sources*
is even stronger corroboration than N queries).

```bash
#!/usr/bin/env bash
# Usage: merge.sh normalized1.json normalized2.json …   (each a JSON array)
set -uo pipefail
jq -s '
  add
  | group_by(.repo)
  | map(
      (map(.source) | unique) as $sources
      | .[0]
      + { sources: $sources, source_hits: ($sources | length) }
      + { stars: ([.[].stars] | map(select(. != null)) | max // 0) }
      + { downloads30d: ([.[].downloads30d] | map(select(. != null)) | max // null) }
      + { scorecard: ([.[].scorecard] | map(select(. != null)) | max // null) }
      + { pushedAt: ([.[].pushedAt] | map(select(. != null)) | first // null) }
      + { description: ([.[].description] | map(select(. != null)) | first // null) }
    )
  | map(. + { ageDays: (if .pushedAt then ((now - (.pushedAt|fromdateiso8601))/86400) else 9999 end) })
  | map(. + { recency: (if .ageDays < 183 then 1.0 elif .ageDays < 365 then 0.7 elif .ageDays < 730 then 0.4 else 0.15 end) })
  | map(. + { score: ((((.stars + 1)|log) * .recency * .source_hits) * 100 | round / 100) })
  | sort_by(-.score)
' "$@"
```

### S-B1 — SKILL.md orchestration + routing table (Phase 1 prose)

Add a new subsection after § "Run the search core":

```markdown
### 3b. Widen with additional sources

`search.sh` is the primary (GitHub repos). Add sources based on the domain, then
merge everything through `merge.sh` (dedupe + cross-source corroboration). A repo
found by repo-search AND code-search AND an awesome list is strongly corroborated.

**Source-routing table — pick by domain, don't run all of them:**

| Domain signal | Add these sources |
|---|---|
| JS / TS / web / frontend | `npm.sh`, `github_code.sh` |
| Rust | `crates.sh`, `github_code.sh` |
| Python / Go library | `github_code.sh`, `enrich.sh` (deps.dev), WebSearch |
| ML / AI | Hugging Face (`hub_repo_search`), repo search, WebSearch |
| CLI tool | `npm.sh` / `crates.sh`, repo search |
| Niche / vertical (defence, gov, hardware) | repo search + `awesome_extract.sh` + WebSearch + `hn.sh` — no package registry will help |

Always run repo search; add 1–2 more sources max. Then:
`merge.sh <(search.sh … | gs_to_normalized) github_code.out.json awesome.out.json`
```

---

## Phase 2 — real adoption signals

### B3 — `sources/npm.sh`

**Why.** npm's own `popularity/quality/maintenance` scores + download counts are a
truer adoption signal than GitHub stars. Verified: search returns `score.detail`,
and `…/downloads/point/last-month/PKG` returns real monthly downloads.

```bash
#!/usr/bin/env bash
# Usage: npm.sh [--size N] "query" ["query2" …]
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
SIZE=15; QUERIES=()
while [[ $# -gt 0 ]]; do case "$1" in
  --size) SIZE="$2"; shift 2;; *) QUERIES+=("$1"); shift;; esac; done

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for q in "${QUERIES[@]}"; do
  eq=$(jq -rn --arg s "$q" '$s|@uri')
  gs_get "https://registry.npmjs.org/-/v1/search?text=$eq&size=$SIZE" >> "$tmp"
done
jq -s '
  [ .[].objects[] ] 
  | map({
      pkg: .package.name,
      repoUrl: (.package.links.repository // ""),
      description: .package.description,
      pop: .score.detail.popularity, maint: .score.detail.maintenance
    })
' "$tmp" | jq -c '.[]' | while read -r row; do
  pkg=$(jq -r '.pkg' <<<"$row")
  dl=$(gs_get "https://api.npmjs.org/downloads/point/last-month/$pkg" | jq '.downloads // null')
  slug=$(gs_repo_slug "$(jq -r '.repoUrl' <<<"$row")")
  jq -n --argjson r "$row" --arg slug "$slug" --argjson dl "${dl:-null}" '{
    repo: (if $slug == "" then null else $slug end),
    url: (if $slug == "" then ("https://www.npmjs.com/package/" + $r.pkg) else ("https://github.com/" + $slug) end),
    source: "npm", description: $r.description, language: "JavaScript",
    stars: null, downloads30d: $dl, scorecard: null, pushedAt: null,
    package: { registry: "npm", name: $r.pkg },
    sourceSignals: { npmPopularity: $r.pop, npmMaintenance: $r.maint }
  }'
done | jq -s '.'
```

### B4 — `sources/crates.sh`

Same shape for Rust. **Must send `User-Agent`** (403 otherwise — verified).

```bash
#!/usr/bin/env bash
# Usage: crates.sh [--size N] "query" …
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
SIZE=15; QUERIES=()
while [[ $# -gt 0 ]]; do case "$1" in
  --size) SIZE="$2"; shift 2;; *) QUERIES+=("$1"); shift;; esac; done
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for q in "${QUERIES[@]}"; do
  eq=$(jq -rn --arg s "$q" '$s|@uri')
  gs_get "https://crates.io/api/v1/crates?q=$eq&per_page=$SIZE" >> "$tmp"
  sleep 1   # crates.io asks for ~1 req/s
done
jq -s '
  [ .[].crates[] ]
  | map(.repository as $r | {
      repo: ($r // "" | sub("^git\\+";"") | sub("\\.git$";"") | capture("github\\.com[:/]+(?<s>[^/]+/[^/#?]+)").s // null),
      url: ($r // ("https://crates.io/crates/" + .name)),
      source: "crates", description: .description, language: "Rust",
      stars: null, downloads30d: .recent_downloads, scorecard: null, pushedAt: null,
      package: { registry: "cargo", name: .name },
      sourceSignals: { totalDownloads: .downloads }
    })
' "$tmp"
```

### B5 — `enrich.sh`

**Why.** Adapter records arrive star-less and health-less. This fills them: resolves
`repo` for records that have one, pulls fresh GitHub stats, and adds the deps.dev
**scorecard** (opportunistic — often null, handled). This is also what makes
`github_code` and `awesome` records rankable.

```bash
#!/usr/bin/env bash
# Usage: enrich.sh normalized.json   (reads array, writes enriched array)
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
jq -c '.[]' "$1" | while read -r row; do
  slug=$(jq -r '.repo // ""' <<<"$row")
  if [[ -n "$slug" ]]; then
    gh=$(gh api "repos/$slug" --jq '{stars: .stargazers_count, pushedAt: .pushed_at, language: .language, license: (.license.spdx_id // "none"), description: .description}' 2>/dev/null || echo '{}')
    sc=$(gs_get "https://api.deps.dev/v3/projects/github.com%2F$(printf '%s' "$slug" | sed 's#/#%2F#')" \
          | jq '.scorecard.overallScore // null' 2>/dev/null || echo null)
  else
    gh='{}'; sc=null
  fi
  jq -n --argjson row "$row" --argjson gh "$gh" --argjson sc "${sc:-null}" '
    $row
    + { stars:       ($row.stars       // $gh.stars),
        pushedAt:    ($row.pushedAt    // $gh.pushedAt),
        language:    ($row.language    // $gh.language),
        description: ($row.description // $gh.description),
        scorecard:   ($row.scorecard   // $sc) }'
done | jq -s '.'
```

**Note.** Enrichment is the rate-limit-heavy step (one `gh api` + one deps.dev call
per repo). Cap input to the top ~25 candidates before enriching; the cache in
`common.sh` absorbs repeats within a session.

### B7b — `merge.sh` adoption-aware scoring

Replace the Phase-1 `score` line. Popularity becomes the **max** of stars-derived
and downloads-derived magnitude, so a heavily-downloaded package with few stars
still ranks; scorecard is a mild health multiplier.

```jq
  | map(. + {
      popularity: ([ ((.stars + 1) | log), (((.downloads30d // 0) + 1 | log) * 0.5) ] | max)
    })
  | map(. + {
      score: (
        .popularity * .recency * .source_hits
        * (if .scorecard then (1 + (.scorecard/10) * 0.2) else 1 end)
        * 100 | round / 100
      )
    })
```

**Tuning happens here** (this is why adoption is its own phase): after wiring npm +
crates + enrich, run the T-B2 test below and sanity-check that download-heavy
packages rank sensibly against star-heavy repos. The `0.5` downloads weight and
`0.2` scorecard weight are starting points, not gospel.

### S-B2 — SKILL.md digest additions

In § "Deliver the digest", extend the per-repo line and ranking guidance:

```markdown
When a repo carries adoption data, show it — it beats stars:
`**owner/name** — ⭐stars · ↓<downloads30d>/mo · 🛡️<scorecard>/10 · pushed <date> · <license>`

Rank and recommend by adoption + health first (downloads, scorecard, recency), then
stars. A 400-star package pulling 2M downloads/month is a safer dependency than a
9k-star repo with no releases. Note which sources corroborated each pick
(`source_hits`) — multi-source agreement is your strongest signal.
```

---

## Phase 3 — community + conditional + polish

### B6 — `sources/hn.sh`

**Why.** "Show HN" traction + comment volume = community validation and surfaces
tools GitHub search buries. Verified: 1074 hits for "vector database", top story
557 points.

```bash
#!/usr/bin/env bash
# Usage: hn.sh "query" …   → normalized records for GitHub repos linked from HN stories
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for q in "$@"; do
  eq=$(jq -rn --arg s "$q" '$s|@uri')
  gs_get "https://hn.algolia.com/api/v1/search?query=$eq&tags=story&hitsPerPage=20" >> "$tmp"
done
jq -s '
  [ .[].hits[] ]
  | map(select(.url != null and (.url | test("github\\.com/[^/]+/[^/]+"))))
  | map({
      repo: (.url | capture("github\\.com/(?<s>[^/]+/[^/#?]+)").s),
      url: .url, source: "hn", description: .title, language: null,
      stars: null, downloads30d: null, scorecard: null, pushedAt: null, package: null,
      sourceSignals: { hnPoints: .points, hnComments: .num_comments }
    })
' "$tmp"
```

### S-B3 — SKILL.md: WebSearch, Hugging Face, reverse discovery

Three prose additions:

```markdown
### 3c. Non-GitHub sources (use judgment, not scripts)

- **WebSearch** — for "best <capability> library", "<X> vs <Y>", and Reddit/blog
  roundups. Catches mature tools GitHub's keyword index ranks poorly and gives you
  the comparison framing to write the "Take". Always do one WebSearch on a
  build-vs-adopt call.
- **Hugging Face** (ML/AI domains only) — use the `hub_repo_search` MCP tool for
  models, datasets, and Spaces. Skip entirely for non-ML work.

### Reverse discovery (high yield — do this once you have a strong hit)

Once one genuinely-relevant repo is found, expand from *it* rather than guessing
more keywords:
- Read its README "Related / Alternatives" section.
- `gh api repos/OWNER/NAME` → check its topics; search those topics.
- If it's a package, its registry page lists dependencies you may also want.
Feed the names you find back through `enrich.sh` + `merge.sh`. One good repo usually
points at better neighbors than a fourth keyword query does.
```

*(Note: deps.dev `:dependents` was probed and 404s, so reverse discovery uses
READMEs + topics + registry dependencies, not a dependents API.)*

---

## Test plan

**T-B0 — normalizer.** `gs_repo_slug 'git+https://github.com/lancedb/lancedb.git'`
→ `lancedb/lancedb`; a non-GitHub URL → empty.

**T-B1 — code search adapter.** `github_code.sh --limit 5 "milvus vector"` emits an
array where every record has `source:"github-code"` and `sourceSignals.codeHits >= 1`.

**T-B2 — adoption ranking (the core Phase-2 proof).**
Run npm + repo search for a JS capability (e.g. "date parsing"), enrich, merge.
Pass: a high-download package (e.g. `date-fns`/`dayjs`) with fewer stars than some
framework repo still ranks near the top via the downloads term; every record has
`source_hits`, and download-carrying records show `downloads30d`.

**T-B3 — cross-source dedupe.** A repo present in both `search.sh` output and
`github_code.sh` output appears **once** after merge with `source_hits: 2` and
`sources: ["github-code","github-repos"]`.

**T-B4 — scorecard opportunism.** `enrich.sh` on a repo with a scorecard (e.g.
`kubernetes/kubernetes` → 7.6) fills `scorecard`; on one without (e.g.
`qdrant/qdrant`) leaves it `null` without erroring.

**T-B5 — crates UA.** `crates.sh "http client"` returns results (proves the UA
header is being sent; without it crates.io 403s).

**T-B6 — politeness.** Re-running the same query within 6h serves from `.cache`
(no second network call) — check with a timing diff or a network log.

---

## Rollback & risk notes

- **Additive & isolated.** All new sources are separate files; `search.sh` (the
  Part-A core) is untouched except that `merge.sh` consumes a normalized mapping of
  its output. Delete `sources/`, `enrich.sh`, `merge.sh`, `lib/common.sh` and the
  skill reverts to Part-A behavior.
- **Rate limits are the main operational risk.** Code search and `gh api` (enrich)
  are the tight ones. Mitigations already in the design: low `--limit`, cap
  enrichment to top ~25, 6h on-disk cache, `sleep 1` for crates.
- **Third-party API drift.** npm/crates/deps.dev/HN are external and can change
  shape. Each adapter is a thin, independently-testable file; the normalization
  contract means a broken adapter degrades gracefully (fewer sources) rather than
  breaking the run. Re-run the probe commands in the "Verified API reference" table
  if an adapter starts returning empty.
- **deps.dev dependents stays dropped** unless a working endpoint is confirmed; the
  plan does not depend on it.
```
