# ts-quality

Shared TypeScript/web quality-gate toolchain as a [mooncake](https://github.com/alehatsman/mooncake) module — one canonical [Biome](https://biomejs.dev) config plus lint / format / typecheck / build / test / vuln components and CI gates. The TS analog of `go-quality`.

## Use

Hoist the `dir` prop into the binding as a **default prop** (mooncake ≥ the
default-props/shorthand release) and wire each export with the one-line
task-as-alias shorthand:

```yaml
modules:
  tq:
    source: "127.0.0.1:8080/alehatsman/ts-quality@v0.1.0"
    props:
      dir: web              # applied to every tq/* export that declares it

tasks:
  ui-lint:      tq/lint
  ui-typecheck: tq/typecheck
  ui-build:     tq/build
  ui-test:      tq/test
  ci:           tq/ci
  ci-fast:      tq/ci-fast
  # sync-config takes a `dest`, not `dir`, so the default is filtered out:
  ui-sync-config:
    steps:
      - use: tq/sync-config
        props: { dest: "{{ invocation_dir }}/web/biome.json" }
```

Every shell component takes a `dir` prop (default `.`) threaded into the step
cwd so a consumer can target a subdirectory (e.g. `web`). Declared once as a
module-level default prop, it's applied only to the exports that declare it
(so `sync-config`, which takes `dest`, ignores it); a per-call `props:` still
overrides. `mooncake task` lists each component's own `description:`, so a
shorthand task needs no `desc:`. The verbose form still works if you prefer it
explicit: `ui-lint: { steps: [{ use: tq/lint, props: { dir: web } }] }`.

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
