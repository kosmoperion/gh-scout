---
name: gh-scout
description: Deep GitHub reconnaissance before planning or building a feature. Given a description of what you're about to build, finds existing repos that (a) already do it — so you can adopt instead of rebuild — and (b) are complementary building blocks you could depend on. Use before writing an implementation plan, when scoping a new feature/library/tool, when evaluating "should we build or adopt this", or when the user says "scout github", "any libraries for this", "has someone built this", or invokes /gh-scout.
---

# gh-scout

Reconnaissance, not a plain search. GitHub's native search is keyword-matched and
shallow. The value here is the **LLM layer on both ends** of it: you expand one
intent into many search angles, then read the top candidates' READMEs and judge
real relevance. A run costs a minute and can save days of rebuilding something
that already exists as a maintained library.

## When to run this

- **Right before planning or building** anything non-trivial — a new feature,
  service, library, CLI, or integration.
- When the question "should we build this or adopt something?" is live.
- When the user explicitly asks to scout, or types `/gh-scout`.

If the task is a trivial change to existing code, skip it — this is for greenfield
capability, not edits.

## Context hygiene: run it in a subagent

This process pulls dozens of repo records and ~10 READMEs — a lot of noisy tokens
right when you want a clean context to plan in. **Prefer delegating the whole run
to a subagent** (the `Explore` or `general-purpose` agent) and having it return
only the final digest. Give the subagent this SKILL.md's steps and the intent;
let it hand back the ranked report. Run inline only for a quick, narrow lookup.

## The pipeline

### 1. Distill intent
Write one or two sentences: *what capability* is being built, and in *what
ecosystem* (language, framework, domain). This is what you expand from.

### 2. Expand into 6–10 search queries
This is the step that makes results good. Brainstorm diverse angles for the same
capability:
- **Synonyms & alternate framings** — "job queue" / "task queue" / "background worker".
- **Ecosystem/tech terms** — the library category, the protocol, the algorithm name.
- **Known projects** — if you know incumbents, search their names to find forks,
  alternatives, and "X vs Y" neighbors.
- **Curated lists** — an `awesome <topic>` query surfaces hand-picked collections.

**Query rules (learned the hard way):**
- **Keep each query SHORT — 2 to 4 keywords.** GitHub ANDs every term, so a
  full sentence like `"cli tool to search github repositories"` matches almost
  nothing. Use `"github repo search"` instead.
- Lean on **qualifiers** to sharpen: `language:python`, `stars:>200`,
  `topic:rag`, `archived:false`, `in:name,description,readme`.
