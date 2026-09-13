#!/usr/bin/env bash
# config-check — assert the consumer did not quietly weaken the shared config.
#
# Biome and tsc both have a native `extends`, so unlike go-quality (golangci-lint
# has no config merge) and rust-quality (cargo has no manifest include), the
# baseline here really is copied in and really does merge. That solves the
# "did the copy drift" problem and creates a different one: `extends` lets a
# consumer OVERRIDE an inherited setting, silently.
#
# That is not theoretical. A consumer extending a base with `strict: true` and
# setting `strict: false` locally compiles an implicit-any function with exit 0
# and no diagnostic. Verified on typescript 7.0.2.
#
# So this checks the RESOLVED config, not the file text — `tsc --showConfig`
# resolves `extends` for us, the same move go-quality makes by asking
# golangci-lint rather than grepping YAML.
#
#   tsconfig-weakened   a baseline compilerOption resolved to a weaker value
#   tsconfig-absent     no tsconfig.json in the target directory
#   biome-unparseable   consumer biome.json is not strict JSON (Biome then runs with defaults)
#   biome-not-extended  consumer biome.jsonc does not extend the baseline
#   biome-rule-off      consumer turned a baseline-enabled rule off
#   biome-first-exception  consumer files.includes starts with a negation; Biome matches no files
#
# Usage:
#   bash scripts/config-check.sh                # human report
#   bash scripts/config-check.sh --format jsonl # structured findings
#   bash scripts/config-check.sh --warn-only    # always exit 0
set -euo pipefail

FORMAT="text"
WARN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)    FORMAT="${2:-}"; shift 2 ;;
    --format=*)  FORMAT="${1#*=}"; shift ;;
    --warn-only) WARN_ONLY=1; shift ;;
    -h|--help)   sed -n '2,26p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

case "$FORMAT" in
  text|jsonl) ;;
  *) echo "config-check: unknown --format '$FORMAT' (want text|jsonl)" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON_TS="${CANON_TS:-$HERE/tsconfig.base.json}"
CANON_BIOME="${CANON_BIOME:-$HERE/biome.json}"

# Resolve the consumer's tsconfig with tsc itself. Buffered to a file: a
# pipeline would hide tsc's exit status, and "tsc is not installed" must not
# read the same as "the config is clean".
SHOWN=""
if [ -f tsconfig.json ]; then
  SHOWN="$(mktemp)"
  if ! npx --no-install tsc -p . --showConfig >"$SHOWN" 2>/dev/null; then
    : > "$SHOWN"   # empty file = "could not resolve"; python reports it as such
  fi
fi

CANON_TS="$CANON_TS" CANON_BIOME="$CANON_BIOME" SHOWN="$SHOWN" \
FORMAT="$FORMAT" WARN_ONLY="$WARN_ONLY" python3 - <<'PY'
import json, os, pathlib, re, sys

fmt       = os.environ["FORMAT"]
warn_only = os.environ["WARN_ONLY"] == "1"
shown     = os.environ["SHOWN"]

def say(*a):
    print(*a, file=sys.stderr if fmt == "jsonl" else sys.stdout)

records = []
def rec(rule, level, path, line, message):
    records.append((rule, level, path, line, message))

