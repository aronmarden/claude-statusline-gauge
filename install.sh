#!/usr/bin/env bash
# claude-statusline-gauge installer.
# https://github.com/aronmarden/claude-statusline-gauge
#
#   curl -fsSL https://raw.githubusercontent.com/aronmarden/claude-statusline-gauge/main/install.sh | bash
#
# What it touches, and nothing else:
#   ~/.claude/statusline.sh        installed (existing one backed up first)
#   ~/.claude/usage-collector.sh   installed (optional; --no-collector skips it)
#   ~/.claude/uninstall-statusline-gauge.sh
#   ~/.claude/settings.json        ONE key added via jq: .statusLine
#
# Your settings.json is backed up before it is touched, read with jq, rewritten
# with jq, and every other key in it is carried through untouched. If it is not
# valid JSON the installer stops rather than guessing.
#
# Options:
#   --no-collector    skip the optional usage collector (bars/pace only)
#   --dir <path>      install somewhere other than ~/.claude
#   --from <path>     install from a local checkout instead of downloading
set -eu

REPO_RAW="${CLAUDE_STATUSLINE_REPO_RAW:-https://raw.githubusercontent.com/aronmarden/claude-statusline-gauge/main}"
DEST="${HOME}/.claude"
FROM=""
WITH_COLLECTOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-collector) WITH_COLLECTOR=0; shift ;;
    --dir)   DEST="${2:?--dir needs a path}"; shift 2 ;;
    --from)  FROM="${2:?--from needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) printf 'install: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mnote\033[0m  %s\n' "$*"; }
die()  { printf '\n  \033[31merror\033[0m %s\n\n' "$*" >&2; exit 1; }

printf '\n  claude-statusline-gauge\n\n'

# --- 1. dependencies --------------------------------------------------------
command -v jq >/dev/null 2>&1 || die "jq is required.
        macOS:  brew install jq
        Debian: sudo apt install jq
        Fedora: sudo dnf install jq"

jq_ver=$(jq --version 2>/dev/null | sed 's/^jq-//')
case "$jq_ver" in
  1.[0-5]*) die "jq $jq_ver is too old; 1.6 or newer is required." ;;
esac
ok "jq $jq_ver"

# The status line itself is run by Claude Code with whatever bash is on PATH.
# Everything here is written for bash 3.2, which is what macOS still ships, so
# there is nothing to install -- this only reports what will run it.
ok "bash ${BASH_VERSION%%(*} (3.2+ is enough; macOS's stock bash is fine)"

for tool in find grep date sed awk; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but was not found on PATH."
done

# --- 2. fetch ---------------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/statusline-gauge.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fetch() {  # $1 = filename
  if [ -n "$FROM" ]; then
    [ -f "$FROM/$1" ] || die "$FROM/$1 not found."
    cp "$FROM/$1" "$TMP/$1"
  else
    curl -fsSL "$REPO_RAW/$1" -o "$TMP/$1" \
      || die "could not download $1 from $REPO_RAW"
  fi
  # A truncated download or an HTML error page must never be chmod +x'd into
  # a path Claude Code will execute on every keystroke.
  [ -s "$TMP/$1" ] || die "$1 downloaded empty."
  head -1 "$TMP/$1" | grep -q '^#!' || die "$1 does not look like a shell script."
  bash -n "$TMP/$1" 2>/dev/null || die "$1 failed a syntax check; refusing to install it."
}

fetch statusline.sh
[ "$WITH_COLLECTOR" -eq 1 ] && fetch usage-collector.sh
fetch uninstall.sh
ok "downloaded and syntax-checked"

# --- 3. back up whatever is already there -----------------------------------
mkdir -p "$DEST"
BACKUPS=""
# One pristine backup, taken the first time and never overwritten: it is the
# state to roll back TO, and a second install must not clobber it with the
# state this installer itself produced.
keep_original() {  # $1 = path
  [ -e "$1" ] || return 0
  if [ -e "$1.pre-statusline-gauge" ]; then
    say "existing backup kept: $1.pre-statusline-gauge"
  else
    cp -p "$1" "$1.pre-statusline-gauge"
    BACKUPS="$BACKUPS
    $1.pre-statusline-gauge"
  fi
}

SETTINGS="$DEST/settings.json"
keep_original "$DEST/statusline.sh"
keep_original "$SETTINGS"

# --- 4. install the scripts -------------------------------------------------
install_script() {  # $1 = src name, $2 = dest name
  cp "$TMP/$1" "$DEST/$2.new"
  chmod 755 "$DEST/$2.new"
  mv -f "$DEST/$2.new" "$DEST/$2"
}
install_script statusline.sh statusline.sh
install_script uninstall.sh uninstall-statusline-gauge.sh
ok "$DEST/statusline.sh"
if [ "$WITH_COLLECTOR" -eq 1 ]; then
  install_script usage-collector.sh usage-collector.sh
  ok "$DEST/usage-collector.sh"
fi

# --- 5. patch settings.json -------------------------------------------------
# The whole file is read by jq and written back by jq: one key is set, every
# other key -- permissions, hooks, env, model, whatever you have -- comes
# through byte-identical. An existing .statusLine object keeps any extra fields
# it had (refreshInterval and friends); only type and command are set.
if [ -f "$SETTINGS" ]; then
  jq -e . "$SETTINGS" >/dev/null 2>&1 \
    || die "$SETTINGS is not valid JSON. Fix it (or move it aside) and re-run;
        this installer will not rewrite a file it cannot parse."
else
  printf '{}\n' > "$SETTINGS"
fi

before_keys=$(jq -r 'keys | length' "$SETTINGS")
jq --arg cmd "$DEST/statusline.sh" \
   '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})' \
   "$SETTINGS" > "$SETTINGS.new" || die "failed to rewrite $SETTINGS (original untouched)"
jq -e . "$SETTINGS.new" >/dev/null 2>&1 || die "produced invalid JSON; original untouched"

after_keys=$(jq -r 'keys | length' "$SETTINGS.new")
# Setting one key can only ever add one. Anything else means jq did something
# we did not ask for, and the safe move is to keep the file we have.
if [ "$after_keys" -lt "$before_keys" ]; then
  rm -f "$SETTINGS.new"
  die "settings.json would have lost keys ($before_keys -> $after_keys); original untouched"
fi
mv -f "$SETTINGS.new" "$SETTINGS"
ok "settings.json updated ($after_keys top-level keys preserved)"

# --- 6. first collection ----------------------------------------------------
if [ "$WITH_COLLECTOR" -eq 1 ]; then
  if [ -d "$HOME/.claude/projects" ]; then
    say "backfilling usage history in the background (a large transcript"
    say "history can take ~15s; the gauges fill in as it lands)"
    ( "$DEST/usage-collector.sh" >/dev/null 2>&1 & ) >/dev/null 2>&1
  else
    warn "no transcripts at ~/.claude/projects yet -- the rate figures will"
    warn "appear once Claude Code has written some"
  fi
fi

# --- 7. what happened -------------------------------------------------------
printf '\n  Backups\n'
if [ -n "$BACKUPS" ]; then
  printf '%s\n' "$BACKUPS"
else
  say "nothing to back up (clean install)"
fi

printf '\n  Uninstall\n    bash %s\n' "$DEST/uninstall-statusline-gauge.sh"
printf '\n  Restart Claude Code, or run /statusline, to pick it up.\n\n'
