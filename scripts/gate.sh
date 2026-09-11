#!/usr/bin/env bash
# gate.sh — the quality gate. `gate.sh fast` before a commit, `gate.sh full`
# before a push. First failure stops the run.
#
# There is no per-command wrapper here and no component for `vite build`. The
# tools already are the interface; wrapping one npx invocation in YAML adds a
# file and removes nothing. What this script owns is the part they cannot
# express: ordering, fail-fast, and the gotchas that silently pass otherwise —
#
#   * `biome check` EXITS 0 ON WARNINGS. So does `biome ci`. 90 of Biome's 223
#     recommended rules are warn/info by default, so a bare `biome check` is a
#     gate over 133 rules pretending to be a gate over 223. Every invocation
#     here carries --error-on-warnings.
#   * --max-diagnostics defaults to 20 and truncates the human report. A gate
#     that says "20 problems" when there are 300 is lying by omission.
#   * a consumer can weaken an inherited tsconfig setting silently -> config-check
#   * agent residue is invisible to Biome -> ai-lint
#
# Knobs: DIR (.), CAP_LOC (500), BIOME_ARGS, TSC_ARGS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

MODE="${1:-full}"

# Gate the project the caller is standing in. A consumer whose packages are not
# one workspace passes each by `dir`, which is a `cd` before this script runs —
# an unconditional jump to the git toplevel would undo it on line one, silently.
# Falling back to the toplevel keeps the convenience of running it from anywhere
# in a single-package repo.
if [ ! -f package.json ]; then
  cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi
[ -f package.json ] || { echo "✗ no package.json here or at the repo root" >&2; exit 1; }

# `npx --no-install`: a gate must not reach the network to find its own tools,
# and it must not silently run a DIFFERENT version than the lockfile pins.
# Without it, a missing biome is fetched from the registry mid-gate.
bx() { npx --no-install "$@"; }
have_script() { node -e 'const s=require("./package.json").scripts||{};process.exit(s[process.argv[1]]?0:1)' "$1" 2>/dev/null; }
step() { printf '[%s/%s] %s\n' "$1" "$TOTAL" "$2"; }

# render <title> — turn lib.sh records on stdin into an indented human report.
#
# Never call this through a pipe: a pipeline subshell would discard FAILED=1
# and the gate would exit 0 while printing error-level findings. Process
# substitution keeps it in the caller's shell.
#
# Findings go to STDERR, deliberately. provision's default failure view shows a
# step's stderr and not its stdout, so a report written to stdout produced
# "✗ gate failed on the findings above" with no findings above it — the one
# moment the report exists for. They are diagnostics about defects, which is
# what stderr is for; the [n/N] progress lines stay on stdout.
render() {
  local n=0 rule level path lineno msg
  while IFS=$'\t' read -r rule level path lineno msg; do
    printf '  %s:%s: %s: %s\n' "$path" "$lineno" "$rule" "$msg" >&2
    n=$((n + 1))
    [ "$level" = "error" ] && FAILED=1
  done
  if [ "$n" -eq 0 ]; then printf '  ✓ %s: clean\n' "$1" >&2; fi
}
FAILED=0

# shellcheck disable=SC2086
biome_check() { bx biome check --error-on-warnings --max-diagnostics=none ${BIOME_ARGS:-} "$@"; }

case "$MODE" in
# ── fast: pre-commit. No build, no test suite, no network. ───────────────────
fast)
  TOTAL=5
  step 1 "lockfile drift"
  if [ ! -f package-lock.json ]; then
    echo "  ✗ no package-lock.json — run 'npm install', stage it, re-commit" >&2; exit 1
  fi
  # `npm ci --dry-run` is the only offline check that package.json and the
  # lockfile still agree; it exits non-zero naming the offender.
  if ! npm ci --dry-run --offline >/dev/null 2>&1; then
    echo "  ✗ package.json and package-lock.json disagree — run 'npm install', stage the lockfile" >&2; exit 1
  fi
  echo "  ✓ in sync"

  # Biome's own --staged, not a hand-rolled git diff: it already knows how to
  # scope to the index, and it applies the same config it would in CI.
  step 2 "biome check (staged)"
  biome_check --staged .

  step 3 "typecheck"
  # shellcheck disable=SC2086
  bx tsc -b ${TSC_ARGS:-}

  step 4 "ai-lint (staged)"
  mapfile -t files < <(staged_ts)
  if [ "${#files[@]}" -eq 0 ]; then echo "  (no staged source files)"; else
    render "ai-lint" < <(ai_lint "${files[@]}")
  fi

  step 5 "soft caps"
  render "soft caps" < <(god_files)
  ;;

# ── full: pre-push. ─────────────────────────────────────────────────────────
full)
  TOTAL=9
  step 1 "biome check"
  biome_check .

  step 2 "typecheck"
  # shellcheck disable=SC2086
  bx tsc -b ${TSC_ARGS:-}

  step 3 "config drift"
  bash "$HERE/config-check.sh"

  # build and test are the consumer's own scripts on purpose. This module does
  # not decide whether a repo builds with vite or tests with playwright; it
  # decides that a gate runs them. A repo with no such script is not failed for
  # lacking one — it is told, so the omission is visible rather than assumed.
  step 4 "build"
  if have_script build; then npm run build --silent; else echo "  (no build script — skipped)"; fi

  step 5 "test"
  if have_script test; then npm test --silent; else echo "  (no test script — skipped)"; fi

  step 6 "supply chain"
  bash "$HERE/supply-chain.sh"

  step 7 "audit"
  bash "$HERE/audit.sh"

  # Over tracked files, not staged: `fast` only ever sees a staged diff, so a
  # --no-verify commit, an amend, a rebase or a merge walks agent residue
  # straight past the only rules in here that are errors. Piped per file rather
  # than collected into an array — no path ever becomes a word.
  step 8 "ai-lint (tracked)"
  render "ai-lint" < <(tracked_ts | while IFS= read -r f; do ai_lint "$f"; done)

  step 9 "soft caps"
  render "soft caps" < <(god_files)
  ;;

*)
  echo "usage: gate.sh [fast|full]" >&2; exit 2 ;;
esac

[ "$FAILED" -eq 0 ] || { echo; echo "✗ gate failed on the findings above." >&2; exit 1; }
echo
if [ "$MODE" = "fast" ]; then
  echo "✓ fast checks green — full gate runs on push."
else
  echo "✓ all checks green — safe to push."
fi
