#!/usr/bin/env bash
# claude-statusline-gauge uninstaller.
# https://github.com/aronmarden/claude-statusline-gauge
#
# Restores exactly what the installer moved aside:
#   settings.json  -> byte-for-byte from settings.json.pre-statusline-gauge if
#                     one exists; otherwise the .statusLine key is removed with
#                     jq and everything else is left alone.
#   statusline.sh  -> restored from its backup, or removed if there was none.
#
# Options:
#   --dir <path>   uninstall from somewhere other than ~/.claude
#   --keep-usage   leave the collected usage data in place
set -eu

DEST="${HOME}/.claude"
KEEP_USAGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DEST="${2:?--dir needs a path}"; shift 2 ;;
    --keep-usage) KEEP_USAGE=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) printf 'uninstall: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '  %s\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }
die() { printf '\n  \033[31merror\033[0m %s\n\n' "$*" >&2; exit 1; }

printf '\n  claude-statusline-gauge -- uninstall\n\n'

SETTINGS="$DEST/settings.json"

# --- settings.json ----------------------------------------------------------
if [ -f "$SETTINGS.pre-statusline-gauge" ]; then
  cp -p "$SETTINGS.pre-statusline-gauge" "$SETTINGS"
  rm -f "$SETTINGS.pre-statusline-gauge"
  ok "settings.json restored from backup"
elif [ -f "$SETTINGS" ]; then
  command -v jq >/dev/null 2>&1 || die "jq is needed to edit settings.json cleanly."
  jq 'del(.statusLine)' "$SETTINGS" > "$SETTINGS.new" \
    && jq -e . "$SETTINGS.new" >/dev/null 2>&1 \
    && mv -f "$SETTINGS.new" "$SETTINGS" \
    || { rm -f "$SETTINGS.new"; die "could not edit $SETTINGS; left untouched"; }
  ok "statusLine removed from settings.json (no backup existed to restore)"
else
  say "no settings.json found"
fi

# --- the scripts ------------------------------------------------------------
if [ -f "$DEST/statusline.sh.pre-statusline-gauge" ]; then
  mv -f "$DEST/statusline.sh.pre-statusline-gauge" "$DEST/statusline.sh"
  ok "previous statusline.sh restored"
else
  rm -f "$DEST/statusline.sh"
  ok "statusline.sh removed"
fi
rm -f "$DEST/usage-collector.sh"
ok "usage-collector.sh removed"

# --- collected data ---------------------------------------------------------
USAGE_DIR="${CLAUDE_STATUSLINE_USAGE_DIR:-$DEST/usage}"
if [ "$KEEP_USAGE" -eq 1 ]; then
  say "usage data kept at $USAGE_DIR"
else
  rm -rf "$USAGE_DIR"
  rm -f "$DEST/.pace-trend.json" "$DEST/.plan-usage.json"
  ok "collected usage data removed"
fi

printf '\n  Done. Restart Claude Code.\n\n'
# Safe last: unlinking a running script does not invalidate the descriptor bash
# is already reading from.
rm -f "$DEST/uninstall-statusline-gauge.sh"