- Vary vocabulary across queries — overlap is fine (it's a relevance signal),
  but four near-identical queries waste your rate budget.
- The Search API allows ~30 requests/min, so 6–10 queries per run is the ceiling.
- **Guard short acronyms against collisions.** A short acronym often fuzzy-matches
  an unrelated common term (`DRDO`→`DrDoS` DDoS tools; `HAL`→hardware abstraction
  layer; `SAM`→AWS SAM / access management). Always pin the acronym with a
  disambiguating term (`DRDO india`, `HAL aerospace`) **and** pass the colliding
  term to `--exclude`, e.g. `--exclude 'drdos|denial of service'`.
- **Quote true multi-word phrases** (`"cursor on target"`) so GitHub keeps them
  together instead of AND-ing the loose words.

### 2b. The two-pass pattern (use when the target is domain- or vendor-specific)

The most common real outcome is: *the specific thing barely exists as OSS, but the
underlying primitives are mature.* Plan for it with two passes:

- **Pass 1 — the specific target.** Search the domain/vendor terms directly
  ("indian defence", "DRDO india"). This tells you whether a ready-made option
  exists — often it's only student/intern/hackathon code, which is itself a finding.
- **Pass 2 — the country/vendor-neutral primitives.** Strip the specificity and
  search the underlying capability the industry is built on (for defence: TAK /
  cursor-on-target / MIL-STD-2525 symbology / C2 / tracking). This is where the
  real adoptable building blocks live.

Run pass 2 whenever pass 1 returns only low-signal or hobbyist results. Merge and
dedupe both passes before the digest.

### 3. Run the search core
Pass the queries to the script. It runs each against GitHub, dedupes by repo,
scores by `ln(stars+1) × recency × query_hits × archived_penalty × spam_penalty`,
and returns a ranked JSON shortlist. `query_hits` = how many of your queries
surfaced the repo, so cross-referenced repos outrank one-off high-star hits.

```bash
~/.claude/skills/gh-scout/scripts/search.sh \
  --min-stars 100 --top 15 --pushed-after 2024-01-01 \
  "job queue redis" \
  "task queue python" \
  "background worker async" \
  "distributed task scheduler" \
  "awesome task queue" \
  "celery alternative"
```

Flags: `--limit N` (per-query fetch, default 30), `--min-stars N` (default 0),
`--top N` (final shortlist size, default 15), `--pushed-after YYYY-MM-DD`
(recency floor applied to every query). Output is JSON on stdout; a per-query
run log goes to stderr.

Tuning: if a run returns very few hits, your queries were too specific — shorten
them and drop `--min-stars`. If it returns noise, raise `--min-stars` or add
`language:` / `topic:` qualifiers.

**Reading the summary line.** The script prints a summary to stderr:
`max query_hits` and a count of repos `flagged for review`. On **niche domains
expect `max query_hits = 1`** — queries don't overlap, so the cross-referencing
boost never fires. That is normal, not a failure: fall back to README judgment
(step 4) rather than trusting the ranking. On mainstream domains, `max query_hits`
of 3–5 means the top repos are genuinely corroborated across angles.

### 3b. Widen with additional sources

`search.sh` is the primary source (GitHub repo search). Add more sources based on
the domain, then merge everything through `merge.sh` — it dedupes across sources
and rewards cross-source corroboration: a repo found by repo-search **and**
code-search **and** an awesome list outranks one found by only one angle, even if
its star count is lower.

**Source-routing table — pick by domain, don't run everything every time:**

| Domain signal | Add these sources |
|---|---|
| Niche / vertical (defence, gov, hardware) | `awesome_extract.sh` (find the list first via `search.sh "awesome <topic>"`) + `github_code.sh` |
| Library/API someone might *use in code* without naming it in a README | `github_code.sh` |
| JS/TS/web/frontend capability | `npm.sh` (real download counts — see step 3c) |
| Rust capability | `crates.sh` |
| A build-vs-adopt call where community traction matters | `hn.sh` (points/comments = real usage chatter, not just keyword matches) |
| Everything else (start here, add more only if the shortlist is thin) | `search.sh` alone is often enough |

Always run repo search first. Add at most 1–2 more sources — more than that just
burns rate limit for diminishing signal. `npm.sh`/`crates.sh` results need
`enrich.sh` before they carry stars/pushedAt (see step 3c).

**Code search noise warning.** Unlike repo search, `github_code.sh` queries match
against file *contents*, so generic 2–3 word phrases (`"vessel tracking AIS"`)
return code that happens to contain those words with zero domain relevance —
verified live: a maritime-AIS query returned an unrelated SAAS boilerplate repo
and a repo literally named `id`. Use **distinguishing, technical tokens** for code
search specifically — a function/type name, a protocol constant, an exact API
call (`"AIVDM sentence parse"` beats `"vessel tracking AIS"`) — and treat every
code-search hit as unverified until step 4's README/file check, more so than hits
from any other source.

```bash
source ~/.claude/skills/gh-scout/scripts/lib/common.sh   # for gs_to_normalized
S=~/.claude/skills/gh-scout/scripts

# Pre-ranked sources already carry a ranking signal (stars, or downloads):
$S/search.sh --min-stars 100 --top 15 \
  "job queue redis" "task queue python" | gs_to_normalized > /tmp/gs_repos.json

# Lead sources return only a repo slug + provenance. Enrich them BEFORE merging
# (see 3c for why) so they get real stars to be scored on:
$S/sources/github_code.sh --limit 15 "redis job queue" > /tmp/gs_code.json
$S/enrich.sh /tmp/gs_code.json > /tmp/gs_code_enriched.json

# Merge into one ranked shortlist:
$S/merge.sh /tmp/gs_repos.json /tmp/gs_code_enriched.json
```

### 3c. Enrich star-less sources *before* merge — ordering matters

`github_code.sh`, `awesome_extract.sh`, and `hn.sh` return only a repo slug and
provenance — no stars, no `pushedAt`, no downloads. (`npm.sh` / `crates.sh` are
star-less too but carry `downloads30d`, so they can rank without enrichment.)

**`merge.sh` is the scorer, so enrichment has to happen first.** If you merge a
star-less record and enrich afterward, its score was already computed as if it had
zero stars, and it's stuck at the bottom of the ranking no matter how popular the
repo actually is. So: run `enrich.sh` on each lead source's output, *then* merge.

```bash
$S/sources/hn.sh "redis job queue" > /tmp/gs_hn.json
$S/enrich.sh /tmp/gs_hn.json > /tmp/gs_hn_enriched.json   # fills stars/pushedAt/scorecard
$S/merge.sh /tmp/gs_repos.json /tmp/gs_code_enriched.json /tmp/gs_hn_enriched.json
```

`enrich.sh` makes one `gh api` call + one deps.dev call per repo, so it's the
rate-limit-heavy step. Keep each lead source's `--limit`/`--size` modest (≤20) so
you're enriching a shortlist, not an unfiltered dump; the 6-hour cache in
`common.sh` absorbs repeats within a session.

### 3d. Non-GitHub sources (use judgment, not scripts)

- **WebSearch** — for "best `<capability>` library", "`<X>` vs `<Y>`", and
  Reddit/blog roundups. Catches mature tools GitHub's keyword index ranks poorly,
  and gives you the comparison framing to write the digest's "Take". Do at least
  one WebSearch whenever a build-vs-adopt call is actually live — scripts alone
  won't catch "everyone in this space quietly moved to X".
- **Hugging Face** (ML/AI domains only) — use the `hub_repo_search` MCP tool for
  models, datasets, and Spaces. Skip entirely for non-ML work; it adds noise.

**Reverse discovery** — once you have one genuinely-relevant repo, expand from
*it* rather than guessing more keywords. This is higher-yield than a fourth query:
- Read its README's "Related projects" / "Alternatives" section.
- `gh api repos/OWNER/NAME --jq .topics` — search those topics.
- If it's a package (from `npm.sh`/`crates.sh`), its registry page lists
  dependencies that may also be relevant building blocks.

Feed anything you find this way back through `enrich.sh` + `merge.sh` rather than
listing it separately. (Note: deps.dev's `:dependents` endpoint was evaluated and
returns 404 on every path tried — it's not available, which is why this list
leans on READMEs/topics/registry pages instead of a dependents API.)

### 4. Enrich the top candidates
For the ~8–10 highest-scored repos, fetch the README to judge actual relevance
(the description alone lies often):

```bash
gh repo view OWNER/NAME            # description, topics, README, activity
# or just the readme:
gh api repos/OWNER/NAME/readme --jq '.content' | base64 -d | head -c 4000
```

Drop false positives here — repos that keyword-matched but don't do the thing.

**Always open the README for any repo carrying a `reviewFlags` entry.** The script
flags `fast-star-growth` (young repo, implausibly high star velocity),
`unusual-fork-ratio` (more forks than stars — usually a template/course, not a
library), `stale`, and `archived`. These are cheap numeric hints; you make the
call. In particular, a `fast-star-growth` repo with a long, buzzword-stuffed,
emoji-heavy description and thin actual code is promotional noise — cut it, even if
its score is high.

### 5. Categorize every survivor
Sort the real hits into two buckets — this is what makes the output actionable:

- **Similar / alternative** — it substantially overlaps with what you're about to
  build. Raises the "adopt instead of rebuild?" question.
- **Complementary / building block** — a library or tool you'd *depend on* rather
  than replace.

### 6. Deliver the digest
Keep it short and decision-oriented. For each repo:
`**owner/name** — ⭐stars · pushed <date> · <license> · <language>` then a one-line
*why it's relevant* and, for the top few, the *build-vs-adopt* read.

```
## gh-scout: <intent>

### 🟢 Similar / alternatives (adopt-vs-build)
- **owner/name** — ⭐12.4k · pushed 2026-07 · MIT · Go
  Does exactly the core of what you're planning; battle-tested. Strong adopt candidate.

### 🔧 Complementary building blocks
- **owner/name** — ⭐3.1k · pushed 2026-08 · Apache-2.0 · Python
  Handles the <X> piece — depend on this rather than writing it.

### Take
<2–3 sentences: is there a clear adopt option, or is building justified, and why.>
```

Always end with a clear recommendation. Note licenses when adoption is realistic —
a GPL dependency in a proprietary codebase is a real constraint. Flag archived or
stale-but-high-star repos so they aren't mistaken for live options.

Treat stars as *hype and age*, not current adoption — an 8k-star repo last pushed
in 2019 is a worse dependency than an 800-star repo shipping monthly. Weight
`pushedAt`, open-issue responsiveness, and `reviewFlags` over raw star count.

When records came through `npm.sh` / `crates.sh` / `merge.sh`, real adoption data
is available — use it. `merge.sh` scores `popularity` as
`max(ln(stars+1), ln(downloads30d+1)×0.5)`, so a heavily-downloaded package with
modest stars ranks on its actual usage, not just its GitHub hype. Show it in the
digest when present:
`**owner/name** — ⭐stars · ↓<downloads30d>/mo · 🛡️<scorecard>/10 · pushed <date> · <license>`
(omit any field that's `null` rather than printing it as zero — `null` downloads
means "no package registry data," not "zero downloads"). Note which sources
corroborated each pick (`source_hits`/`sources`) — multi-source agreement is a
strong signal on its own. And don't let high `popularity` mask staleness: a
package can be simultaneously massively downloaded *and* effectively dormant
(no commits in years) — `recency` in the score already discounts for this, but
call it out explicitly in the digest ("still widely used but unmaintained since
&lt;year&gt;") since that's exactly the kind of thing a build-vs-adopt call needs to know.

**When the honest answer is "this barely exists as OSS," say so as a first-class
verdict** — don't pad the digest with weak hobbyist repos to look productive.
Declare it when: pass 1 returned only student/intern/hackathon repos (low stars,
one-off, abandoned), pass 2's primitives don't cover the specific need, and the
domain is one where serious work is typically proprietary/classified (defence,
fintech core, proprietary hardware).

```
## gh-scout: <intent> — thin ecosystem

**Bottom line:** no production-grade OSS for this specific need. What exists on
GitHub is <student/intern/hackathon> code, not adoptable. The real work here is
<proprietary/classified> (<who: e.g. DRDO, HAL, DPSUs>).

### Closest adoptable primitives (if you're *building* for this space)
- **owner/name** — ⭐… · <license> — <the underlying capability it gives you>

### Take
Don't expect to adopt a finished product. If building, start from <primitive>.
Watch licenses: <note>.
```

## Requirements
- `gh` CLI, authenticated (`gh auth status`). Code search needs auth.
- `jq` for the scoring pipeline.
