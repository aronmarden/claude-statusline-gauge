#!/usr/bin/env bash
# claude-statusline-gauge -- optional usage collector.
# https://github.com/aronmarden/claude-statusline-gauge
#
# Turns Claude Code's own transcripts into the two files statusline.sh needs
# for the RATE half of each gauge (the burn ratio, the "lands at" projection,
# and the whole premium-model gauge):
#
#   $USAGE_DIR/usage-hourly.jsonl   {hour, family, model, *_tokens, messages}
#   $USAGE_DIR/share.json           premium-model share of the trailing 7 days
#
# It reads ~/.claude/projects/**/*.jsonl and nothing else. Nothing leaves the
# machine. It is self-throttling and self-locking, which is what makes it safe
# for statusline.sh to fire detached on every refresh.
#
#   usage-collector.sh              collect now
#   usage-collector.sh --if-stale   collect only if the aggregate is older than
#                                   CLAUDE_STATUSLINE_THROTTLE seconds (300)
#   usage-collector.sh --full       rebuild the whole retention window
#   usage-collector.sh --status     print where things stand and exit
#
# Requires: bash 3.2+, jq 1.6+, find, grep.
set -u

USAGE_DIR="${CLAUDE_STATUSLINE_USAGE_DIR:-$HOME/.claude/usage}"
PROJECTS_DIR="${CLAUDE_STATUSLINE_PROJECTS_DIR:-$HOME/.claude/projects}"
THROTTLE="${CLAUDE_STATUSLINE_THROTTLE:-300}"       # seconds between real runs
RETAIN_DAYS="${CLAUDE_STATUSLINE_RETAIN_DAYS:-9}"   # >7 so a 7d window never runs short
# What fraction of the 7-day window you are willing to let the premium model
# (fable, weighted 2x) take. 0.5 = half. This is YOUR policy, not a limit the
# API enforces -- see the README.
PREMIUM_SHARE="${CLAUDE_STATUSLINE_PREMIUM_SHARE:-0.5}"

HOURLY="$USAGE_DIR/usage-hourly.jsonl"
SHARE="$USAGE_DIR/share.json"
LOCK="$USAGE_DIR/.lock"

MODE=""
for arg in "$@"; do
  case "$arg" in
    --if-stale|--full|--status) MODE="$arg" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) printf 'usage-collector: unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "usage-collector: jq not found" >&2; exit 1; }
mkdir -p "$USAGE_DIR" || exit 1

# stat(1) is not portable. GNU accepts -c, BSD/macOS does not (and GNU's -f
# means something else entirely, so -c is the safe thing to probe for).
if stat -c '%s' /dev/null >/dev/null 2>&1; then
  mtime_of() { stat -c '%Y' "$1" 2>/dev/null; }
else
  mtime_of() { stat -f '%m' "$1" 2>/dev/null; }
fi

now=$(date +%s)

if [ "$MODE" = "--status" ]; then
  printf 'usage dir     %s\n' "$USAGE_DIR"
  printf 'transcripts   %s%s\n' "$PROJECTS_DIR" "$([ -d "$PROJECTS_DIR" ] || echo '  (MISSING)')"
  if [ -f "$HOURLY" ]; then
    printf 'usage-hourly  %s rows, last written %ss ago\n' \
      "$(wc -l < "$HOURLY" | tr -d ' ')" "$(( now - $(mtime_of "$HOURLY") ))"
  else
    printf 'usage-hourly  not written yet\n'
  fi
  if [ -f "$SHARE" ]; then
    printf 'share.json    %s\n' "$(jq -c '.fable_share_of_7d' "$SHARE" 2>/dev/null)"
  else
    printf 'share.json    not written yet\n'
  fi
  exit 0
fi

# Throttle BEFORE taking the lock, so the common "nothing is due" path costs one
# stat and nothing else. statusline.sh fires this on every refresh.
if [ "$MODE" = "--if-stale" ] && [ -f "$HOURLY" ]; then
  [ $(( now - $(mtime_of "$HOURLY") )) -lt "$THROTTLE" ] && exit 0
fi

[ -d "$PROJECTS_DIR" ] || { echo "usage-collector: no transcripts at $PROJECTS_DIR" >&2; exit 1; }

# mkdir is the atomic primitive every POSIX shell has. A lock left behind by a
# killed run would otherwise wedge the collector permanently, so anything older
# than 30 minutes is treated as abandoned.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $(( now - $(mtime_of "$LOCK" 2>/dev/null || echo "$now") )) -gt 1800 ]; then
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
TMP="$USAGE_DIR/.tmp.$$"
mkdir -p "$TMP" || { rmdir "$LOCK"; exit 1; }
trap 'rm -rf "$TMP" "$LOCK"' EXIT INT TERM

# --- how far back do we need to look? ---------------------------------------
# A transcript file's last write is at or after its last record's timestamp, so
# an hour bucket at or after time T can only have come from a file modified at
# or after T. That is the whole trick: rescan the files touched since T, throw
# away every stored row at or after T, and the merge is exact -- no per-file
# cursors, no state to corrupt. T is 3 hours back at minimum, further if the
# aggregate has been sitting unwritten (laptop asleep, collector disabled), and
# the full retention window on a first run or --full.
lookback_min=$(( 3 * 60 ))
if [ ! -f "$HOURLY" ] || [ "$MODE" = "--full" ]; then
  lookback_min=$(( RETAIN_DAYS * 24 * 60 ))
else
  gap_min=$(( (now - $(mtime_of "$HOURLY")) / 60 + 120 ))
  [ "$gap_min" -gt "$lookback_min" ] && lookback_min=$gap_min
  [ "$lookback_min" -gt $(( RETAIN_DAYS * 24 * 60 )) ] && lookback_min=$(( RETAIN_DAYS * 24 * 60 ))
