# TypeScript, done properly

Baseline: **TypeScript 6.0 / 7.0, Node 24 LTS, Biome 2.5, 2026-09.** Rules, not
essays. `[gate]` marks what `tsq/ci` enforces — everything else is review
surface.

Companion: [STACK.md](STACK.md) — what to reach for.

---

## 0. Before the first line

1. **Spec first for anything non-trivial.** Goal, scope, interfaces, edge cases,
   validation. The type you pick in hour one shows up in every signature by hour
   ten.
2. **Boring tech, few deps, small interfaces.** Every dependency is code you
   ship, a lifecycle script you execute, and a maintainer account that can be
   phished. See §9.
3. **Smallest module that does the job.** Splitting later costs a refactor;
   splitting up front costs a directory.

## 1. Toolchain

4. **Pin Node in `engines` and mean it.** `engine-strict=true` in `.npmrc`, or
   `engines` is a comment. [gate: `engines-advisory-only`, `no-engines`]
   ```json
   "engines": { "node": "^24.0.0 || >=26.0.0" }
   ```
   Node 20 is EOL (2026-04-30). Node 22 is maintenance-only until 2027-04.
   **Node 24 is the only Active LTS.** Vitest 5 does not accept Node 20, 23 or 25.
5. **Commit the lockfile; install with `npm ci`.** It is the only thing that
   makes a build reproducible, and the only offline way to detect that
   `package.json` and the lockfile have drifted apart. [gate: lockfile drift]
6. **TypeScript 7 is the native Go port and it is a real migration, not a bump.**
   `tsc` is a platform binary, `tsserver` is gone, and **there is no programmatic
   API** — `require("typescript")` returns `{version, versionMajorMinor}` and
   nothing else. Anything built on `ts.createProgram` (typescript-eslint, several
   framework language servers) does not work until 7.1. Go via 6.0, which is the
   last JS-based compiler and front-loads the deprecations.
7. **These compiler options are gone in 7.** `target: es5`, `moduleResolution:
   node`/`node10`/`classic`, `module: amd`/`umd`/`system`/`none`,
   `esModuleInterop: false`, `baseUrl`, `downlevelIteration`, `outFile`. Removed
   means `error TS5108`/`TS5102` and **exit 2**, not a warning.
8. **`types` now defaults to `[]` in 7.** `@types/*` packages are no longer
   auto-included; list them explicitly or every global is `TS2304`.

## 2. Project shape

9. **One `tsconfig.base.json` for policy, one `tsconfig.json` for shape.** The
   fleet baseline carries strictness only; `target`, `module`, `moduleResolution`
   and `include` describe your project and stay yours. [gate: `tsconfig-weakened`]
10. **Never weaken an inherited setting.** `extends` merges, so a local
    `"strict": false` silently wins and the compiler says nothing. If you must
    deviate, record why in the file — the gate reports it either way.
11. **Bundler app:** `module: preserve` + `moduleResolution: bundler` + `noEmit`.
    **Node library:** `module: nodenext` + `moduleResolution: nodenext` +
    `declaration` + `composite`. Mixing them produces `TS5095`.
12. **`vite build` type-checks nothing.** It transpiles. `tsc -b && vite build`
    is still the pattern; typecheck is an independent gate step. [gate]
13. **No barrel files.** `index.ts` re-exporting a directory defeats
    tree-shaking and turns one import into a whole subtree.
    [gate: `noBarrelFile`, `noReExportAll`]
14. **No cyclic imports.** [gate: `noImportCycles`]

## 3. Types

15. **`strict: true`, and then the flags `strict` does not cover.**
    `noUncheckedIndexedAccess` is the highest-value of them: `arr[i]` is
    `T | undefined` and pretending otherwise is where runtime `undefined` comes
    from. Also `exactOptionalPropertyTypes`, `noImplicitOverride`,
    `noFallthroughCasesInSwitch`, `noImplicitReturns`,
    `noPropertyAccessFromIndexSignature`. All [gate].
16. **`any` is a bug you have not found yet.** [gate: `noExplicitAny`, promoted
    to error by `--error-on-warnings`] Reach for `unknown` and narrow.
17. **Know the gap.** Biome has no equivalent of typescript-eslint's
    `no-unsafe-argument`/`-assignment`/`-call`/`-member-access`/`-return`, so an
    `any` that enters from an untyped dependency propagates **unflagged**. The
    defence is refusing `any` at the boundary, not the linter.
18. **`as` is an assertion, not a cast.** It tells the compiler to stop
    checking. A type predicate or a schema parse is almost always what you meant.
19. **`erasableSyntaxOnly`.** No `enum`, no `namespace`, no parameter
    properties — all three are `TS1294`. [gate] They are not erasable, so a
    type-stripping runtime cannot run them, and Node removed
    `--experimental-transform-types` in v26. Use a `const` object + union type
    instead of an enum.
