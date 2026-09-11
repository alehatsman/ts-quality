#!/usr/bin/env bash
# tools.sh install | check — get a consumer to the point where the gate can run.
#
# Unlike the Rust and Go siblings, there is almost nothing to install globally:
# biome, typescript, vite and playwright are all project devDependencies pinned
# by the consumer's own lockfile. Installing them globally would be actively
# wrong — the gate would then run a different version than CI does.
#
# So `install` is `npm ci` plus the one thing a lockfile cannot express: the
# Playwright browser binaries, which live outside node_modules.
#
# `--ignore-scripts` is deliberately NOT used. It is the strongest single
# defence against install-time supply-chain attacks, and it also breaks
# esbuild, playwright and every native module in the mainstream TS stack, so
# turning it on by default would be a gate nobody can run. It is exposed as a
# knob instead, and docs/TS.md says when to reach for it.
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
bx()   { npx --no-install "$@"; }

case "${1:-check}" in
install)
  [ -f package.json ] || { echo "✗ no package.json here" >&2; exit 1; }

  if [ -f package-lock.json ]; then
    echo "→ npm ci"
    # Unquoted on purpose: NPM_INSTALL_ARGS is a list of flags, not one word.
    # shellcheck disable=SC2086
    npm ci ${NPM_INSTALL_ARGS:-}
  else
    # `npm ci` REQUIRES a lockfile and fails without one. Saying so beats the
    # raw npm error, which tells a first-time consumer to run `npm ci`.
    echo "  (no package-lock.json — running 'npm install' to create one; commit it)"
    # shellcheck disable=SC2086
    npm install ${NPM_INSTALL_ARGS:-}
  fi

  # Only when the consumer actually depends on Playwright. Installing Chromium
  # into a repo that does not test with it is a 150MB surprise.
  if [ -d node_modules/@playwright/test ]; then
    echo "→ playwright install chromium"
    bx playwright install chromium
  else
    echo "  (no @playwright/test — skipping browser download)"
  fi

  echo
  echo "✓ installed. Optional, on demand:"
  echo "    npx knip                     unused files / exports / dependencies"
  echo "    npx publint                  package publish correctness (libraries)"
  echo "    npx @arethetypeswrong/cli     .d.ts resolution across module modes"
  ;;
check)
  missing=0
  # node and npm are the only things that must exist on PATH. Everything else
  # is asked for through `npx --no-install`, which answers the real question:
  # is it in THIS project's node_modules, at the version the lockfile pins.
  for t in node npm; do
    if have "$t"; then printf '  ✓ %s (%s)\n' "$t" "$("$t" --version 2>/dev/null)"
    else printf '  ✗ %s — MISSING\n' "$t"; missing=$((missing + 1)); fi
  done
  for t in biome tsc; do
    if bx "$t" --version >/dev/null 2>&1; then
      printf '  ✓ %s (%s)\n' "$t" "$(bx "$t" --version 2>/dev/null | tr -d '\n' | sed 's/^Version:* *//')"
    else
      printf '  ✗ %s — not in node_modules (npm ci)\n' "$t"; missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] || { echo; echo "$missing missing. Run: scripts/tools.sh install"; exit 1; }
  ;;
*)
  echo "usage: tools.sh [install|check]" >&2; exit 2 ;;
esac
