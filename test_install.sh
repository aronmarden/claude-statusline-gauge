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
if [ "$FAIL" -gt 0 ]; then echo "INSTALLER: $PASS passed, $FAIL FAILED"; exit 1; fi
echo "INSTALLER: $PASS passed, 0 failed"
