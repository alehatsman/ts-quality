#!/usr/bin/env bash
# audit.sh — known-vulnerability check over the dependency tree.
#
# `npm audit` is the only advisory check that needs no extra tool and no
# account, which is why it is the one wired in. Its limits are real and are
# stated here rather than discovered later:
#
#   * it needs the NETWORK. The advisory database is a registry endpoint, not
#     a local file. A gate that must work offline cannot depend on it, so a
#     transport failure is reported as a note and does not fail the gate —
#     while a real advisory does.
#   * it matches versions against an advisory DB. It has no reachability
#     analysis, so a "high" in a transitive dev-only package that never runs
#     in production is scored the same as one in a shipped dependency.
#   * `--omit=dev` is how that noise is cut, and it is the default here.
#
# Usage:
#   bash scripts/audit.sh                 # human report
#   bash scripts/audit.sh --format jsonl  # structured findings
#   bash scripts/audit.sh --warn-only     # always exit 0
#
# Knobs: AUDIT_LEVEL (high), AUDIT_OMIT_DEV (1).
set -euo pipefail

FORMAT="text"
WARN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)    FORMAT="${2:-}"; shift 2 ;;
    --format=*)  FORMAT="${1#*=}"; shift ;;
    --warn-only) WARN_ONLY=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

LEVEL="${AUDIT_LEVEL:-high}"
OMIT_DEV="${AUDIT_OMIT_DEV:-1}"

args=(audit --json --audit-level="$LEVEL")
[ "$OMIT_DEV" = "1" ] && args+=(--omit=dev)

# Buffered, not piped: npm audit exits non-zero BOTH when it finds an advisory
# and when it cannot reach the registry, and those must not be the same verdict.
# The JSON body is what tells them apart.
raw="$(mktemp)"
rc=0
npm "${args[@]}" >"$raw" 2>/dev/null || rc=$?

FORMAT="$FORMAT" WARN_ONLY="$WARN_ONLY" LEVEL="$LEVEL" RC="$rc" RAW="$raw" python3 - <<'PY'
import json, os, pathlib, sys

fmt       = os.environ["FORMAT"]
warn_only = os.environ["WARN_ONLY"] == "1"
level     = os.environ["LEVEL"]
rc        = int(os.environ["RC"])
raw       = pathlib.Path(os.environ["RAW"]).read_text().strip()

def say(*a):
    print(*a, file=sys.stderr if fmt == "jsonl" else sys.stdout)

records = []
def rec(rule, lvl, path, line, message):
    records.append((rule, lvl, path, line, message))

data = None
if raw:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = None

# npm signals an unreachable advisory endpoint by putting an `error` object in
# the JSON body and omitting `metadata` — NOT by withholding `vulnerabilities`,
# which is present and empty on a genuinely clean tree. Keying on the wrong one
# of those made this script report "no advisories" against a dead registry,
# which is the exact failure it exists to prevent. Verified both ways: dead
# registry with deps to audit -> exit 1, `error` present, no `metadata`; live
# registry -> exit 0, `metadata.vulnerabilities` populated.
#
# An unreachable DB is a note, not a gate failure: it is an unknown, and failing
# a push on an unknown trains people to reach for --no-verify.
if data is None or "error" in data or "metadata" not in data:
    rec("audit-unavailable", "note", "package-lock.json", 1,
        "npm audit could not reach the registry — advisories NOT checked this run")
else:
    order = ["info", "low", "moderate", "high", "critical"]
    floor = order.index(level) if level in order else order.index("high")
    for name, v in (data.get("vulnerabilities") or {}).items():
        sev = v.get("severity", "info")
        if sev not in order or order.index(sev) < floor:
            continue
        via = v.get("via") or []
        titles = sorted({x.get("title", "") for x in via if isinstance(x, dict) and x.get("title")})
        detail = "; ".join(titles) if titles else f"vulnerable via {', '.join(str(x) for x in via[:3])}"
        fix = v.get("fixAvailable")
        remedy = " — fix available: npm audit fix" if fix else " — no fix available upstream"
        rec("vulnerable-dep", "error", "package-lock.json", 1,
            f"{name} ({sev}): {detail}{remedy}")

if fmt == "jsonl":
    for rule, lvl, path, line, message in records:
        print(json.dumps({
            "tool": "npm-audit", "rule": rule, "level": lvl, "path": path,
            "line": line, "message": message,
            "fingerprint": f"{rule}:{path}:{line}",
        }, separators=(",", ":")))
else:
    errs = [r for r in records if r[1] == "error"]
    if not records:
        say(f"  ✓ audit: no advisories at or above {level}")
    for rule, lvl, path, line, message in records:
        say(f"  {path}:{line}: {rule}: {message}")
    if errs:
        say(f"  ✗ {len(errs)} advisory(ies) at or above {level}")

if warn_only:
    sys.exit(0)
sys.exit(1 if any(r[1] == "error" for r in records) else 0)
PY
rc=$?
rm -f "$raw"
exit $rc
