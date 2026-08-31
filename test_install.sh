#!/usr/bin/env bash
# Installer test suite. Runs entirely inside disposable HOME sandboxes under
# $TMPDIR -- it never reads or writes your real ~/.claude.
#
# The one bug worth being paranoid about here is the installer eating somebody's
# settings.json, so most of this is about proving that every other key survives
# a rewrite, that the pristine backup is never overwritten by a re-run, and that
# uninstall puts the original back byte-for-byte.
#
#   bash test_install.sh        # exits non-zero if anything fails
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/statusline-gauge-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
chk() {  # $1 name $2 got $3 want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want=%s\n        got =%s\n' "$1" "$3" "$2"; fi
}

echo "=== A. fresh install, no prior config ==="
A="$ROOT/a"; mkdir -p "$A/.claude"
HOME="$A" bash "$REPO/install.sh" --from "$REPO" >/dev/null 2>&1
chk "statusline.sh installed"    "$([ -x "$A/.claude/statusline.sh" ] && echo yes)" "yes"
chk "collector installed"        "$([ -x "$A/.claude/usage-collector.sh" ] && echo yes)" "yes"
chk "uninstaller installed"      "$([ -x "$A/.claude/uninstall-statusline-gauge.sh" ] && echo yes)" "yes"
chk "statusLine.command set"     "$(jq -r '.statusLine.command' "$A/.claude/settings.json")" "$A/.claude/statusline.sh"
chk "statusLine.type set"        "$(jq -r '.statusLine.type' "$A/.claude/settings.json")" "command"
chk "no spurious backup"         "$(ls "$A/.claude" | grep -c pre-statusline-gauge)" "0"