def strip_jsonc(text):
    """Comment-strip our own controlled JSONC. Skips // and /* */ outside strings."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2; continue
                if text[j] == '"':
                    break
                j += 1
            out.append(text[i:j+1]); i = j + 1; continue
        if text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if text.startswith("/*", i):
            j = text.find("*/", i); i = n if j < 0 else j + 2; continue
        out.append(c); i += 1
    return "".join(out)

def load_jsonc(p):
    return json.loads(strip_jsonc(pathlib.Path(p).read_text()))

# ── tsconfig ────────────────────────────────────────────────────────────────
canon_ts = load_jsonc(os.environ["CANON_TS"]).get("compilerOptions", {})

if not pathlib.Path("tsconfig.json").is_file():
    rec("tsconfig-absent", "error", "tsconfig.json", 1,
        "no tsconfig.json — a TS repo consuming ts-quality without one is misconfigured, not exempt")
elif not shown or not pathlib.Path(shown).read_text().strip():
    rec("tsconfig-unresolved", "error", "tsconfig.json", 1,
        "tsc --showConfig failed — is typescript installed? (npm ci)")
else:
    got = json.loads(pathlib.Path(shown).read_text()).get("compilerOptions", {})
    # tsc lowercases enum-ish values in --showConfig output; the baseline is
    # all booleans, so a case-insensitive compare is enough and avoids a
    # false positive on anything that is not.
    for key, want in canon_ts.items():
        if key not in got:
            rec("tsconfig-weakened", "error", "tsconfig.json", 1,
                f"{key} is not set; the baseline requires {json.dumps(want)}")
        elif got[key] != want:
            rec("tsconfig-weakened", "error", "tsconfig.json", 1,
                f"{key} resolved to {json.dumps(got[key])}, baseline requires {json.dumps(want)}")

# ── biome ───────────────────────────────────────────────────────────────────
# Biome merges `extends` natively, so there is nothing to diff rule-by-rule the
# way go-quality must. Two things still have to be asserted: that the consumer
# extends the baseline at all, and that it did not switch an inherited rule off.
consumer_biome = next((p for p in ("biome.jsonc", "biome.json") if pathlib.Path(p).is_file()), None)
cfg = None
if consumer_biome is None:
    rec("biome-not-extended", "error", "biome.jsonc", 1,
        "no biome.jsonc — run tsq/sync-config, then extend ./biome.base.json")
elif consumer_biome == "biome.json":
    # Biome reads biome.json as strict JSON. A comment in it is a parse error,
    # and Biome then runs with a DEFAULT config — no extends, no excludes —
    # instead of failing. It crawled a consumer's dist/ for five minutes once.
    try:
        cfg = json.loads(pathlib.Path(consumer_biome).read_text())
    except json.JSONDecodeError as e:
        rec("biome-unparseable", "error", consumer_biome, e.lineno,
            f"not strict JSON ({e.msg}); Biome silently runs with defaults — rename to biome.jsonc")
else:
    cfg = load_jsonc(consumer_biome)
if cfg is not None:
    ext = cfg.get("extends", [])
    if isinstance(ext, str):
        ext = [ext]
    if not any("biome.base.json" in e for e in ext):
        rec("biome-not-extended", "error", consumer_biome, 1,
            'does not extend the baseline — add "extends": ["./biome.base.json"]')
    raw = pathlib.Path(consumer_biome).read_text()
    # `files.includes` replaces the baseline's list, and a list whose first
    # pattern is a negation matches NO files: `biome check .` processes only
    # the config and exits 0. Biome's own noBiomeFirstException reports this
    # for biome.json but not biome.jsonc, and biome.jsonc is the consumer file.
    inc = (cfg.get("files") or {}).get("includes")
    if isinstance(inc, list) and inc and isinstance(inc[0], str) and inc[0].startswith("!"):
        line = next((i for i, l in enumerate(raw.splitlines(), 1)
                     if '"includes"' in l), 1)
        rec("biome-first-exception", "error", consumer_biome, line,
            'files.includes starts with a negation, so Biome matches no files — put "**" first')
    # A rule set to "off" anywhere in the consumer's own rules block is drift
    # worth surfacing. Reported per rule so the message names the rule.
    rules = (cfg.get("linter") or {}).get("rules") or {}
    for group, entries in rules.items():
        if not isinstance(entries, dict):
            continue
        for rule, val in entries.items():
            sev = val if isinstance(val, str) else (val or {}).get("level")
            if sev == "off":
                line = next((i for i, l in enumerate(raw.splitlines(), 1)
                             if re.search(rf'"{re.escape(rule)}"', l)), 1)
                rec("biome-rule-off", "warning", consumer_biome, line,
                    f"{group}/{rule} is switched off — record why, or drop the override")

# ── render ──────────────────────────────────────────────────────────────────
if fmt == "jsonl":
    for rule, level, path, line, message in records:
        print(json.dumps({
            "tool": "tsq", "rule": rule, "level": level, "path": path,
            "line": line, "message": message,
            "fingerprint": f"{rule}:{path}:{line}",
        }, separators=(",", ":")))
else:
    if not records:
        say("  ✓ config-check: consumer config matches the baseline")
    for rule, level, path, line, message in records:
        say(f"  {path}:{line}: {rule}: {message}")

if warn_only:
    sys.exit(0)
sys.exit(1 if any(r[1] == "error" for r in records) else 0)
PY
rc=$?
[ -n "$SHOWN" ] && rm -f "$SHOWN"
exit $rc
