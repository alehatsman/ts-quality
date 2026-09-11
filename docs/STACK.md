# The stack

What to reach for, and when not to. **Versions verified against the npm registry
on 2026-09-11.**

Defaults, not laws. Deviating is fine; deviating *silently* is not — write the
reason down in the manifest or an ADR. Companion: [TS.md](TS.md).

---

## Runtime

| | |
|---|---|
| **Node 24 (Krypton)** | Active LTS until 2028-04-30. **The fleet target.** |
| Node 26 | Current; becomes LTS 2026-10-28. Fine to develop on. |
| Node 22 (Jod) | Maintenance only, EOL 2027-04-30. Migrate off. |
| Node 20 (Iron) | **EOL 2026-04-30.** Not supported. |

```json
"engines": { "node": "^24.0.0 || >=26.0.0" }
```

That range is the intersection of what the toolchain actually accepts — Vitest 5
requires `^22.12 || ^24 || >=26`, which excludes the odd-numbered lines, and Vite
8 requires `^20.19 || >=22.12`.

**Type stripping** is Stable as of Node 24.12. Node runs a `.ts` file with no
flag. `--experimental-transform-types` was **removed in v26**, so non-erasable
syntax can never run natively — which is what `erasableSyntaxOnly` guards.

## Default stacks

**Web app**

```json
"devDependencies": {
  "typescript": "~6.0.2",
  "@biomejs/biome": "2.5.13",
  "vite": "8.3.0",
  "vitest": "5.0.0",
  "@playwright/test": "1.63.0"
}
```
That is the whole list for most apps. Add `knip` when the dead-code question
comes up, and nothing else without a reason.

**Library** — the app list, plus `publint` and `@arethetypeswrong/cli` in the
release script. Both are no-ops for a private app; both matter the moment you
publish.

## The picks

| Need | Pick | Why, and when not to |
|---|---|---|
| Lint + format | **Biome 2.5.13** | One Rust binary, no `tsc` dependency, formats too. 538 rules. The gap is type-aware coverage — 17 rules, none recommended. |
| Type-aware lint | **Biome's 17, opted in** | See the gap note below. |
| Compiler | **TypeScript 6.0.2**, 7.0.2 opt-in | 7 is the Go port: 8–12× faster, no programmatic API until 7.1. create-vite's own templates still pin `~6.0.2`. |
| Bundler | **Vite 8.3.0** | Rolldown is the default and **mandatory** — no documented opt-out to Rollup. Oxc replaces esbuild; Lightning CSS is default. |
| Unit tests | **Vitest 5.0.0** | 53.8% usage / 97% satisfaction in State of JS 2025, the largest YoY gain alongside Playwright. `v8` coverage now AST-remapped, so the old reason to prefer istanbul is gone. |
| E2E | **Playwright 1.63.0** | 94% satisfaction. `--only-shell` skips the headed Chromium download in CI. Do not cache browser binaries — the docs advise against it. |
| Dead code | **knip 6.35.1** | Dropped the TS compiler API for oxc in v6, so it is **immune to the TS 7 API removal**. Gateable, but tune `rules` to `warn` first. |
| Publish checks | **publint 0.3.24** + **attw 0.18.5** | Libraries only. attw needs `--pack` explicitly in CI or it hard-errors. |

## Deliberately not the pick

- **typescript-eslint** — cannot run on TypeScript 7. `require("typescript")`
  exposes only `version`; `createProgram` is gone. This is a hard blocker, not a
  preference.
- **oxlint / tsgolint** — genuinely better type-aware coverage (59/61 vs Biome's
  17) and it *does* support TS 7. Left out because it is a second linter, a
  second config and a Go binary beside Biome, with no formatter. oxc's own docs
  warn it degrades on monorepos with many project references. **Revisit if the
  `no-unsafe-*` gap starts costing real bugs.**
- **Jest** — 74.4% usage but 65% satisfaction (B-tier). Vitest is faster, shares
  Vite's transform pipeline, and is where the ecosystem went.
- **Cypress** — C-tier, ~57%. Playwright won.
- **ESLint + Prettier** — two tools, two configs and a plugin graph, for what
  Biome does in one binary. create-vite now ships oxlint rather than ESLint.
- **jscpd** for duplication — 5.2.0 is a credible Rust rewrite on the oxc parser,
  but a typo'd `--format` or a missing path **exits 0**, and `--fail-on-empty` is
  not in the released version. Revisit when a misconfigured run is loud.
- **`node:test`** — Stable, but coverage is still
  `--experimental-test-coverage`. Not competitive for a web repo.

## The type-aware gap, stated plainly

Biome ships 17 type-aware rules. 13 are `nursery`, **none** are recommended, and
all default to `info` severity — so they are a silent no-op unless you both
enable them and raise the level, which `biome.json` does for five of them.

Absent entirely, with no Biome equivalent: `no-unsafe-argument`,
`no-unsafe-assignment`, `no-unsafe-call`, `no-unsafe-member-access`,
`no-unsafe-return`, `restrict-template-expressions`,
`no-unnecessary-type-assertion`, `unbound-method`, `strict-boolean-expressions`.

Biome self-reports ~85% detection on `noFloatingPromises` versus
typescript-eslint. The mitigation is upstream: `strict` +
`noUncheckedIndexedAccess` + `exactOptionalPropertyTypes` + `noExplicitAny` at
error keeps `any` from entering. That works if your dependencies are typed. If
they are not, reconsider oxlint.

## Supply chain

| Setting | Value | Note |
|---|---|---|
| `min-release-age` | `3` | **DAYS.** npm ≥ 11.10.0. The highest-value setting available. |
| `strict-allow-scripts` | `true` | npm ≥ 11.16.0. Default-on in npm 12. |
| `engine-strict` | `true` | Otherwise `engines` is a comment. |
| `save-exact` | `true` | A caret is an attack window. |

pnpm's equivalent cooldown is `minimumReleaseAge` and it is in **minutes**, with
a default of 1440 since pnpm 11. npm's is in days and defaults to off — still
off in npm 12.

**Platform-binary risk is now systemic.** TypeScript 7, Biome, Rolldown and
jscpd 5 all ship native per-platform `optionalDependencies`. An `npm ci` against
a lockfile built on another OS/arch can silently omit the binary, and pnpm does
not install optionalDependencies by default. `tsq/tools check` verifies biome and
tsc are actually reachable rather than assuming the install worked.
