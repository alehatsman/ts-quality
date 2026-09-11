# ts-quality — SPEC

v2, 2026-09-11. Decisions and evidence. The README describes what exists; this
records why, and what was measured to justify it.

v1 was a mooncake module. Every component in it fails `provision validate`, so
this is not a port of a working thing.

## Goal

One canonical source for TypeScript/web lint policy, the quality gate, the
supply-chain posture, and the agent-facing guide, consumed as a provision
component set. The TS sibling of `rust-quality`.

## The governing decision

**Ship config, not command wrappers.**

Biome, tsc, vite, vitest and playwright each read their own config file
natively. Anything built on top that merely restates one invocation is a file to
maintain with nothing inside it. Consequences, in order of leverage:

1. Anything that is one invocation is an **npm script** in the consumer's
   `package.json`. Works with no provision at all.
2. A component exists only for multi-step fail-fast ordering, or for copying
   config into a consumer.
3. JSON lives at **one** edge (`findings.sh`); `gate.sh` renders the same checks
   for humans from the same functions in `lib.sh` — define once, render twice.
4. Checks Biome already performs are not written a second time.
5. The gate runs no step whose work another step already did.

v1 violated (1) six times: `lint`, `format`, `typecheck`, `build`, `test` and
`vuln` were components wrapping a single `npx` call each. They are npm scripts
now, printed by `sync-config`.

## What v1 got wrong

Not stylistic. v1 does not run under provision, and its gate never enforced what
it claimed.

| Defect | Evidence |
|---|---|
| `name:` and `version:` root keys on all 10 components | `provision validate lint.yml` → `error: unknown key 'name' in a component; allowed: props, steps, description` |
| `sync-config.yml` uses `file.copy:` | `error: unknown key 'file.copy' in a step`. provision's action is `file: {path, state, src}` |
| `index.yml` declares a mooncake `exports:` map | provision has no module registry and no exports table |
| README wires consumers via `modules:`/`source: 127.0.0.1:8080/...` | a mooncake registry; provision consumers `use:` a path from a pinned checkout |
| **`ci.yml` runs bare `npx biome check .`** | **exits 0 on 30 `noExplicitAny` warnings**; `biome ci` does too; only `--error-on-warnings` exits 1 |
| `biome.json` is stale | `biome migrate`: `$schema` 2.4.16 → 2.5.13, `"recommended": true` → `"preset": "recommended"` (deprecated, removed next major) |
| `biome.json` `files.includes` is `["src/**","*.ts","*.json"]` | misses `.tsx`, tests, and every nested config |

The gate hole is the load-bearing one. Inventory built by running
`biome explain` over all 538 rules in the 2.5.13 schema:

| | rules |
|---|---|
| total (excl. `preset`/`recommended` pseudo-keys) | 538 |
| recommended | 223 |
| recommended @ `error` — these failed v1's gate | 133 |
| recommended @ `warn`/`info` — **these did not** | **90** |

v1 enforced formatting and 133 rules while appearing to enforce 223.

## Config that can be copied, and config that cannot

This is what decides which components exist.

- **`biome.json` can be copied.** Native `extends`. Verified: a consumer
  extending the baseline and raising `noExplicitAny` to `error` produced 30
  error-severity diagnostics where the baseline gave 30 warnings.
- **`tsconfig.base.json` can be copied.** Native `extends`.
- **`package.json` cannot.** npm has no include mechanism for a manifest. Same
  shape as rust-quality's `[workspace.lints]` problem, same answer: ship the
  canonical text (`package-scripts.json`), print it, enforce rather than mutate.

`extends` also *creates* a drift vector. Verified: a consumer extending a base
with `strict: true` and setting `strict: false` locally compiles an
implicit-`any` function with **exit 0 and no diagnostic**. `tsc --showConfig`
resolves `extends` and reports it, which is the enforcement mechanism — the same
move go-quality makes by asking golangci-lint rather than grepping YAML.

## One linter, not two

typescript-eslint is not a choice under TypeScript 7. Verified on 7.0.2:
`require("typescript")` returns `{version, versionMajorMinor}`,
`typeof ts.createProgram === "undefined"`, and
`require("typescript/lib/typescript.js")` throws `ERR_PACKAGE_PATH_NOT_EXPORTED`.
Every type-aware rule it has is built on that API.

oxlint's `tsgolint` *does* work — it is built on typescript-go, requires TS 7+,
and covers 59/61 type-aware rules. It was considered and left out: a second
linter, a second config and a Go binary beside Biome, with no formatter, and
oxc's own docs warn it degrades on monorepos with many project references.

The cost is written down rather than hidden. Biome ships 17 type-aware rules;
13 are nursery, none are recommended, all default to `info`. Absent entirely:
the whole `no-unsafe-*` family. The mitigation is upstream — `strict` +
`noUncheckedIndexedAccess` + `exactOptionalPropertyTypes` + `noExplicitAny` at
error keeps `any` from entering — and it works only if dependencies are typed.

