#!/usr/bin/env bash
# claude-statusline-gauge -- optional usage collector.
# https://github.com/aronmarden/claude-statusline-gauge
#
# Turns Claude Code's own transcripts into the two files statusline.sh needs
# for the RATE half of each gauge (the burn ratio, the "lands at" projection,
# and the whole premium-model gauge):
#
#   $USAGE_DIR/usage-hourly.jsonl   {hour, family, model, *_tokens, messages}
#   $USAGE_DIR/share.json           premium-family share of the trailing 7 days
#                                   (or a null premium block, when you do not
#                                   run a premium family at all)
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

# --- the premium-family gauge ------------------------------------------------
# The third gauge rations ONE model family: the one that costs materially more
# per token than the rest of your mix, so that moving mechanical work off it
# actually buys back window. WHICH family that is depends on what you run, so
# nothing here is hardcoded to a model name.
#
#   CLAUDE_STATUSLINE_PREMIUM_FAMILY  extended regex, matched case-insensitively
#                                     against the model id. Empty (the default)
#                                     means auto-detect -- see PREMIUM_COST_TABLE
#                                     in the share block at the bottom.
#   CLAUDE_STATUSLINE_PREMIUM_WEIGHT  what one of its tokens costs in
#                                     opus-equivalents. Empty means: the cost
#                                     table's figure for the resolved family,
#                                     else 1. Opus is 1 by definition -- it is
#                                     the unit.
#   CLAUDE_STATUSLINE_PREMIUM_LABEL   what the gauge is called on screen. Empty
#                                     means the family name.
#   CLAUDE_STATUSLINE_PREMIUM_SHARE   what fraction of the 7-day window you are
#                                     willing to let that family take. 0.5 =
#                                     half. This is YOUR policy, not a limit the
#                                     API enforces -- see the README.
#
# Changing FAMILY changes how rows are CLASSIFIED, and rows already written keep
# their old family, so follow a change with `usage-collector.sh --full`.
PREMIUM_SHARE="${CLAUDE_STATUSLINE_PREMIUM_SHARE:-0.5}"
PREMIUM_FAMILY="${CLAUDE_STATUSLINE_PREMIUM_FAMILY:-}"
PREMIUM_WEIGHT="${CLAUDE_STATUSLINE_PREMIUM_WEIGHT:-}"
PREMIUM_LABEL="${CLAUDE_STATUSLINE_PREMIUM_LABEL:-}"

# The family NAME rows are filed under when PREMIUM_FAMILY is an explicit
# regex. A bare word is its own name; anything with regex metacharacters in it
# gets a stable placeholder, because "fable|opus" is not a family name.
if [ -n "$PREMIUM_FAMILY" ]; then
  PREMIUM_NAME="$PREMIUM_LABEL"
  if [ -z "$PREMIUM_NAME" ]; then
    case "$PREMIUM_FAMILY" in
      *[!A-Za-z0-9._-]*) PREMIUM_NAME="premium" ;;
      *)                 PREMIUM_NAME="$PREMIUM_FAMILY" ;;
    esac
  fi
else
  PREMIUM_NAME=""
fi

HOURLY="$USAGE_DIR/usage-hourly.jsonl"
SHARE="$USAGE_DIR/share.json"
LOCK="$USAGE_DIR/.lock"

MODE=""
for arg in "$@"; do
  case "$arg" in
    --if-stale|--full|--status) MODE="$arg" ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
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
    printf 'share.json    %s\n' "$(jq -c '.premium_share_of_7d // .fable_share_of_7d' "$SHARE" 2>/dev/null)"
  else
    printf 'share.json    not written yet\n'
  fi
  if [ -n "$PREMIUM_FAMILY" ]; then
    printf 'premium       /%s/ (configured), weight %s, filed as "%s"\n' \
      "$PREMIUM_FAMILY" "${PREMIUM_WEIGHT:-from the cost table, else 1}" "$PREMIUM_NAME"
  elif [ -f "$SHARE" ]; then
    printf 'premium       %s\n' "$(jq -r '
      if .premium_share_of_7d == null and (has("premium_share_of_7d") | not)
      then "old-schema share.json -- rerun the collector to resolve it"
      elif .premium_share_of_7d == null
      then "none auto-detected: nothing in your history costs more than the baseline, so the gauge is not rendered"
      else "auto-detected \(.premium_share_of_7d.family) at weight \(.premium_share_of_7d.weight)"
      end' "$SHARE" 2>/dev/null)"
  else
    printf 'premium       not resolved yet -- run the collector once\n'
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
  | jq -Rnc --arg prem_re "$PREMIUM_FAMILY" --arg prem_name "$PREMIUM_NAME" '
  # An explicitly configured premium family wins the classification outright,
  # so its rows are filed under one name no matter which ids it spans. The
  # ladder below it is only the built-in fallback, and it exists so that
  # auto-detection has named families to choose between.
  def fam:
    if   . == null      then "other"
    elif $prem_re != "" and test($prem_re; "i") then $prem_name
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

