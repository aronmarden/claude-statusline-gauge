#!/usr/bin/env bash
# claude-statusline-gauge uninstaller.
# https://github.com/aronmarden/claude-statusline-gauge
#
# Restores exactly what the installer moved aside:
#   settings.json  -> byte-for-byte from settings.json.pre-statusline-gauge if
#                     one exists; otherwise the .statusLine key is removed with
#                     jq and everything else is left alone.
#   statusline.sh  -> restored from its backup, or removed if there was none.
#   CLAUDE.md      -> the pace governor block is lifted out by its delimiters.
#                     Everything else in the file, including edits made after
#                     install, is left byte-for-byte -- so it is stripped in
#                     place rather than restored from the backup.
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
    -h|--help) sed -n '2,17p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) printf 'uninstall: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '  %s\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }
die() { printf '\n  \033[31merror\033[0m %s\n\n' "$*" >&2; exit 1; }

printf '\n  claude-statusline-gauge -- uninstall\n\n'

SETTINGS="$DEST/settings.json"
GOV_BEGIN='<!-- BEGIN claude-statusline-gauge pace governor -->'
GOV_END='<!-- END claude-statusline-gauge pace governor -->'

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

# --- pace governor block in CLAUDE.md ---------------------------------------
# Byte-exact inverse of the installer's append: the block, plus the blank line
# it wrote before BEGIN -- or, when there is no such blank line, plus the
# newline it added to a last line that had none.
strip_governor() {  # $1 = file; stdout = the file without the block
  nl=1; if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then nl=0; fi
  awk -v b="$GOV_BEGIN" -v e="$GOV_END" -v nl="$nl" '
    { line[NR] = $0 }
    END {
      s = 0; f = 0
      for (i = 1; i <= NR; i++) { if (!s && line[i] == b) s = i; if (line[i] == e) f = i }
      n = 0
      if (!s || f < s) {
        for (i = 1; i <= NR; i++) out[++n] = line[i]
        trail = nl
      } else {
        cut = (s > 1 && line[s-1] == "") ? s - 1 : s
        glued = (cut == s && s > 1)
        for (i = 1; i < cut; i++) out[++n] = line[i]
        for (i = f + 1; i <= NR; i++) out[++n] = line[i]
        trail = (f == NR) ? (glued ? 0 : 1) : nl
      }
      for (i = 1; i <= n; i++) {
        if (i == n && !trail) printf "%s", out[i]; else print out[i]
      }
    }' "$1"
}

CLAUDEMD="$DEST/CLAUDE.md"
if [ -f "$CLAUDEMD" ] && grep -qF "$GOV_BEGIN" "$CLAUDEMD" 2>/dev/null; then
  strip_governor "$CLAUDEMD" > "$CLAUDEMD.new" \
    && mv -f "$CLAUDEMD.new" "$CLAUDEMD" \
    || { rm -f "$CLAUDEMD.new"; die "could not edit $CLAUDEMD; left untouched"; }
  # An empty file is what "no CLAUDE.md" looks like, and one the installer
  # created for the block alone should not be left behind as litter.
  if [ -s "$CLAUDEMD" ]; then
    ok "pace governor block removed from CLAUDE.md (the rest is untouched)"
  else
    rm -f "$CLAUDEMD"
    ok "pace governor removed; CLAUDE.md held nothing else, so it is gone"
  fi
fi
rm -f "$CLAUDEMD.pre-statusline-gauge"

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
