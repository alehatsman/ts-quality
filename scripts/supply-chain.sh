#!/usr/bin/env bash
# supply-chain.sh — is this repo configured to survive 2026's npm threat model?
#
# WHY THIS EXISTS, AND WHY `npm audit` IS NOT ENOUGH.
#
# npm audit matches installed versions against an advisory database. Every
# major npm compromise of the last year was a freshly-published malicious
# version of a legitimate package, and an advisory does not exist at the moment
# it lands. The Sept 2025 chalk/debug clipper, Shai-Hulud and its 2026
# descendants (SANDWORM_MODE, Mini Shai-Hulud, the AntV and keyv waves) would
# every one of them have passed a clean `npm audit` during their exposure
# window. So audit is necessary and not close to sufficient.
#
# What actually stops that class is configuration, and it is configuration npm
# only grew recently:
#
#   * `min-release-age` (npm >= 11.10.0, in DAYS) refuses versions published
#     less than N days ago. This is the single highest-value setting available,
#     because every one of those attacks was caught and unpublished within
#     hours-to-days. Note the name: it is `min-release-age`, not
#     `minimumReleaseAge` (that is pnpm's key, and it is in MINUTES).
#   * `allowScripts` (npm >= 11.16.0, default-on in npm >= 12.0.0) blocks
#     dependency lifecycle scripts unless allowlisted. Shai-Hulud ran from
#     postinstall; its 2026 descendants moved to preinstall.
#   * `engine-strict` makes `engines` enforcement real rather than advisory.
#
# One thing deliberately NOT checked: provenance/SLSA attestation. Mini
# Shai-Hulud published 84 malicious @tanstack versions that all carried VALID
# SLSA Build L3 provenance — the attacker ran inside a genuine, correctly
# attested build job. Provenance proves origin, not innocence, and a gate that
# treated it as a safety signal would be teaching the wrong lesson.
#
# Usage:
#   bash scripts/supply-chain.sh                 # human report
#   bash scripts/supply-chain.sh --format jsonl  # structured findings
#   bash scripts/supply-chain.sh --warn-only     # always exit 0
#
# Knobs: MIN_RELEASE_AGE (3, days).
set -euo pipefail

FORMAT="text"
WARN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)    FORMAT="${2:-}"; shift 2 ;;
    --format=*)  FORMAT="${1#*=}"; shift ;;
    --warn-only) WARN_ONLY=1; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

NPM_V="$(npm --version 2>/dev/null || echo 0.0.0)"
CFG_AGE="$(npm config get min-release-age 2>/dev/null || echo undefined)"
CFG_ENGINE_STRICT="$(npm config get engine-strict 2>/dev/null || echo false)"
CFG_STRICT_SCRIPTS="$(npm config get strict-allow-scripts 2>/dev/null || echo undefined)"

NPM_V="$NPM_V" CFG_AGE="$CFG_AGE" CFG_ENGINE_STRICT="$CFG_ENGINE_STRICT" \
CFG_STRICT_SCRIPTS="$CFG_STRICT_SCRIPTS" WANT_AGE="${MIN_RELEASE_AGE:-3}" \
FORMAT="$FORMAT" WARN_ONLY="$WARN_ONLY" python3 - <<'PY'
import json, os, pathlib, sys

fmt       = os.environ["FORMAT"]
warn_only = os.environ["WARN_ONLY"] == "1"
want_age  = int(os.environ["WANT_AGE"])

def say(*a):
    print(*a, file=sys.stderr if fmt == "jsonl" else sys.stdout)

records = []
def rec(rule, level, path, line, message):
    records.append((rule, level, path, line, message))

def ver(s):
    out = []
    for part in s.strip().split("."):
        num = "".join(c for c in part if c.isdigit())
        out.append(int(num) if num else 0)
    while len(out) < 3:
        out.append(0)
    return tuple(out[:3])

npm_v = ver(os.environ["NPM_V"])

# ── the npm CLI itself ──────────────────────────────────────────────────────
# 11.10.0 is where `min-release-age` landed; below it the defence is not
# available at any price, so the remedy is a toolchain bump, not a config line.
if npm_v < (11, 10, 0):
    rec("npm-too-old", "warning", "package.json", 1,
        f"npm {'.'.join(map(str, npm_v))} predates min-release-age (npm 11.10.0) — "
        "the strongest available defence against freshly-published malware cannot be enabled")
else:
    age = os.environ["CFG_AGE"].strip()
    if age in ("undefined", "null", ""):
        rec("no-release-cooldown", "warning", ".npmrc", 1,
            f"min-release-age is unset — set it to {want_age} (DAYS) so a version published "
            "minutes ago cannot be installed")
    else:
        try:
            if int(age) < want_age:
                rec("release-cooldown-short", "note", ".npmrc", 1,
                    f"min-release-age={age} days, below the fleet default of {want_age}")
        except ValueError:
            pass

if npm_v >= (11, 16, 0) and os.environ["CFG_STRICT_SCRIPTS"].strip() not in ("true",):
    rec("install-scripts-unreviewed", "warning", ".npmrc", 1,
        "strict-allow-scripts is not true — dependency lifecycle scripts run unreviewed. "
        "npm 12 blocks them by default; opt in early with an allowScripts policy")

if os.environ["CFG_ENGINE_STRICT"].strip() != "true":
    rec("engines-advisory-only", "note", ".npmrc", 1,
        "engine-strict is false, so `engines` is a warning rather than a constraint")

# ── the manifest and lockfile ───────────────────────────────────────────────
pkg_path = pathlib.Path("package.json")
if pkg_path.is_file():
    try:
        pkg = json.loads(pkg_path.read_text())
    except json.JSONDecodeError:
        pkg = {}
        rec("package-json-unparseable", "error", "package.json", 1, "package.json is not valid JSON")
    if pkg and not pkg.get("engines"):
        rec("no-engines", "note", "package.json", 1,
            "no `engines` field — nothing records which Node this is supposed to run on")

lock = pathlib.Path("package-lock.json")
if not lock.is_file():
    rec("no-lockfile", "error", "package-lock.json", 1,
        "no package-lock.json — installs are unpinned and `npm ci` cannot run")
else:
    try:
        lv = json.loads(lock.read_text()).get("lockfileVersion")
        if isinstance(lv, int) and lv < 3:
            rec("lockfile-outdated", "note", "package-lock.json", 1,
                f"lockfileVersion {lv}; npm 9+ writes 3. Re-run `npm install` on a current npm")
    except json.JSONDecodeError:
        rec("lockfile-unparseable", "error", "package-lock.json", 1,
            "package-lock.json is not valid JSON")

# npm 12 no longer loads npm-shrinkwrap.json at all, so a repo still relying on
# one is pinned by a file that will stop being read.
if pathlib.Path("npm-shrinkwrap.json").is_file():
    rec("shrinkwrap-removed", "warning", "npm-shrinkwrap.json", 1,
        "npm 12 removed shrinkwrap support and no longer honors this file — migrate to package-lock.json")

# ── render ──────────────────────────────────────────────────────────────────
if fmt == "jsonl":
    for rule, level, path, line, message in records:
        print(json.dumps({
            "tool": "supply-chain", "rule": rule, "level": level, "path": path,
            "line": line, "message": message,
            "fingerprint": f"{rule}:{path}:{line}",
        }, separators=(",", ":")))
else:
    if not records:
        say("  ✓ supply-chain: configured against the 2026 threat model")
    for rule, level, path, line, message in records:
        say(f"  {path}:{line}: {rule}: {message}")

if warn_only:
    sys.exit(0)
sys.exit(1 if any(r[1] == "error" for r in records) else 0)
PY
