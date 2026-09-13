# ts-quality

Shared TypeScript/web quality gate for the fleet — the canonical Biome config,
the strict tsconfig baseline, a two-mode gate, the supply-chain posture check,
and the agent-facing guide. Consumed by
[provision](https://github.com/alehatsman/provision).

- [docs/TS.md](docs/TS.md) — how to write it. Rules, gate markers, the 2026 trap list, a review checklist.
- [docs/STACK.md](docs/STACK.md) — what to reach for. De-facto picks with versions and deviation triggers.

## What's here

```
biome.json            the canonical lint + format baseline
tsconfig.base.json    type-checking POLICY (no module/target/paths — that is project shape)
package-scripts.json  the canonical npm scripts; package.json cannot be extended, so this is printed
scripts/
  lib.sh              the checks the toolchain does not do, defined once
  gate.sh             fast | full
  findings.sh         JSONL for agents — one of two things here that speak JSON
  config-check.sh     did the consumer weaken the shared config
  supply-chain.sh     is this repo configured against the 2026 npm threat model
  audit.sh            npm advisories, with the offline case handled honestly
  tools.sh            install | check
docs/                 the guide
```

Six components. Anything that is a single invocation is an **npm script** (see
`package-scripts.json`), not a component; components exist only for multi-step
gates with fail-fast ordering, and for getting config into a consumer repo.

| File | What it does |
|---|---|
| `ci.yml` | full pre-push gate — biome, typecheck, config drift, build, test, supply chain, audit, ai-lint, soft caps |
| `fast.yml` | pre-commit gate — lockfile drift, biome over staged, typecheck, ai-lint over staged, soft caps. No network |
| `tools.yml` | `npm ci` + Playwright browsers, then verify |
| `sync-config.yml` | config into the consumer repo, and print what cannot be copied |
| `config-check.yml` | did the consumer quietly weaken the baseline |
| `findings.yml` | every finding as JSONL for agents → `.gate/findings.jsonl` |

## How a consumer reaches it

A component is a provision component, `use`d by file path from a checkout the
consumer's own plan clones and pins:

```yaml
steps:
  - name: full gate
    use: ~/.cache/provision/tools/ts-quality/ci.yml
    props: { dir: web }
```

```
$ provision list ~/.cache/provision/tools/ts-quality/
$ provision apply tasks/ci.yml
```

Nothing fetches at gate time. The checkout is a step in the consumer's plan,
`creates`-gated like any other, so a bump is a one-line version change and
offline works.

Inside a component, `{{ component_dir }}` is this checkout's own directory,
which is how a step reaches `scripts/` and how `tsq/sync-config` reads the
config it copies. A relative `path:` is not resolved against anything and so
lands in the directory provision was invoked from, which is the consumer repo.
Read from here, write over there, with no argument saying where "there" is.

**`dir`** names the package. Every component takes it, defaulting to `"."`, so a
single-package repo passes nothing. `moongit` passes `dir: web`.

The components carry no `name:` or `version:` root key and there is no exports
table: the tag is the version, and provision lists a directory by each file's
`description:`. (`name:` is not merely unnecessary — provision rejects it.)

## Design

The tools are the interface. Biome reads `biome.json`, tsc reads
`tsconfig.json`, vite/vitest/playwright read their own configs, all without
being asked. So **this repo ships config, not command wrappers**. Three rules
follow.

**One invocation is an npm script, not a component.** `tsq/sync-config` prints
the canonical `scripts` block, so the everyday commands work in a terminal, in
CI and in an editor with no provision and no YAML:

```
npm run lint        # biome check --error-on-warnings --max-diagnostics=none .
npm run typecheck   # tsc -b
npm run build       # vite build
npm test            # vitest run
npm run test:e2e    # playwright test
```

**A component exists only for what a script cannot do** — a multi-step gate with
fail-fast ordering, or getting config into a consumer repo. Six of them.

**A check Biome already performs is not written twice.** Complexity is
`noExcessiveCognitiveComplexity` with a threshold, not a second tool. Cyclic
imports are `noImportCycles`, not a graph script. What *is* written here is only
what Biome reports nothing for — verified, not assumed.

## The gate

`gate.sh fast` — pre-commit. Lockfile drift, Biome over staged files, typecheck,
ai-lint over staged files, soft caps. No build, no suite, no network.

`gate.sh full` — pre-push. Biome, typecheck, config drift, the consumer's build
and test scripts, supply-chain posture, npm audit, ai-lint over tracked files,
soft caps. It runs ai-lint over everything tracked, not just a staged diff:
`--no-verify`, amends, rebases and merges all bypass the pre-commit path.

Four things the gate exists to get right, all of which pass silently otherwise:

- **`biome check` exits 0 on warnings.** So does `biome ci`. 90 of Biome's 223
  recommended rules are `warn`/`info` by default, so a bare `biome check` gates
  133 rules while looking like it gates 223. Every invocation here carries
  `--error-on-warnings`.
- **`--max-diagnostics` defaults to 20** and truncates the human report. A gate
  that says "20 problems" when there are 300 is lying by omission.
- **A consumer can weaken an inherited tsconfig setting silently** — `extends`
  merges, and an override of `strict: false` compiles an implicit-`any` function
  with exit 0. `tsq/config-check` resolves the config and compares.
- **`tsc` exits 2, not 1, when a project emits.** Gate on `!= 0`, never `== 1`.
- **`tsc -b` never sees a `.svelte` or `.vue` file.** The gate runs the
  consumer's `typecheck` script when it has one (svelte-check, vue-tsc), and
  falls back to `tsc -b` only when it does not.

## The baseline is a file copy — and package.json is not

`biome.json` and `tsconfig.base.json` are copied in by `tsq/sync-config`, and
both Biome and tsc merge `extends` natively, so the baseline stays the source of
truth instead of being forked on copy. Verified both ways.

`package.json` cannot be: **npm has no include mechanism for a manifest.** So
`package-scripts.json` is the canonical text, sync-config prints it, and the
consumer pastes. Same shape as rust-quality's lint block, same reason.

`extends` also *creates* a drift vector, which is what `tsq/config-check`
watches:

```
tsconfig-weakened    a baseline compilerOption resolved to a weaker value
tsconfig-absent      no tsconfig.json at all
biome-unparseable    consumer biome.json is not strict JSON — Biome runs with DEFAULTS, not an error
biome-not-extended   consumer biome.jsonc does not extend the baseline
biome-rule-off       consumer switched a baseline rule off
```

The consumer file is `biome.jsonc`, not `biome.json`. `biome-rule-off` asks
for the reason to be recorded, and a comment is where it goes; Biome reads
`biome.json` as strict JSON, and on a parse error it does not fail — it runs
with a default configuration, no `extends` and no excludes, and crawls
`dist/`. Restated excludes are spelled `!**/dir`, with no leading `"**"`:
Biome lints its own config, and `!**/dir/**` (`useBiomeIgnoreFolder`) and a
leading `**` (`noBiomeFirstException`) are warnings, fatal under
`--error-on-warnings`.

## Stance

Biome `preset: "recommended"` (223 rules) plus targeted additions, each with a
reason recorded in `biome.json`: phantom dependencies and unresolved imports,
`noConsole`, `noVar`, `noSecrets`, barrel files, cognitive complexity, and five
type-aware rules promoted to error.

**One linter, not two.** typescript-eslint is not an option under TypeScript 7:
`require("typescript")` now exposes only `version` and `versionMajorMinor`,
`createProgram` is gone, and deep imports are blocked by the `exports` map.
oxlint's `tsgolint` does cover 59/61 type-aware rules and does work on TS 7, and
it was considered and left out — it is a second linter, a second config and a Go
binary beside Biome, and Biome's 17 type-aware rules plus a strict tsconfig and
`noExplicitAny` shrink the `any` surface at the source, which is where the
`no-unsafe-*` family aims.

The gap is real and is written down rather than papered over: Biome has **no**
equivalent of `no-unsafe-argument` / `-assignment` / `-call` / `-member-access` /
`-return`. A repo with many untyped dependencies or heavy `as` usage should
revisit this.

## Supply chain

`npm audit` would have caught **none** of the npm compromises of the last year —
chalk/debug, Shai-Hulud and its 2026 descendants were all freshly published
malicious versions of legitimate packages, and an advisory does not exist at the
moment one lands. It is wired in anyway, because known advisories still matter;
it is just not the defence.

The defence is configuration, and `scripts/supply-chain.sh` reports on it.
One consequence to expect: `min-release-age=3` refuses the Biome this repo's
`$schema` pins for the first three days after a Biome release. That is the
setting working. Pin the previous version and let the schema mismatch be.

| Rule | Meaning |
|---|---|
| `npm-too-old` | npm < 11.10.0, so `min-release-age` cannot be enabled at all |
| `no-release-cooldown` | `min-release-age` unset — the highest-value setting available (npm's key, in DAYS; pnpm's is `minimumReleaseAge`, in minutes) |
| `install-scripts-unreviewed` | `strict-allow-scripts` off (npm ≥ 11.16.0; npm 12 blocks scripts by default) |
| `engines-advisory-only` | `engine-strict` false, so `engines` is decoration |
| `no-lockfile` / `lockfile-outdated` / `shrinkwrap-removed` | pinning hygiene |

Deliberately **not** checked: provenance/SLSA attestation. Mini Shai-Hulud
published 84 malicious `@tanstack` versions carrying valid SLSA Build L3
provenance — the attacker ran inside a genuine, correctly attested build job.
Provenance proves origin, not innocence, and a gate that treated it as a safety
signal would teach the wrong lesson.

## Findings for agents

`tsq/findings` writes `.gate/findings.jsonl` — Biome diagnostics, tsc errors,
ai-lint, config drift, supply-chain posture and advisories, in the shared fleet
schema:

```json
{"tool":"biome","rule":"lint/suspicious/noExplicitAny","level":"warning","path":"src/a.ts","line":25,"col":5,"message":"Unexpected any.","fingerprint":"lint/suspicious/noExplicitAny:src/a.ts:25"}
```

`level:error` is gate-failing. A pure producer: it never re-gates and never
aborts on a finding. Dedup across runs via `fingerprint`.

Biome's own `--reporter=json` is used rather than parsing human output, and its
`sarif` reporter is available for code scanning. A tool that exits non-zero
without producing a report gets an explicit `biome-failed` / `tsc-failed`
record — **a run that could not check must never read as a run that found
nothing.**

## Knobs

| Var | Default | Meaning |
|---|---|---|
| `CAP_LOC` | `500` | God-file soft cap, non-generated sources |
| `AUDIT_LEVEL` | `high` | Minimum advisory severity that fails |
| `AUDIT_OMIT_DEV` | `1` | Audit production dependencies only |
| `MIN_RELEASE_AGE` | `3` | Cooldown in DAYS that supply-chain expects |
| `BIOME_ARGS` | *(empty)* | Extra flags for every biome invocation |
| `TSC_ARGS` | *(empty)* | Extra flags for `tsc -b` |

From provision these are props, and `dir` names the package:

```yaml
steps:
  - name: full gate
    use: ~/.cache/provision/tools/ts-quality/ci.yml
    props: { dir: web, cap_loc: "800" }
```

First-time setup in a consumer repo:

```
provision apply tasks/tools.yml         # npm ci + Playwright browsers
provision apply tasks/sync-config.yml   # config in; prints scripts + .npmrc
# paste the scripts/engines block into package.json
# point biome.jsonc and tsconfig.json at the two base files
provision apply tasks/ci.yml
```

## Not here, on purpose

- **`lint` / `format` / `typecheck` / `build` / `test` / `vuln` components** — one
  invocation each. They are npm scripts; v1 shipped them as components and that
  was six files restating a command.
- **typescript-eslint** — cannot run on TypeScript 7. Not a preference.
- **oxlint** — see Stance. Reconsider if the `no-unsafe-*` gap bites.
- **osv-scanner** — the only credible *offline* vulnerability scanner, and a real
  gap that `npm audit` does not fill. Left out to avoid a non-npm binary and a
  seeded database; the honest note is that the offline story is weaker for it.
- **publint / arethetypeswrong** — publishing checks. Near-no-ops for a private
  app; add them the day the fleet publishes a library.
- **jscpd / clone detection** — `jscpd` 5.2.0 is credible (Rust, oxc parser), but
  a typo'd `--format` or a wrong path makes it **exit 0**, and `--fail-on-empty`
  is not in the released version. Deferred until a misconfigured run is loud.
- **A coverage floor** — belongs with the consumer's own test config, not a
  shared gate, until every consumer runs vitest.