## Checks the toolchain does not do

Written here only because nothing upstream covers them.

- **ai-lint.** Agent-tagged TODOs, prompt artifacts, diff relics. Verified:
  Biome reports **0 diagnostics** on a file containing all three.
- **god files.** A LOC soft cap. Biome caps cognitive complexity per function
  (`noExcessiveCognitiveComplexity`, enabled in the baseline) but has no
  file-size opinion.
- **resolved-config drift.** Above.
- **supply-chain posture.** `npm audit` matches an advisory database, and none of
  the 2025–26 npm compromises had an advisory during their exposure window. What
  stops that class is `min-release-age`, `strict-allow-scripts` and
  `engine-strict` — configuration, which is what `supply-chain.sh` reports on.

Deliberately **not** checked: provenance/SLSA attestation. 84 malicious
`@tanstack` versions shipped with valid SLSA Build L3 provenance from a genuine,
correctly attested build job. Provenance proves origin, not innocence.

## Interfaces

Env: `CAP_LOC` (500), `AUDIT_LEVEL` (high), `AUDIT_OMIT_DEV` (1),
`MIN_RELEASE_AGE` (3, days), `BIOME_ARGS`, `TSC_ARGS`.

`lib.sh` records — the internal contract, format-free:

```
rule<TAB>level<TAB>path<TAB>line<TAB>message
```

Finding schema on the wire, shared with go-quality and rust-quality:

```json
{"tool":..,"rule":..,"level":"error|warning|note","path":..,"line":N,"col":N?,
 "message":..,"fingerprint":"rule:path:line"}
```

Components: `ci`, `fast`, `tools`, `sync-config`, `config-check`, `findings`.

## Edge cases

- **`biome check` exits 0 on warnings**, and so does `biome ci`. Every gate
  invocation carries `--error-on-warnings`, or 90 recommended rules are
  decoration.
- **`--max-diagnostics` defaults to 20** and truncates the *human* reporter (30
  violations printed 20). The `json`/`sarif` reporters emit all 30, so the
  findings path is unaffected; only `gate.sh` needs the flag.
- **`vcs.useIgnoreFile: true` hard-errors when no ignore file exists**, and the
  JSON reporter still emits an empty document — so a gate reading only
  diagnostics sees "clean". The baseline therefore sets it `false` and lists its
  exclusions explicitly in `files.includes`. v1 shipped `true`.
- **`tsc` exit codes are not uniform**: `noEmit` → 1, **emitting → 2**,
  `noEmitOnError` → 1, `tsc -b` composite → 2, removed option → 2. Gate on
  `!= 0`, never `== 1`.
- **`git diff --cached --name-only` prints repo-root-relative paths** while
  `git ls-files` prints cwd-relative ones. In a repo gated with `dir: web` that
  made every staged path fail `[ -f ]` and ai-lint report "clean" having read
  nothing. `--relative` is what makes the two agree.
- **A warm `tsc -b` still re-reports its errors** — three consecutive runs, all
  exit 1 with the diagnostic. rust-quality's "warm `cargo clippy` prints
  nothing" trap does not apply, so `findings.sh` busts no cache.
- **`npm audit` reports an unreachable registry as `{"error":...}` with no
  `metadata`**, not as a missing `vulnerabilities` key — which is present and
  empty on a genuinely clean tree. Keying on the wrong one made audit.sh report
  "no advisories" against a dead registry.
- **`npm ci` detects genuine manifest/lockfile drift offline** and exits
  non-zero; a range the lockfile still satisfies is correctly not drift.
- **Biome type-aware rules need explicit per-rule opt-in.** Setting
  `domains.types` alone does not enable them, and neither does any `preset` —
  nursery is excluded from `preset: "all"`. Conversely the `types` domain is not
  required: an explicitly listed rule fires without it.
- `grep` exits 1 on no match, the normal case for every ai-lint rule. Under
  `set -euo pipefail` inside a process substitution, every check pipeline must
  end in `|| true`. Verified with a two-file fixture where each file matches a
  different rule: guarded reports 2 findings, unguarded reports **1**.
- `fast` only sees a staged diff, so `full` re-runs ai-lint over tracked files;
  otherwise `--no-verify`, amend, rebase and merge bypass the only error-level
  rules there are.
- **Findings print to stderr, not stdout.** provision's default failure view
  shows a step's stderr only, so a report on stdout produced "gate failed on the
  findings above" with no findings above it.

## Validation — actually run, 2026-09-11

Toolchain: node v22.23.1, npm 10.9.8, provision 0.9.1, typescript 7.0.2,
@biomejs/biome 2.5.13, vite 8.3.0, vitest 5.0.0, knip 6.35.1. Versions resolved
against registry.npmjs.org, not from memory.

