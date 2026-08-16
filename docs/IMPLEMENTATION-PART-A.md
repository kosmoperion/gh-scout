# gh-scout — Part A Implementation Guide

Technical spec for the "make SKILL.md better" changes. Every item here traces to
concrete evidence from the first real run (Indian-defence-industry scout) or the
vector-DB smoke test. This guide is implementation-ready: exact code blocks, exact
insertion anchors, and a regression test plan using the cases that exposed each gap.

Two files change:
- `scripts/search.sh` — the deterministic scorer (adds cheap numeric signals + a filter).
- `SKILL.md` — the model-facing guidance (adds query-craft rules, workflow patterns, verdicts).

**Design principle held throughout:** the *script* only computes cheap, objective
signals (ratios, velocities, a keyword filter). All *prose judgment* (is this
description buzzword spam? is this repo actually relevant?) stays in the model's
README/enrich pass. We do not try to do NLP in jq.

---

## Change inventory

| ID | Item | File | Type |
|----|------|------|------|
| C1 | Collision guard: `--exclude` post-filter | search.sh | new flag + jq |
| C2 | Quality signals: `forkRatio`, `starVelocity`, `reviewFlags` + soft penalty | search.sh | fields + jq |
| C3 | Overlap/summary line to stderr | search.sh | bash |
| S1 | Acronym/homograph query rule | SKILL.md | prose |
| S2 | Low-overlap interpretation note | SKILL.md | prose |
| S3 | Two-pass pattern (narrow → primitives) | SKILL.md | new section |
| S4 | Spam-check step keyed on `reviewFlags` | SKILL.md | prose |
| S5 | "Thin / proprietary ecosystem" first-class verdict | SKILL.md | prose + template |
| S6 | Adoption ≠ stars interpretation | SKILL.md | prose |

**Sequencing:** do the script changes (C1→C2→C3) first, because several SKILL.md
edits (S2, S4) document fields the script must already emit. Then the SKILL.md
edits in any order. C2 depends on adding `createdAt` to the fetched fields.

---

## C1 — Collision guard (`--exclude`)

**Evidence.** The `DRDO` query returned mostly `DrDoS` DDoS-tool repos
(`Memcached-drdos`, `drdos-framework`, `hadoop-drdobbs`). GitHub search is
case-insensitive and fuzzy on short tokens, so acronyms collide with common tech
terms. We need a post-filter to drop matches by keyword.

**Change 1 — add the flag.** In the arg-parse `while` loop, add a case:

```bash
    --exclude)       EXCLUDE="$2"; shift 2 ;;
```

And add its default with the other defaults near the top:

```bash
EXCLUDE=""        # case-insensitive regex; drop repos whose name/description match
```

**Change 2 — apply it in jq.** The final `jq -s` call must take the value as an
arg and filter early (right after the `stargazersCount` filter, before `group_by`):

- Change the invocation from `jq -s '` to:
  ```bash
  jq -s --arg ex "$EXCLUDE" '
  ```
- Insert this stage immediately after the `map(select(.stargazersCount >= ...))` line:
  ```jq
    | ( if $ex == "" then .
        else map(select(((.fullName // "") + " " + (.description // "")) | test($ex; "i") | not))
        end )
  ```

**Usage** (documented in S1): `--exclude 'drdos|denial of service|dr\.? dobbs'`

---

## C2 — Quality signals + soft penalty

**Evidence.** The vector-DB smoke test surfaced a 6.1k-star repo
(`rocketride-org/rocketride-server`) with a buzzword-stuffed description that
outranked genuine libraries. Stars alone are gameable. We add two objective
numeric signals and a `reviewFlags` array the model must check, plus a mild score
penalty — we *demote and flag*, we never silently drop.

**Change 1 — fetch `createdAt`** (needed for star velocity). Update the FIELDS line:

```bash
FIELDS="fullName,description,stargazersCount,pushedAt,createdAt,url,language,license,isArchived,forksCount,openIssuesCount"
```

**Change 2 — extend the jq pipeline.** Replace the current object-building +
scoring tail (from `group_by(.fullName)` through `sort_by(-.score) | .[0:TOP]`)
with this expanded version:

```jq
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
  | .[0:'"$TOP"']
```

**Signal rationale (be honest about limits):**
- `starVelocity` = stars per day since *creation*. A young repo with thousands of
  stars (`>25/day` and `>300` stars) is worth a human glance — sometimes genuinely
  viral, sometimes inflated. It's a **flag for review, not a verdict**.
- `forkRatio` = forks / stars. `>1.0` (more forks than stars) usually means a
  course/template/mirror, not a library you adopt.
- These are deliberately crude. Buzzword/quality judgment of the *prose* is the
  model's job in the enrich pass (S4), not the script's.

---

## C3 — Overlap & summary reporting to stderr

**Evidence.** In the defence run nearly every repo scored `hits: 1` — the
cross-referencing signal never engaged because niche queries don't overlap. The
model couldn't see this at a glance. Surface it.

**Change.** The script currently ends by letting the final `jq` write straight to
stdout. Capture it once, print it, then emit a summary to stderr. Replace the
final `jq -s ... "$tmp"/r*.json` invocation's *usage* like so — wrap it:

```bash
result="$(jq -s --arg ex "$EXCLUDE" '
  ...the full pipeline from C1/C2...
' "$tmp"/r*.json)"

printf '%s\n' "$result"

printf '%s' "$result" | jq -r '
  "  summary: \(length) repos · max query_hits \([.[].hits] | max // 0) (1 = no cross-referencing, judge by README) · \([.[] | select(.reviewFlags | length > 0)] | length) flagged for review"
' >&2
```

---

## S1 — Acronym/homograph query rule

**Location.** SKILL.md § "Expand into 6–10 search queries" → the **Query rules**
bullet list. Append these two bullets:

```markdown
- **Guard short acronyms against collisions.** A short acronym often fuzzy-matches
  an unrelated common term (`DRDO`→`DrDoS` DDoS tools; `HAL`→hardware abstraction
  layer; `SAM`→AWS SAM / access management). Always pin the acronym with a
  disambiguating term (`DRDO india`, `HAL aerospace`) **and** pass the colliding
  term to `--exclude`, e.g. `--exclude 'drdos|denial of service'`.
- **Quote true multi-word phrases** (`"cursor on target"`) so GitHub keeps them
  together instead of AND-ing the loose words.
```

---

## S2 — Low-overlap interpretation

**Location.** SKILL.md § "Run the search core", after the paragraph describing
`query_hits`. Insert:

```markdown
**Reading the summary line.** The script prints a summary to stderr:
`max query_hits` and a count of repos `flagged for review`. On **niche domains
expect `max query_hits = 1`** — queries don't overlap, so the cross-referencing
boost never fires. That is normal, not a failure: fall back to README judgment
(step 4) rather than trusting the ranking. On mainstream domains, `max query_hits`
of 3–5 means the top repos are genuinely corroborated across angles.
```

---

## S3 — Two-pass pattern (narrow → primitives)

**Location.** SKILL.md — new subsection between § "Expand into 6–10 search queries"
and § "Run the search core". Insert:

```markdown
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
```

---

## S4 — Spam-check step in enrich

**Location.** SKILL.md § "Enrich the top candidates", replace the final paragraph
("Drop false positives here…") with:

```markdown
Drop false positives here — repos that keyword-matched but don't do the thing.

**Always open the README for any repo carrying a `reviewFlags` entry.** The script
flags `fast-star-growth` (young repo, implausibly high star velocity),
`unusual-fork-ratio` (more forks than stars — usually a template/course, not a
library), `stale`, and `archived`. These are cheap numeric hints; you make the
call. In particular, a `fast-star-growth` repo with a long, buzzword-stuffed,
emoji-heavy description and thin actual code is promotional noise — cut it, even if
its score is high.
```

---

## S5 — "Thin / proprietary ecosystem" verdict

**Location.** SKILL.md § "Deliver the digest". Add a template variant and criteria
after the existing digest template block:

```markdown
**When the honest answer is "this barely exists as OSS," say so as a first-class
verdict** — don't pad the digest with weak hobbyist repos to look productive.
Declare it when: pass 1 returned only student/intern/hackathon repos (low stars,
one-off, abandoned), pass 2's primitives don't cover the specific need, and the
domain is one where serious work is typically proprietary/classified (defence,
fintech core, proprietary hardware).

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

---

## S6 — Adoption ≠ stars

**Location.** SKILL.md § "Deliver the digest", in the closing guidance paragraph.
Append:

```markdown
Treat stars as *hype and age*, not current adoption — an 8k-star repo last pushed
in 2019 is a worse dependency than an 800-star repo shipping monthly. Weight
`pushedAt`, open-issue responsiveness, and `reviewFlags` over raw star count. (True
adoption signals — download counts, dependents — come from package-registry sources
in Part B; until then, lead with recency and maintenance, not stars.)
```

---

## Test plan

Run these after implementing. Each maps to the evidence that motivated a change.

**T1 — collision guard (C1/S1).** Regression on the case that started this:
```bash
scripts/search.sh --min-stars 2 --top 15 --exclude 'drdos|denial of service|dr\.? dobbs' \
  "DRDO india" "indian defence" "defence research india"
```
Pass: no `*drdos*` / `hadoop-drdobbs` / DDoS-tool repos in output.

**T2 — quality signals (C2).** Confirm fields + penalty exist:
```bash
scripts/search.sh --min-stars 50 --top 8 "vector database" "embeddings search" \
  | jq '.[] | {fullName, stars, starVelocity, forkRatio, reviewFlags, score}'
```
Pass: every object has `starVelocity`, `forkRatio`, `reviewFlags`; any repo with
`fast-star-growth` or `unusual-fork-ratio` is demoted below a comparable clean repo.

**T3 — overlap summary (C3).** Pass: stderr shows a `summary:` line with
`max query_hits` and a flagged count. On the niche defence queries it reads
`max query_hits 1`.

**T4 — empty `--exclude` is a no-op.** `--exclude ''` (or omitting it) must return
the same set as before the change. Guards against the jq `test` stage nuking
everything on empty input.

**T5 — no `createdAt` regression.** A repo with `null` createdAt must not crash the
pipeline (the `// "1970-..."` guard handles it); `starVelocity` for it will be tiny,
which is acceptable.

---

## Rollback

All changes are additive and self-contained. To revert: restore the previous
FIELDS line, the previous `jq -s '...'` block, and drop the `--exclude` case and
`EXCLUDE` default. SKILL.md edits are pure prose additions and can be reverted
independently of the script.
