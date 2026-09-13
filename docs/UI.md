# UI, done consistently

How a web UI in the fleet is split into pieces and how those pieces are styled.
Framework-neutral: teleport is Svelte 5, codefort is React 19, and every rule
here holds in both. `[gate]` marks what `tsq/ci`'s ui-lint checks — the rest is
review surface. Each repo's `CLAUDE.md` links here and keeps only its own delta:
file layout, where the base stylesheet is, how a primitive is promoted.

Companions: [TS.md](TS.md) — the code. [STACK.md](STACK.md) — what to reach for.

---

## 0. What is not here

1. **No utility framework, no CSS-in-JS, no CSS modules.** Class names are part
   of the contract: tests, keyboard-nav selectors and `is-*` state flags target
   them, and a hashed or generated name breaks that. A task that seems to need
   one doesn't — ask before adding a dependency.
2. **No component library, no state-management library.** The in-repo
   primitives are the vocabulary (§2). A store is a plain module until it isn't.

## 1. Styling: BEM, strictly

3. **Every class is `block`, `block__element`, `block--modifier` or
   `block__element--modifier`.** Lower-case, hyphen-separated words. Nothing
   else. `[gate: bem-class]`
   ```css
   .board-col { }                 /* block */
   .board-col__head { }           /* element */
   .board-col__head--done { }     /* element modifier */
   .btn--primary { }              /* block modifier */
   ```
4. **No element inside an element.** `block__element__sub` is not BEM. If a part
   has its own parts it is its own block: `session-row` is a sibling of
   `session-list`, not `session-list__row`.
5. **Modifier words are hyphenated, not underscored.** `--in-progress`, not
   `--in_progress`. A domain enum with underscores gets mapped at the call
   site (§2, rule 12), not leaked into the class name. `[gate: bem-class]`
6. **State flags use the `is-*` / `has-*` prefix** and toggle on top of a block:
   `is-active`, `is-loading`, `is-vim-selected`. They are the only classes that
   are not BEM. `sr-only` is the one utility.
7. **One class names the thing; modifiers toggle variants.** Never build a
   second class that just forwards to a shared one — plain CSS has no `@extend`,
   so a wrapper duplicates the rule. Apply the shared block directly:
   `<span class="dot dot--success">`.
8. **Conditional classes go through one composer**, never a template-literal
   ternary that leaves a trailing space or an empty token. React: `clsx`.
   Svelte: the `class:` directive. A pure interpolation with no condition
   (`` `ci-badge ci-badge--${status}` ``) stays a template literal.

## 2. Structure: where a block lives

9. **Shared blocks live in one base stylesheet.** Buttons, badges, dots,
   banners, notices, toasts, the app shell, and any block used by more than one
   feature or by the primitives. Each repo's `CLAUDE.md` names the file and
   keeps a table of the shared blocks and their modifiers. **Check the table
   before adding a color or a variant.**
10. **Feature-specific blocks stay with the feature.** Svelte: the component's
    own `<style>`. React: a co-located `features/<x>/<x>.css` imported by that
    feature's pages. Do not promote until a second consumer actually exists.
11. **A pattern used by two features graduates to a primitive** — the shell
    moves into the shared vocabulary (`src/ui/` in React, a shared block in the
    base stylesheet in Svelte), the feature keeps its call site. Every primitive
    gets a row in the gallery / the shared-block table when it lands.
12. **Domain → presentation mapping stays in the feature.** The primitive knows
    `{glyph, colorClass}`; the feature knows that `merged` means the purple one.
    Route matching, mutation wiring and other caller-derived state stay at the
    call site — the primitive owns markup and class composition only.
13. **Compose, don't wrap.** A component element class that exists only to
    forward to a shared block is a wrapper; delete it and put the shared class on
    the element.

## 3. Tokens

14. **Colors, spacing, radii, shadows and durations are custom properties on
    `:root`.** A component never hardcodes a hex or `rgb()` color, an ad-hoc
    `border-radius: Npx`, or a bespoke transition duration — it reuses a token
    or adds one to the base stylesheet. A `var(--x, #hex)` fallback is still a
    raw literal; the token is the fallback. `[gate: raw-color, raw-radius,
    raw-duration]`
15. **Theme is a token swap, not a second stylesheet.** Light/dark and named
    schemes redefine the tokens under a selector or `@media`; blocks read tokens
    and never branch on theme themselves. A dark-only app skips the branch and
    says so in its `CLAUDE.md`.

## 4. Motion and accessibility

16. **Every transition and `@keyframes` goes inert under
    `prefers-reduced-motion: reduce`** — one global block in the base stylesheet
    (`0.01ms !important`), never bypassed with an inline duration. That block is
    the one place `!important` belongs.
17. **`:focus-visible` gets a ring globally; nothing sets `outline: none`.**
18. **A color- or icon-only indicator has a text twin.** A status dot is
    `aria-hidden` with an `sr-only` label beside it; an icon button has a
    label. Static a11y rules in Biome are error-level: fix the violation, and
    suppress a deliberate exception inline with its reason.

## 5. Before calling it done

19. **Look at it.** A clean build proves the CSS parses, not that it looks
    right. Screenshot the affected views (headless Chromium is enough), in every
    scheme and both system appearances the app supports.
20. **The gate is a floor.** ui-lint sees class selectors and literals in
    stylesheets, nothing in markup and nothing about whether a block is split
    right. Rules 4, 9–13 are review surface.
