# ts-quality

Shared TypeScript/web quality-gate toolchain as a [mooncake](https://github.com/alehatsman/mooncake) module — one canonical [Biome](https://biomejs.dev) config plus lint / format / typecheck / build / test / vuln components and CI gates. The TS analog of `go-quality`.

## Use

```yaml
modules:
  tq: "127.0.0.1:8080/alehatsman/ts-quality@v0.1.0"

tasks:
  ui-lint:      { steps: [{ use: tq/lint,      props: { dir: web } }] }
  ui-typecheck: { steps: [{ use: tq/typecheck, props: { dir: web } }] }
  ui-build:     { steps: [{ use: tq/build,     props: { dir: web } }] }
  ui-test:      { steps: [{ use: tq/test,      props: { dir: web } }] }
  ci:           { steps: [{ use: tq/ci,        props: { dir: web } }] }
  ci-fast:      { steps: [{ use: tq/ci-fast,   props: { dir: web } }] }
```

Every shell component takes a `dir` prop (default `.`) threaded into the step cwd
so a consumer can target a subdirectory (e.g. `web`).

## Components

| export        | runs                                          |
|---------------|-----------------------------------------------|
| `ci` / default| npm ci → tsc -b → biome check → vite build → playwright test |
| `ci-fast`     | tsc -b → biome check                          |
| `tools`       | npm ci (+ Playwright browsers)                |
| `sync-config` | copy the shared `biome.json` baseline into the consumer |
| `lint`        | `biome check` (lint + format + assist)        |
| `format`      | `biome format --write`                        |
| `typecheck`   | `tsc -b`                                       |
| `build`       | `vite build`                                  |
| `test`        | `playwright test`                             |
| `vuln`        | `npm audit`                                    |

## Shared Biome config

`biome.json` is the shared baseline (house style: 2-space indent, 100 col,
`semicolons: asNeeded`, double quotes, es5 trailing commas; recommended linter).
`sync-config` drops it into the consumer as `biome.base.json`; the consumer's own
`biome.json` then `extends ["./biome.base.json"]` and layers local rule overrides.
Biome merges config natively, so the baseline stays the source of truth.