echo
echo "=== B. install over an existing settings.json and a different status line ==="
C="$ROOT/c"; mkdir -p "$C/.claude"
cat > "$C/.claude/settings.json" <<'JSON'
{
  "model": "opusplan",
  "permissions": { "allow": ["Bash(git status)", "Read(**)"], "deny": ["Bash(rm -rf /)"] },
  "env": { "SOMETHING_IMPORTANT": "keep-me" },
  "hooks": { "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "echo done" } ] } ] },
  "statusLine": { "type": "command", "command": "/opt/somebody-elses/statusline", "refreshInterval": 1000 },
  "includeCoAuthoredBy": false
}
JSON
printf '#!/bin/sh\necho "somebody elses statusline"\n' > "$C/.claude/statusline.sh"
chmod 755 "$C/.claude/statusline.sh"
cp "$C/.claude/settings.json" "$ROOT/settings.orig"
cp "$C/.claude/statusline.sh" "$ROOT/statusline.orig"
HOME="$C" bash "$REPO/install.sh" --from "$REPO" >/dev/null 2>&1
chk "settings backed up"         "$([ -f "$C/.claude/settings.json.pre-statusline-gauge" ] && echo yes)" "yes"
chk "backup byte-identical"      "$(cmp -s "$ROOT/settings.orig" "$C/.claude/settings.json.pre-statusline-gauge" && echo yes)" "yes"
chk "old statusline backed up"   "$(cmp -s "$ROOT/statusline.orig" "$C/.claude/statusline.sh.pre-statusline-gauge" && echo yes)" "yes"
chk "model preserved"            "$(jq -r '.model' "$C/.claude/settings.json")" "opusplan"
chk "env preserved"              "$(jq -r '.env.SOMETHING_IMPORTANT' "$C/.claude/settings.json")" "keep-me"
chk "hooks preserved"            "$(jq -r '.hooks.Stop[0].hooks[0].command' "$C/.claude/settings.json")" "echo done"
chk "refreshInterval preserved"  "$(jq -r '.statusLine.refreshInterval' "$C/.claude/settings.json")" "1000"
chk "command repointed"          "$(jq -r '.statusLine.command' "$C/.claude/settings.json")" "$C/.claude/statusline.sh"
chk "key count unchanged"        "$(jq -r 'keys|length' "$C/.claude/settings.json")" "6"
chk "only statusLine differs" \
  "$(diff <(jq -S 'del(.statusLine)' "$ROOT/settings.orig") <(jq -S 'del(.statusLine)' "$C/.claude/settings.json") >/dev/null && echo yes)" "yes"

echo
echo "=== C. re-running the installer is a no-op ==="
cp "$C/.claude/settings.json" "$ROOT/settings.installed"
for _ in 1 2 3; do HOME="$C" bash "$REPO/install.sh" --from "$REPO" >/dev/null 2>&1; done
chk "settings stable over 4 runs" "$(cmp -s "$ROOT/settings.installed" "$C/.claude/settings.json" && echo yes)" "yes"
chk "pristine backup not clobbered" "$(cmp -s "$ROOT/settings.orig" "$C/.claude/settings.json.pre-statusline-gauge" && echo yes)" "yes"
chk "no backup of a backup"       "$(ls "$C/.claude" | grep -c 'pre-statusline-gauge.pre')" "0"

echo
echo "=== D. uninstall restores the original ==="
HOME="$C" bash "$C/.claude/uninstall-statusline-gauge.sh" >/dev/null 2>&1
chk "settings.json byte-for-byte" "$(cmp -s "$ROOT/settings.orig" "$C/.claude/settings.json" && echo yes)" "yes"
chk "statusline.sh byte-for-byte" "$(cmp -s "$ROOT/statusline.orig" "$C/.claude/statusline.sh" && echo yes)" "yes"
chk "collector removed"           "$([ -e "$C/.claude/usage-collector.sh" ] && echo yes || echo no)" "no"
chk "backups cleaned up"          "$(ls "$C/.claude" | grep -c pre-statusline-gauge)" "0"

echo
echo "=== E. uninstall after a clean install just drops the key ==="
HOME="$A" bash "$A/.claude/uninstall-statusline-gauge.sh" >/dev/null 2>&1
chk "statusLine key removed"      "$(jq -r 'has("statusLine")' "$A/.claude/settings.json")" "false"
chk "settings.json still valid"   "$(jq -e . "$A/.claude/settings.json" >/dev/null && echo yes)" "yes"
chk "statusline.sh removed"       "$([ -e "$A/.claude/statusline.sh" ] && echo yes || echo no)" "no"

echo
echo "=== F. a settings.json that is not valid JSON is never rewritten ==="
E="$ROOT/e"; mkdir -p "$E/.claude"
printf '{"model": "opus", oops not json\n' > "$E/.claude/settings.json"
cp "$E/.claude/settings.json" "$ROOT/broken.orig"
out=$(HOME="$E" bash "$REPO/install.sh" --from "$REPO" 2>&1); rc=$?
chk "installer refuses"           "$rc" "1"
chk "file untouched"              "$(cmp -s "$ROOT/broken.orig" "$E/.claude/settings.json" && echo yes)" "yes"
chk "explains why"                "$(printf '%s' "$out" | grep -c 'not valid JSON')" "1"

echo
echo "=== G. --no-collector installs the zero-dependency core only ==="
F="$ROOT/f"; mkdir -p "$F/.claude"
HOME="$F" bash "$REPO/install.sh" --from "$REPO" --no-collector >/dev/null 2>&1
chk "statusline installed"        "$([ -x "$F/.claude/statusline.sh" ] && echo yes)" "yes"
chk "collector not installed"     "$([ -e "$F/.claude/usage-collector.sh" ] && echo yes || echo no)" "no"

echo
echo "=== H. --with-governor: the pace governor block in CLAUDE.md ==="
GOV_B='<!-- BEGIN claude-statusline-gauge pace governor -->'
GOV_E='<!-- END claude-statusline-gauge pace governor -->'

# H1. no CLAUDE.md at all -- the installer creates one holding just the block.
G="$ROOT/g"; mkdir -p "$G/.claude"
HOME="$G" bash "$REPO/install.sh" --from "$REPO" --with-governor >/dev/null 2>&1
chk "H1 CLAUDE.md created"        "$([ -f "$G/.claude/CLAUDE.md" ] && echo yes)" "yes"
chk "H1 exactly one BEGIN"        "$(grep -cF "$GOV_B" "$G/.claude/CLAUDE.md")" "1"
chk "H1 exactly one END"          "$(grep -cF "$GOV_E" "$G/.claude/CLAUDE.md")" "1"
chk "H1 the do-no-harm rule made it" \
  "$(grep -cF 'never refuses work' "$G/.claude/CLAUDE.md")" "1"

# H2. somebody's real CLAUDE.md. Their bytes must still be the first bytes of
# the file, and the pristine backup must be their file, not ours.
H="$ROOT/h"; mkdir -p "$H/.claude"
printf '# My rules\n\n- always run the tests\n- never push to main\n' > "$H/.claude/CLAUDE.md"
cp "$H/.claude/CLAUDE.md" "$ROOT/claudemd.orig"
orig_bytes=$(wc -c < "$ROOT/claudemd.orig" | tr -d ' ')
HOME="$H" bash "$REPO/install.sh" --from "$REPO" --with-governor >/dev/null 2>&1
chk "H2 user content leads, byte-for-byte" \
  "$(head -c "$orig_bytes" "$H/.claude/CLAUDE.md" | cmp -s - "$ROOT/claudemd.orig" && echo yes)" "yes"
chk "H2 backup is their file"     "$(cmp -s "$ROOT/claudemd.orig" "$H/.claude/CLAUDE.md.pre-statusline-gauge" && echo yes)" "yes"
chk "H2 one block appended"       "$(grep -cF "$GOV_B" "$H/.claude/CLAUDE.md")" "1"

# H3. re-running replaces the block instead of stacking a second copy -- two
# copies would be two sets of rules for Claude to read.
cp "$H/.claude/CLAUDE.md" "$ROOT/claudemd.installed"
for _ in 1 2 3; do HOME="$H" bash "$REPO/install.sh" --from "$REPO" --with-governor >/dev/null 2>&1; done
chk "H3 one BEGIN after 4 runs"   "$(grep -cF "$GOV_B" "$H/.claude/CLAUDE.md")" "1"
chk "H3 one END after 4 runs"     "$(grep -cF "$GOV_E" "$H/.claude/CLAUDE.md")" "1"
chk "H3 file byte-stable"         "$(cmp -s "$ROOT/claudemd.installed" "$H/.claude/CLAUDE.md" && echo yes)" "yes"

# H4. uninstall gives their file back exactly, separator blank line included.
HOME="$H" bash "$H/.claude/uninstall-statusline-gauge.sh" >/dev/null 2>&1
chk "H4 CLAUDE.md byte-for-byte"  "$(cmp -s "$ROOT/claudemd.orig" "$H/.claude/CLAUDE.md" && echo yes)" "yes"
chk "H4 backup cleaned up"        "$([ -e "$H/.claude/CLAUDE.md.pre-statusline-gauge" ] && echo yes || echo no)" "no"

# H5. the realistic case: they kept editing the file after install, on both
# sides of the block. Restoring the backup would silently eat that, so the
# uninstaller strips in place instead.
I="$ROOT/i"; mkdir -p "$I/.claude"
printf '# Rules\n\n- one\n' > "$I/.claude/CLAUDE.md"
cp "$I/.claude/CLAUDE.md" "$ROOT/i.orig"
HOME="$I" bash "$REPO/install.sh" --from "$REPO" --with-governor >/dev/null 2>&1
{ printf '# Added on top\n\n'; cat "$I/.claude/CLAUDE.md"; printf '\n## Added below\n\n- two\n'; } > "$ROOT/i.edited"
cp "$ROOT/i.edited" "$I/.claude/CLAUDE.md"
{ printf '# Added on top\n\n'; cat "$ROOT/i.orig"; printf '\n## Added below\n\n- two\n'; } > "$ROOT/i.expected"
HOME="$I" bash "$I/.claude/uninstall-statusline-gauge.sh" >/dev/null 2>&1
chk "H5 edits on both sides survive" "$(cmp -s "$ROOT/i.expected" "$I/.claude/CLAUDE.md" && echo yes)" "yes"

# H6. a CLAUDE.md with no trailing newline. The block cannot be glued onto
# their last line, and the newline that makes room for it must not survive
# the uninstall.
J="$ROOT/j"; mkdir -p "$J/.claude"
printf '# No trailing newline here' > "$J/.claude/CLAUDE.md"
cp "$J/.claude/CLAUDE.md" "$ROOT/j.orig"
HOME="$J" bash "$REPO/install.sh" --from "$REPO" --with-governor >/dev/null 2>&1
chk "H6 BEGIN starts its own line" "$(sed -n '2p' "$J/.claude/CLAUDE.md")" "$GOV_B"
HOME="$J" bash "$J/.claude/uninstall-statusline-gauge.sh" >/dev/null 2>&1
chk "H6 unterminated file byte-for-byte" "$(cmp -s "$ROOT/j.orig" "$J/.claude/CLAUDE.md" && echo yes)" "yes"

# H7. a CLAUDE.md the installer created holding nothing else goes away again.
HOME="$G" bash "$G/.claude/uninstall-statusline-gauge.sh" >/dev/null 2>&1
chk "H7 created CLAUDE.md removed" "$([ -e "$G/.claude/CLAUDE.md" ] && echo yes || echo no)" "no"

# H8. opt-in means opt-in: without the flag CLAUDE.md is not read or written.
K="$ROOT/k"; mkdir -p "$K/.claude"
printf '# Mine\n' > "$K/.claude/CLAUDE.md"
cp "$K/.claude/CLAUDE.md" "$ROOT/k.orig"
HOME="$K" bash "$REPO/install.sh" --from "$REPO" >/dev/null 2>&1
chk "H8 no flag, CLAUDE.md untouched" "$(cmp -s "$ROOT/k.orig" "$K/.claude/CLAUDE.md" && echo yes)" "yes"
chk "H8 no flag, no backup taken"     "$([ -e "$K/.claude/CLAUDE.md.pre-statusline-gauge" ] && echo yes || echo no)" "no"

# --- the block's own reader, run exactly as it is written in the file. A block
# whose jq does not parse is worse than no block: it would be read as rules and
# then silently produce nothing to apply them to.
GOVJQ="$(sed -n '/^```sh$/,/^```$/p' "$REPO/pace-governor.md" | sed '1d;$d')"
L="$ROOT/l"; mkdir -p "$L/.claude"
gov_run() {  # $1 = .pace-trend.json contents
  printf '%s' "$1" > "$L/.claude/.pace-trend.json"
  HOME="$L" bash -c "$GOVJQ" 2>/dev/null
}
R7=$(( $(date +%s) + 302400 ))   # 3.5 days out, so the 7d window is half gone

# H9. the collector is present: lands_at is used as-is, and the age is derived
# from resets_at minus hours_to_reset, which is the only clock the file has.
out=$(gov_run "{\"gauge\":{\"seven_day\":{\"median\":50,\"hours_to_reset\":84,\"resets_at\":$R7,\"lands_at\":92,\"burn_ratio\":1.1},\"five_hour\":{},\"fable\":{}}}")
chk "H9 worst is the 7d projection" "$(printf '%s' "$out" | jq -r '.worst')" "92"
chk "H9 age reads fresh"            "$(printf '%s' "$out" | jq -r '.age_s | if . >= 0 and . < 60 then "fresh" else "stale" end')" "fresh"

# H10. no collector: no lands_at anywhere, so the projection falls back to
# used% over the elapsed fraction -- half the window gone at 50% used lands 100.
out=$(gov_run "{\"gauge\":{\"seven_day\":{\"median\":50,\"hours_to_reset\":84,\"resets_at\":$R7},\"five_hour\":{},\"fable\":{}}}")
chk "H10 degraded projection"       "$(printf '%s' "$out" | jq -r '.seven_day.lands')" "100"
chk "H10 ratio stays unknown"       "$(printf '%s' "$out" | jq -r '.seven_day.ratio')" "null"

# H11. nothing known at all reads null, never 0 -- "unknown" and "fine" must
# not render the same.
out=$(gov_run '{"gauge":{"seven_day":{},"five_hour":{},"fable":{}}}')
chk "H11 unknown is null, not zero" "$(printf '%s' "$out" | jq -r '[.age_s, .worst] | map(tostring) | join(",")')" "null,null"

# H13. both windows projecting: the TIGHTER one has to govern. 5h is a burst
# limit and can be the one about to bite while 7d still reads comfortable.
R5=$(( $(date +%s) + 7200 ))
out=$(gov_run "{\"gauge\":{\"seven_day\":{\"median\":40,\"hours_to_reset\":84,\"resets_at\":$R7,\"lands_at\":60,\"burn_ratio\":0.7},\"five_hour\":{\"median\":70,\"hours_to_reset\":2,\"resets_at\":$R5,\"lands_at\":120,\"burn_ratio\":1.8},\"fable\":{}}}")
chk "H13 the tighter window governs"   "$(printf '%s' "$out" | jq -r '.worst')" "120"
chk "H13 the looser one still reported" "$(printf '%s' "$out" | jq -r '.seven_day.lands')" "60"

# H12. a stale file is not a quiet one: the derived age has to show the gap.
out=$(gov_run "{\"gauge\":{\"seven_day\":{\"median\":90,\"hours_to_reset\":84,\"resets_at\":$(( R7 - 7200 )),\"lands_at\":140},\"five_hour\":{},\"fable\":{}}}")
chk "H12 two-hour-old file reads stale" \
  "$(printf '%s' "$out" | jq -r '.age_s | if . > 900 then "stale" else "fresh" end')" "stale"

echo
if [ "$FAIL" -gt 0 ]; then echo "INSTALLER: $PASS passed, $FAIL FAILED"; exit 1; fi
echo "INSTALLER: $PASS passed, 0 failed"