fi
cutoff_hour=$(jq -nr --argjson m "$lookback_min" '(now - $m * 60) | gmtime | strftime("%Y-%m-%dT%H")')
retain_hour=$(jq -nr --argjson d "$RETAIN_DAYS" '(now - $d * 86400) | gmtime | strftime("%Y-%m-%dT%H")')
# +2h of slack on the file selection so the hour-granular cutoff above can never
# land past the minute-granular file filter.
find_min=$(( lookback_min + 120 ))

# --- aggregate the transcripts in scope -------------------------------------
# One API request writes several assistant records (one per content block), each
# carrying the SAME usage object -- counting them all double-counts every single
# request, so deduping on requestId is mandatory, not an optimisation.
# Two layers of tolerance, because a transcript that is being appended to RIGHT
# NOW is the normal case, not the exception: grep narrows the stream to lines
# that could possibly matter, and `jq -R` + `fromjson?` parses each line
# independently so one truncated or garbled line is skipped instead of aborting
# the whole run and costing us every other file in it.
find "$PROJECTS_DIR" -type f -name '*.jsonl' -mmin -"$find_min" -print0 2>/dev/null \
  | xargs -0 grep -h -a -E '"type": ?"assistant"' /dev/null 2>/dev/null \
  | jq -Rnc '
  def fam:
    if   . == null      then "other"
    elif test("fable")  then "fable"
    elif test("opus")   then "opus"
    elif test("sonnet") then "sonnet"
    elif test("haiku")  then "haiku"
    else "other" end;
  reduce (inputs | fromjson?) as $l ({seen: {}, agg: {}};
    ($l.message.usage) as $u
    | ($l.message.model) as $m
    | if $l.type == "assistant" and ($u | type) == "object"
         and ($m | type) == "string" and $m != "<synthetic>"
         and ($l.timestamp | type) == "string"
      then (($l.requestId // $l.message.id // $l.uuid) | tostring) as $rid
        | if (.seen[$rid] // false) then .
          else
            .seen[$rid] = true
            | (($l.timestamp)[0:13] + "\u001f" + ($m | fam) + "\u001f" + $m) as $k
            | .agg[$k] = ((.agg[$k] // {i:0, o:0, cc:0, cr:0, n:0})
                | {i:  (.i  + ($u.input_tokens                // 0)),
                   o:  (.o  + ($u.output_tokens               // 0)),
                   cc: (.cc + ($u.cache_creation_input_tokens // 0)),
                   cr: (.cr + ($u.cache_read_input_tokens     // 0)),
                   n:  (.n  + 1)})
          end
      else . end)
  | .agg | to_entries[]
  | (.key | split("\u001f")) as $k
  | {hour: $k[0], family: $k[1], model: $k[2],
     input_tokens: .value.i, output_tokens: .value.o,
     cache_creation_input_tokens: .value.cc,
     cache_read_input_tokens: .value.cr, messages: .value.n}
  ' > "$TMP/fresh" 2>/dev/null || : > "$TMP/fresh"

# A scan that produced nothing while stored rows exist inside the same window is
# far more likely to be a broken jq than a genuinely idle machine, and silently
# replacing real data with nothing is the one unrecoverable failure here. Keep
# what we have and try again next cycle.
if [ ! -s "$TMP/fresh" ] && [ -s "${HOURLY:-/dev/null}" ] && \
   [ -n "$(jq -sr --arg c "$cutoff_hour" 'map(select(.hour >= $c)) | length' "$HOURLY" 2>/dev/null | grep -v '^0$')" ]; then
  exit 0
fi

# --- merge: keep stored rows before the cutoff, take fresh ones after --------
[ -f "$HOURLY" ] || : > "$HOURLY"
jq -sc --arg cutoff "$cutoff_hour" --arg retain "$retain_hour" --slurpfile fresh "$TMP/fresh" '
  (map(select(.hour < $cutoff and .hour >= $retain))) + ($fresh | map(select(.hour >= $retain)))
  | sort_by(.hour, .family, .model)[]
' "$HOURLY" > "$TMP/hourly.new" 2>/dev/null
# An empty merge is only legitimate when the scan itself was empty (retention
# pruned everything). An empty merge after a non-empty scan means the merge
# broke, and keeping yesterday's aggregate beats destroying it.
if [ -s "$TMP/hourly.new" ] || [ ! -s "$TMP/fresh" ]; then
  mv -f "$TMP/hourly.new" "$HOURLY" 2>/dev/null || true
fi

# --- premium-model share of the trailing 7 days -----------------------------
# Opus-equivalent weighting matches statusline.sh: fable counts double,
# everything else counts once.
jq -sc --argjson allowance "$PREMIUM_SHARE" \
       --arg since "$(jq -nr '(now - 604800) | gmtime | strftime("%Y-%m-%dT%H")')" '
  def oe: (.input_tokens + .output_tokens
           + .cache_creation_input_tokens + .cache_read_input_tokens)
          * (if .family == "fable" then 2 else 1 end);
  map(select(.hour >= $since))
  | (map(oe) | add // 0) as $total
  | (map(select(.family == "fable") | oe) | add // 0) as $prem
  | {fable_share_of_7d: {
       share: (if $total > 0 then (($prem / $total) * 10000 | round) / 10000 else 0 end),
       allowance: $allowance,
       fable_opus_equivalent_tokens: $prem,
       total_opus_equivalent_tokens: $total },
     generated_at: (now | todate),
     generated_at_epoch: (now | floor)}
' "$HOURLY" > "$TMP/share.new" 2>/dev/null
[ -s "$TMP/share.new" ] && mv -f "$TMP/share.new" "$SHARE"

exit 0