20. **`verbatimModuleSyntax`.** Type-only imports say `import type`. [gate]

## 4. Async

21. **Every promise is awaited, returned, or explicitly `void`-ed.**
    [gate: `noFloatingPromises`] A floating promise is a silently swallowed
    rejection.
22. **Never pass an `async` function where a `void` callback is expected.**
    [gate: `noMisusedPromises`]
23. **Only `await` a thenable.** [gate: `useAwaitThenable`]
24. **No `await` inside a loop** unless the iterations genuinely depend on each
    other. `Promise.all` over the array is usually what was meant.

## 5. Errors

25. **Catch is `unknown`.** `useUnknownInCatchVariables` is on under `strict`.
    Narrow before touching `.message`.
26. **Throw `Error`, never a string or an object literal.** Only `Error` carries
    a stack.
27. **An empty catch is a decision.** Write the reason in it, or do not catch.
    [gate: `noEmptyBlockStatements`]

## 6. Style that is not taste

28. **`const` by default, `let` when reassigned, `var` never.** [gate: `noVar`]
29. **`===`, never `==`.** [gate: `noDoubleEquals`]
30. **No `console` in shipped code** beyond `console.error`/`warn`. Use the
    project logger. [gate: `noConsole`]
31. **Cognitive complexity ≤ 15 per function.** [gate:
    `noExcessiveCognitiveComplexity`] Not a line count — a measure of how many
    things you must hold in your head at once.
32. **Files under 500 LOC.** [gate: `god-file`, warning] A soft cap and a smell,
    not a law.
33. **Biome formats; you do not.** `npm run format`. Formatting diagnostics are
    severity `error` and will fail the gate.

## 7. Tests

34. **vitest for unit, playwright for e2e.** [STACK.md]
35. **Fence the two test globs explicitly.** Vitest's default `include` and
    Playwright's default `testMatch` are the same pattern written two ways, and
    neither excludes the other by default. Set Playwright `testDir: './e2e'` and
    Vitest `exclude: [...configDefaults.exclude, 'e2e/**']` — with `**`, not `*`.
    A suffix convention alone will not save you.
36. **No skipped tests on main.** [gate: `noSkippedTests`, warning]
37. **A test that passes on retry still passes by default.** Playwright needs
    `--fail-on-flaky-tests` if you want to know.

## 8. Agent hygiene

38. **No agent-tagged TODOs.** `TODO(claude)` is not an owner. [gate:
    `agent-todo`, error]
39. **No prompt artifacts.** A comment saying "As requested, …" is talking to
    the agent, not the reader. [gate: `ai-self-ref`, error]
40. **No diff relics.** `// REMOVED: …` belongs in commit history.
    [gate: `diff-relic`, error]

None of the three are visible to Biome — verified, which is why `lib.sh` exists.

## 9. Dependencies and supply chain

41. **Set a release cooldown.** `min-release-age=3` in `.npmrc` (npm ≥ 11.10.0,
    the value is in **DAYS**). pnpm's equivalent is `minimumReleaseAge`, in
    **minutes**. [gate: `npm-too-old`, `no-release-cooldown`] This is the single
    highest-value setting available: every major npm compromise of the last year
    was caught within hours-to-days of publication, so a cooldown is what
    actually stops them.
42. **Do not trust `npm audit` as a defence.** It matches an advisory database.
    None of chalk/debug, Shai-Hulud or its 2026 descendants had an advisory
    during their exposure window. Run it, but know what it is for.
43. **Do not trust provenance either.** 84 malicious `@tanstack` versions shipped
    with valid SLSA Build L3 attestations. Provenance proves where a package was
    built, not that it is safe.
44. **Review install scripts.** npm 12 blocks dependency lifecycle scripts by
    default; opt in early with `strict-allow-scripts=true` and an `allowScripts`
    allowlist. [gate: `install-scripts-unreviewed`] Blanket `--ignore-scripts` is
    not the answer — it half-installs esbuild, sharp and Playwright, and fails at
    *runtime*.
45. **`save-exact=true`.** A caret is a window for a freshly published bad
    version to land in your tree.
46. **Every import is a declared dependency.** [gate: `noUndeclaredDependencies`,
    `noUnresolvedImports`] A phantom dependency works until the hoist changes.
47. **No secrets in source.** [gate: `noSecrets`, warning]

## 10. Review checklist

- Does it compile with zero `any` added?
- Is every promise awaited, returned or `void`-ed?
- Is every new dependency declared, and does it deserve to exist?
- Are new errors `Error` subclasses, and is every catch narrowed?
- Does the diff contain a TODO with no owner, or a comment addressed to an agent?
- Did a tsconfig or biome setting get weakened to make something pass?
- If a test was added, is it in the right glob for the right runner?