# --- premium-family share of the trailing 7 days ----------------------------
# This block resolves WHICH family is the premium one and writes the answer --
# family, weight, label -- into share.json alongside the number. statusline.sh
# reads all three from here rather than re-deriving them, because a collector
# that counted one set of rows while the gauge weighted another is a silently
# wrong number, not a visible bug.
#
# PREMIUM_COST_TABLE: families that cost MORE per token than the
# opus-equivalent baseline, priciest first. Auto-detection only ever picks
# from this list, and only picks a family that is actually in your history.
#
# WHY WEIGHT > 1 IS THE ENTRY CRITERION, and what the default therefore does:
# this gauge is a cost claim -- "that fraction of my window went somewhere
# dearer than it had to". For a family weighted 1 the arithmetic degenerates
# into a plain token-mix ratio, and the 0.5 target becomes a policy nobody
# set. So a machine that has never run a family from this table gets NO
# premium block, statusline.sh hides the gauge, and you see two gauges rather
# than a confident zero. Someone who wants the mix signal for a weight-1
# family (opus against sonnet, say) opts in with CLAUDE_STATUSLINE_PREMIUM_*
# and is then stating the policy themselves.
#
# APPLICABLE vs ZERO. Selection reads the WHOLE retained file (RETAIN_DAYS,
# default 9); the share is measured over the trailing 7 days. Retention is
# deliberately longer than the window, so "used it last week, none this
# window" selects the family and reports a real, measured 0.00% -- while
# "never appears at all" selects nothing and the gauge does not render.
# An explicitly configured family is always applicable: naming it IS the
# statement that the policy applies to you, so its zero is a measurement too.
jq -sc --argjson allowance "$PREMIUM_SHARE" \
       --arg prem_re "$PREMIUM_FAMILY" --arg prem_name "$PREMIUM_NAME" \
       --arg prem_weight "$PREMIUM_WEIGHT" --arg prem_label "$PREMIUM_LABEL" \
       --arg since "$(jq -nr '(now - 604800) | gmtime | strftime("%Y-%m-%dT%H")')" '
  [["fable", 2]] as $cost_table
  | . as $rows
  | (if $prem_re != "" then $prem_name
     else (first($cost_table[]
                 | .[0] as $f | select(any($rows[]; .family == $f)) | $f) // null)
     end) as $family
  | (if $family == null then null
     elif $prem_weight != "" then ($prem_weight | tonumber)
     else ((first($cost_table[] | select(.[0] == $family) | .[1])) // 1)
     end) as $weight
  | (if $prem_label != "" then $prem_label else ($family // "") end) as $label
  | def oe: (.input_tokens + .output_tokens
             + .cache_creation_input_tokens + .cache_read_input_tokens)
            * (if .family == $family then $weight else 1 end);
    (if $family == null then {premium_share_of_7d: null}
     else ($rows | map(select(.hour >= $since))) as $w
       | ($w | map(oe) | add // 0) as $total
       | ($w | map(select(.family == $family) | oe) | add // 0) as $prem
       | {premium_share_of_7d: {
            family: $family,
            label: $label,
            weight: $weight,
            share: (if $total > 0 then (($prem / $total) * 10000 | round) / 10000 else 0 end),
            allowance: $allowance,
            premium_opus_equivalent_tokens: $prem,
            total_opus_equivalent_tokens: $total }}
     end)
  + {generated_at: (now | todate),
     generated_at_epoch: (now | floor)}
' "$HOURLY" > "$TMP/share.new" 2>/dev/null
[ -s "$TMP/share.new" ] && mv -f "$TMP/share.new" "$SHARE"

exit 0
