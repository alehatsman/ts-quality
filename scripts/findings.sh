#!/usr/bin/env bash
# findings.sh — the agent-facing view: every finding as one JSON object per
# line, in the shared fleet schema.
#
#   {"tool":..,"rule":..,"level":"error|warning|note","path":..,"line":N,
#    "col":N?,"message":..,"fingerprint":"rule:path:line"}
#
# gate.sh renders the same checks for humans from the same functions in lib.sh.
# The format lives at the edge, not duplicated across every emitter.
#
# A pure producer: it never re-gates and never aborts on a finding. Enforcement
# is gate.sh's job. Dedup across runs via `fingerprint`.
#
# Two things worth knowing about the Biome leg:
#   * `--reporter=json` is native, so nothing here parses Biome's human output.
#   * `--max-diagnostics` caps the HUMAN reporter at 20 but does not cap the
#     json one. It is passed anyway, because relying on that asymmetry silently
#     is how a cap starts truncating an artifact nobody re-checks.
# And one that is NOT a problem here: unlike `cargo clippy`, a warm `tsc -b`
# still re-reports its errors (verified over three consecutive runs), so there
# is no cache to bust before collecting.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

OUT="${1:-}"

if [ ! -f package.json ]; then
  cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi

bx() { npx --no-install "$@"; }

emit() {  # stdin: lib.sh records -> stdout: JSONL
  python3 -c '
import json, sys
for raw in sys.stdin:
    parts = raw.rstrip("\n").split("\t")
    if len(parts) != 5:
        continue
    rule, level, path, line, message = parts
    print(json.dumps({
        "tool": "tsq", "rule": rule, "level": level, "path": path,
        "line": int(line), "message": message,
        "fingerprint": f"{rule}:{path}:{line}",
    }, separators=(",", ":")))'
}

biome_findings() {
  [ -f package.json ] || return 0
  local json rc=0
  json="$(mktemp)" || return 0
  # No --error-on-warnings here: this is a producer, and the severity a rule
  # carries is data to pass through, not a verdict to reach. gate.sh is where
  # warning-vs-error decides an exit code.
  bx biome check --reporter=json --max-diagnostics=none . >"$json" 2>/dev/null || rc=$?

  # shellcheck disable=SC2016  # python source, not a shell expansion
  ROOT="$(pwd)" python3 -c '
import json, os, sys
root = os.environ["ROOT"]
try:
    data = json.load(open(sys.argv[1]))
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(0)
seen = set()
for d in data.get("diagnostics") or []:
    loc  = d.get("location") or {}
    path = loc.get("path")
    # Biome reports `path` as a plain string here, but the SARIF reporter uses
    # an absolute URI; normalise both to repo-relative so fingerprints are
    # stable across machines and checkouts.
    if isinstance(path, dict):
        path = path.get("file") or path.get("path")
    if not path:
        continue
    if os.path.isabs(path):
        if not path.startswith(root + os.sep):
            continue
        path = os.path.relpath(path, root)
    start = loc.get("start") or {}
    line  = start.get("line") or 1
    col   = start.get("column")
    # Biome severity vocabulary -> the fleet vocabulary. "information"/"hint"
    # are notes: real findings, not gate failures.
    sev = {"error": "error", "warning": "warning",
           "information": "note", "hint": "note"}.get(d.get("severity"), "note")
    rule = d.get("category") or "biome"
    fp = f"{rule}:{path}:{line}"
    if fp in seen:
        continue
    seen.add(fp)
    rec = {"tool": "biome", "rule": rule, "level": sev, "path": path,
           "line": line, "message": d.get("message") or "", "fingerprint": fp}
    if col:
        rec["col"] = col
    print(json.dumps(rec, separators=(",", ":")))' "$json"
  # Biome exits non-zero for a broken config or an unparseable file as well as
  # for findings; if it produced no JSON at all, say so rather than report zero.
  if [ "$rc" -ne 0 ] && ! grep -q '"diagnostics"' "$json" 2>/dev/null; then
    printf '{"tool":"biome","rule":"biome-failed","level":"error","path":"biome.json","line":1,"message":"biome exited %d without a report — these findings are incomplete","fingerprint":"biome-failed:biome.json:1"}\n' "$rc"
  fi
  rm -f "$json"
}

tsc_findings() {
  [ -f tsconfig.json ] || return 0
  local out rc=0
  out="$(mktemp)" || return 0
  # Buffered, not piped: a pipeline hides tsc's exit status, and "does not
  # compile" must not read the same as "clean".
  #
  # Always tsc, even where the gate would run the consumer's `typecheck`
  # script: this parser reads tsc's diagnostic format and nothing else. A
  # svelte-check or vue-tsc finding is not in the JSONL, which is a gap, not
  # a claim of clean.
  bx tsc -b --pretty false >"$out" 2>&1 || rc=$?
  python3 -c '
import json, re, sys
pat = re.compile(r"^(?P<path>[^(]+)\((?P<line>\d+),(?P<col>\d+)\): (?P<sev>error|warning) (?P<code>TS\d+): (?P<msg>.*)$")
seen = set()
for raw in open(sys.argv[1]):
    m = pat.match(raw.rstrip("\n"))
    if not m:
        continue
    path, line, col = m["path"], int(m["line"]), int(m["col"])
    code = m["code"]
    fp = f"{code}:{path}:{line}"
    if fp in seen:
        continue
    seen.add(fp)
    print(json.dumps({
        "tool": "tsc", "rule": code,
        "level": "error" if m["sev"] == "error" else "warning",
        "path": path, "line": line, "col": col,
        "message": m["msg"], "fingerprint": fp,
    }, separators=(",", ":")))' "$out"
  rm -f "$out"
}

stream() {
  local files=()
  mapfile -t files < <(tracked_ts)   # mapfile, not $(..): paths may contain spaces
  biome_findings
  tsc_findings
  local css=()
  mapfile -t css < <(tracked_css)
  emit < <(ai_lint "${files[@]+"${files[@]}"}"; ui_lint "${css[@]+"${css[@]}"}"; god_files)
  bash "$HERE/config-check.sh"  --format jsonl --warn-only 2>/dev/null || true
  bash "$HERE/supply-chain.sh" --format jsonl --warn-only 2>/dev/null || true
  bash "$HERE/audit.sh"        --format jsonl --warn-only 2>/dev/null || true
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  stream > "$OUT"
  total=$(grep -c . "$OUT" 2>/dev/null || true)
  errs=$(grep -c '"level":"error"' "$OUT" 2>/dev/null || true)
  echo "findings: ${total:-0} total, ${errs:-0} error(s) -> $OUT" >&2
else
  stream
fi