- `bash -n` + `shellcheck -x` clean on all 7 scripts. shellcheck caught a real
  bug, not style: `m['code']` inside a single-quoted shell string terminated the
  string and broke the embedded python.
- **v1 rejected by provision** — `name`/`version` root keys and `file.copy`, on
  real `provision validate` runs.
- **The warning hole reproduced**: a 30-violation fixture exits 0 under
  `biome check` and `biome ci`, 1 under `--error-on-warnings`.
- **Rule inventory measured**: `biome explain` over all 538 schema rules → 223
  recommended, 133 `error` / 60 `warn` / 30 `info`.
- **`biome migrate` on v1's config** reports both required migrations; on the new
  baseline it reports "no migration needed".
- **Biome `extends` verified** end to end including a severity override.
- **Group-level `preset` verified**: `suspicious: {preset: "all"}` surfaced
  `noVar` and `noConsole` where `preset: "recommended"` found nothing. This was
  schema-visible but undocumented.
- **Type-aware rules verified**: `noFloatingPromises` fires at `error` once
  explicitly enabled, with and without the `types` domain.
- **tsconfig weakening verified**: `strict: false` over the base compiles clean;
  `tsc --showConfig` exposes it.
- **TS 7 removed options reproduced**: `target: es5`, `moduleResolution: node`,
  `baseUrl`, `downlevelIteration`, `outFile`, `esModuleInterop: false` all
  `TS5108`/`TS5102`, exit 2.
- **TS 7 has no compiler API** — `createProgram` undefined, deep import
  `ERR_PACKAGE_PATH_NOT_EXPORTED`.
- **`erasableSyntaxOnly` rejects all three** of enum, parameter property and
  namespace (TS1294); node 22.23.1 runs a plain `.ts` file unflagged.
- **config-check verified on five states**: clean, weakened tsconfig, biome not
  extending, rule switched off, and `--format jsonl` (valid JSON, correct line).
- **supply-chain verified on four states**: npm too old, missing `engines`, no
  lockfile (error, exit 1), stale lockfileVersion + shrinkwrap present.
- **audit.sh verified on three states**: clean tree; dead registry (a `note`,
  exit 0, *after* fixing a detection bug that reported it clean); and a fixture
  with `lodash@4.17.11` + `minimist@1.2.0` → 2 critical advisories, exit 1.
- **findings.sh end to end**: 13 findings across 4 tools, every line valid JSON,
  13/13 unique fingerprints. A tool that exits non-zero without a report gets an
  explicit `biome-failed`/`tsc-failed` record — proven by the real
  `useIgnoreFile` failure, not a simulated one.
- **All six components pass `provision validate`.** Five pass `--strict`;
  `tools.yml` does not, and should not — `--strict` demands an idempotency gate
  on every `shell` step and the install step cannot honestly claim one.
- **End to end through provision, from a foreign cwd**: `sync-config` wrote both
  base files into `consumer/web/` and was a no-op on re-apply (3 ok, 0 changed);
  `config-check` passed; the **full 9-step gate ran green**; the same gate
  **exited 1** on committed agent residue; the fast gate **exited 1** on staged
  residue; `findings` produced a valid artifact.

## Known gaps

- **The gate is validated on typescript 7.0.2, but STACK.md recommends pinning
  `~6.0.2`.** create-vite's own templates still pin 6, and TS 7 has no
  programmatic API until 7.1. The baseline `tsconfig.base.json` uses no option
  removed in 7 and no option newer than 5.8, so it should hold on both — but
  only 7.0.2 was actually exercised.
- **`npm audit` needs the network and there is no offline substitute wired in.**
  `osv-scanner --offline` is the only credible one and was left out to avoid a
  non-npm binary and a seeded database. The local gate is therefore blind to
  advisories offline, and says so rather than reporting clean.
- **`supply-chain.sh` can only report, not fix.** It reads `npm config`, so it
  reports the *effective* value including a user-level `~/.npmrc`; a repo whose
  own `.npmrc` is correct can still pass on a machine where it is not, and vice
  versa.
- **Node 24 is the documented fleet target but the toolchain here is Node 22.**
  Everything was validated on 22.23.1. The `engines` range in
  `package-scripts.json` excludes it, deliberately — the recommendation is ahead
  of the validation machine.
- **`noSecrets` false-positive rate is unmeasured.** Enabled at `warn` for that
  reason.
- **The 90 warn/info recommended rules are promoted wholesale** by
  `--error-on-warnings`. That is the correct default, but no consumer has run it
  against a real codebase yet, so the initial churn on `moongit/web` is unknown.
- **knip is not wired in.** It is in `package-scripts.json` as a command, not in
  the gate: its maintainers endorse CI gating but only after the `rules` map is
  tuned per repo, and `--include cycles` does not fail without
  `rules: {cycles: "error"}`.
