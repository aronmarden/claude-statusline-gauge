#!/usr/bin/env bash
# claude-statusline-gauge -- a two-line Claude Code status line with pace gauges.
# https://github.com/aronmarden/claude-statusline-gauge
# Reads the Status JSON payload on stdin and renders a two-line status bar.
# Payload schema verified against Claude Code 2.1.220.

input=$(cat)

# Persist the plan-usage window so the assistant can read it and throttle agent
# dispatch against real capacity instead of guessing. Rendering must never fail
# because of this, hence the guards and the 2>/dev/null.
jq -c '{
  five_hour:  (.rate_limits.five_hour  // null),
  seven_day:  (.rate_limits.seven_day  // null),
  captured_at: (now | todate)
}' <<<"$input" > "$HOME/.claude/.plan-usage.json" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Optional usage source.
#
# The bars, the used%, the pace delta and the time ahead/behind need nothing
# but the payload above and the clock. The burn ratio, the "lands" projection
# and the whole premium-model gauge need real token spend over real time,
# which the payload does not carry -- they come from two files a collector
# maintains:
#
#   $usage_dir/usage-hourly.jsonl   per-hour token aggregates
#   $usage_dir/share.json           premium-family share of the 7d window
#
# usage-collector.sh (shipped alongside this script) produces both from Claude
# Code's own transcripts. Point CLAUDE_STATUSLINE_USAGE_DIR at your own
# producer if you have one. With neither present the rate figures are omitted
# entirely rather than rendered as a permanent "-".
usage_dir="${CLAUDE_STATUSLINE_USAGE_DIR:-$HOME/.claude/usage}"
usage_file="$usage_dir/usage-hourly.jsonl"
share_file="$usage_dir/share.json"
collector="${CLAUDE_STATUSLINE_COLLECTOR:-$HOME/.claude/usage-collector.sh}"

# Keep the aggregate fresh without a scheduler: fire the collector detached on
# every refresh and let IT decide whether anything is due (it self-throttles and
# self-locks, and exits in a few ms when it is not). Skipped entirely when there
# is no transcript directory to read, which is also what keeps the test harness's
# isolated HOME sandboxes free of it.
if [ -x "$collector" ] && [ -d "$HOME/.claude/projects" ]; then
  ( "$collector" --if-stale >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

# The premium family's share of the 7d window. Claude Code's payload has no
# premium rate-limit window (only five_hour/seven_day), so the only source is
# share.json, refreshed by the collector.
#
# WHICH family is premium, what a token of it costs, and what the gauge is
# called are ALL read from here, never re-derived. The collector resolves them
# once (from CLAUDE_STATUSLINE_PREMIUM_* or by auto-detection) and writes the
# answer down; if this script re-derived them it could weight a different set
# of rows than the collector counted, and the two numbers would disagree
# silently. One resolver, one answer, written to the file both sides read.
#
# A null premium block is the collector saying "this install runs no premium
# family" -- not a zero. It renders as NO GAUGE, because a 0.00% bar against a
# policy you are not exercising is an assertion, and a wrong one.
# OLD SCHEMA: a share.json written before this key existed only ever described
# one family, so it is read as exactly that and the gauge keeps working until
# the collector's next run (<=5 min) rewrites the file.
prem=$(jq -c '
  (if   has("premium_share_of_7d") then .premium_share_of_7d
   elif has("fable_share_of_7d")   then
     (.fable_share_of_7d | if . == null then null
      else {family: "fable", label: "fable", weight: 2} + . end)
   else null end) as $p
  | if $p == null or $p.share == null then null
    else {family:    ($p.family // "premium"),
          label:     ($p.label  // ($p.family // "prm") | .[0:6]),
          weight:    ($p.weight // 1),
          share:     $p.share,
          allowance: ($p.allowance // 0.5),
          age:       (now - (.generated_at_epoch // 0))}
    end' "$share_file" 2>/dev/null)
[ -n "$prem" ] || prem=null

# Rolling pace-delta history (last 10 refreshes per window) feeds the trend
# arrow next to each delta number. Stateless jq can't persist across
# invocations on its own, so the last-10 window lives in a small state file
# that this block reads, updates, and rewrites every refresh. Never allowed
# to break rendering, hence the guards.
trend_file="$HOME/.claude/.pace-trend.json"
if [ ! -f "$trend_file" ]; then
  init_tmp="${trend_file}.tmp.$$"
  printf '{"five_hour":[],"seven_day":[],"premium":[],"raw":{"five_hour":[],"seven_day":[]},"gauge":{"seven_day":{}}}' > "$init_tmp" 2>/dev/null && mv -f "$init_tmp" "$trend_file" 2>/dev/null
fi

# Real spend, not a cached percentage: resolve resets_at for BOTH windows
# (live payload, falling back to the persisted value -- same fallback the
# main jq below does) up front, in bash, so the token windows can be bounded
# before tailing usage-hourly.jsonl. This duplicates two small epoch
# computations rather than restructuring the jq pipeline's ordering; they
# can disagree with the main jq for at most one refresh, the moment a
# resets_at first becomes known, and self-correct immediately after.
# (usage_file / share_file are resolved in the config block at the top.)
bash_resets=$(jq -r --slurpfile prev "$trend_file" '
  def epoch:
    if   . == null      then null
    elif type == "number" then (if . > 100000000000 then . / 1000 else . end)
    else (fromdateiso8601? // null) end;
  # INVARIANT: a window’s resets_at must lie within (now, now+window_hours] --
  # anything else is impossible, not merely stale (in the past; or further
  # out than the window can ever be). Validated on EVERY read, live or
  # persisted, because a value that was valid when first written can still
  # age past "now" while sitting untouched in the state file -- exactly
  # what happened live: five_hour.resets_at froze 40.9h in the past while
  # the payload kept sending fresh used_percentage readings around it. A
  # fallback with no validity check is not a fallback, it is a way to keep
  # a wrong value forever -- the same lesson as the allowance bug.
  def valid_resets_at($r; $now; $window_hours):
    if $r == null then null
    elif $r > $now and $r <= ($now + $window_hours * 3600) then $r
    else null end;
  (now) as $now
  | (valid_resets_at($prev[0].gauge.seven_day.resets_at; $now; 168)) as $p7
  | (valid_resets_at($prev[0].gauge.five_hour.resets_at; $now; 5)) as $p5
  | (valid_resets_at((.rate_limits.seven_day.resets_at | epoch); $now; 168)) as $live7
  | (valid_resets_at((.rate_limits.five_hour.resets_at | epoch); $now; 5)) as $live5
  | [ (($live7 // $p7) // ""), (($live5 // $p5) // "") ] | join("|")
' <<<"$input" 2>/dev/null)
# NOT @tsv/IFS=$'\t': bash read collapses consecutive whitespace IFS
# delimiters (space/tab/newline) even when IFS is set to just one of them,
# so an EMPTY field (resets_at genuinely unknown yet) silently shifts every
# field after it left -- caught in testing: cur/rws ended up holding each
# other's values, silently mis-scoping the token window. "|" is not
# whitespace, so read preserves empty fields in every position.
IFS='|' read -r bash_r7 bash_r5 <<<"$bash_resets"

# Bounded tail (never the whole file -- it grows forever): 5000 lines covers
# ~7 days at several times today's row density. One tail, one jq pass, three
# windows: 7d and the premium family (a weighted SHARE of the 7d window, not
# a window of its own) share the same 168h clock and the same trailing-6h
# "recent rate" bucket; 5h gets its own, much shorter, window (see the 5h
# actual_rate comment in the main jq below for why it does NOT reuse the 6h
# bucket -- 6h is longer than the whole window). The still-filling current
# hour is excluded from both by_hour arrays on purpose (see actual_rate).
if { [ -n "$bash_r7" ] || [ -n "$bash_r5" ]; } && [ -f "$usage_file" ]; then
  IFS='|' read -r ws7 ws5 cur rws <<HOURSEOF
$(jq -nr --arg r7 "$bash_r7" --arg r5 "$bash_r5" '
    def h: gmtime | strftime("%Y-%m-%dT%H");
    [ (if $r7 == "" then "" else (($r7 | tonumber) - 604800 | h) end),
      (if $r5 == "" then "" else (($r5 | tonumber) - 18000  | h) end),
      (now | h),
      ((now - 6*3600) | h) ] | join("|")' 2>/dev/null)
HOURSEOF
  usage_agg=$(tail -n 5000 "$usage_file" 2>/dev/null | jq -sc \
      --arg ws7 "${ws7:-}" --arg ws5 "${ws5:-}" --arg cur "${cur:-}" --arg rws "${rws:-}" \
      --argjson prem "$prem" '
      def totrow: (.cache_creation_input_tokens + .cache_read_input_tokens
                   + .input_tokens + .output_tokens);
      # Family and weight come from share.json (see the $prem block above), so
      # the rows weighted here are exactly the rows the collector counted. With
      # no premium family resolved $pf matches nothing and every row weighs 1,
      # which is also the honest reading: nothing here costs more than baseline.
      ($prem.family // "") as $pf
      | ($prem.weight // 1) as $pw
      | def oe: totrow * (if .family == $pf then $pw else 1 end);
      def by_hour($rows): ($rows
          | group_by(.hour)
          | map({hour: .[0].hour, oe: (map(oe) | add)})
          | sort_by(.hour));
      { file_present: true,
        # Fraction of the CURRENT calendar hour that has already elapsed.
        # The still-filling hour is no longer thrown away (work happening
        # right now used to contribute nothing for up to 60 minutes); it is
        # carried separately, with its own weight, and combined in
        # gauge_math -- see the rate branch there for why it cannot spike.
        cur_frac: ((now % 3600) / 3600),
        seven_day: {
          tokens_in_window: (if $ws7 == "" then null
                              else (map(select(.hour >= $ws7)) | map(oe) | add // 0) end),
          by_hour: (if $ws7 == "" then []
                     else by_hour(map(select(.hour < $cur and .hour >= $rws))) end),
          cur_oe: (map(select(.hour == $cur)) | map(oe) | add // 0)
        },
        five_hour: {
          tokens_in_window: (if $ws5 == "" then null
                              else (map(select(.hour >= $ws5)) | map(oe) | add // 0) end)
        },
        premium: {
          tokens_in_window: (if $ws7 == "" or $pf == "" then null
                              else (map(select(.hour >= $ws7 and .family == $pf))
                                    | map(oe) | add // 0) end),
          by_hour: (if $ws7 == "" or $pf == "" then []
                     else by_hour(map(select(.hour < $cur and .hour >= $rws
                                              and .family == $pf))) end),
          cur_oe: (map(select(.hour == $cur and .family == $pf)) | map(oe) | add // 0)
        }
      }
    ' 2>/dev/null)
  [ -n "$usage_agg" ] || usage_agg='{"file_present":true,"cur_frac":0,"seven_day":{"tokens_in_window":0,"by_hour":[],"cur_oe":0},"five_hour":{"tokens_in_window":0},"premium":{"tokens_in_window":null,"by_hour":[],"cur_oe":0}}'
else
  usage_agg='{"file_present":false,"cur_frac":0,"seven_day":{"tokens_in_window":null,"by_hour":[],"cur_oe":0},"five_hour":{"tokens_in_window":null},"premium":{"tokens_in_window":null,"by_hour":[],"cur_oe":0}}'
fi

trend_hist=$(jq -c --slurpfile prev "$trend_file" --argjson prem "$prem" --argjson usage_agg "$usage_agg" '
  def epoch:
    if   . == null      then null
    elif type == "number" then (if . > 100000000000 then . / 1000 else . end)
    else (fromdateiso8601? // null) end;
  # Same invariant, same reason, as the bash pre-step above: a
  # window resets_at must lie within (now, now+window_hours] or it gets
  # thrown away, not kept -- this is what a "fallback" actually needs to
  # mean. Applied here to both the persisted value being read AND the
  # live value being read, before either is allowed into $r7/$r5; the
  # combined result is exactly what gets persisted below, so there is no
  # point where an unvalidated value can slip into the state file.
  def valid_resets_at($r; $now; $window_hours):
    if $r == null then null
    elif $r > $now and $r <= ($now + $window_hours * 3600) then $r
    else null end;
  def median($arr):
    ($arr | length) as $n
    | if $n == 0 then null
      else ($arr | sort) as $s
      | if ($n % 2) == 1 then $s[($n-1)/2]
        else (($s[($n/2)-1] + $s[$n/2]) / 2) end
      end;
  # {value, provisional} from a raw-sample array (newest last), the fix for
  # the flicker: <3 samples shows the latest raw reading (marked so) rather
  # than pretending a median exists; >=3 takes the median of the last 5,
  # which a single wildly-off sample (seen in the wild: 56/44/46/40 within
  # the same few seconds) cannot move.
  def smoothed($arr):
    ($arr | length) as $n
    | if $n == 0 then null
      elif $n < 3 then {value: $arr[-1], provisional: true}
      else {value: median($arr[-5:]), provisional: false}
      end;

  # --- PAYLOAD STABILITY: is the concurrent-process rotation happening right
  # now, or is the payload telling one consistent story?
  #
  # The rotation documented in the ROOT CAUSE comment below is real and
  # recurs, but it is not permanent: it only shows up while several Claude
  # Code processes hold DIFFERENT cached snapshots. When they agree (one
  # session, or every session resynced), used_percentage is the server’s own
  # figure and is strictly better than anything derivable locally -- see the
  # $used_7 comment for why the local derivation cannot be made to track.
  #
  # The test is the SPREAD (max-min) of the last 5 raw samples, because
  # rotation is a spread, not a drift: the live incident spanned 16 points
  # (40/44/46/56) and 4-value rotations cannot hide inside a 3-point band.
  # A genuinely MOVING true value cannot exceed the band either, over this
  # sampling window: refreshes land ~30 s apart (measured from the persisted
  # allowance_history timestamps), so 5 samples span ~1-2 minutes -- at the
  # theoretical maximum burn that is 0.02 pt of a 7d window and 0.7 pt of a
  # 5h one. So spread <= 3 means "not rotating" with ~5x margin on the
  # observed rotation and ~4x on the fastest legitimate movement.
  #
  # <3 samples is NOT stable: that is exactly the case smoothed() already
  # refuses to call non-provisional, and one sample cannot show a spread.
  def stability_spread: 3;
  def payload_stable($arr):
    ($arr | length) as $n
    | if $n < 3 then false
      else ($arr[-5:]) as $w | (($w | max) - ($w | min)) <= stability_spread
      end;

  # --- allowance calibration: opus-equivalent tokens that equal 100% of a
  # window. Persisted, and only ever nudged by a 90/10 blend (never a full
  # overwrite) when a FRESH non-provisional payload reading agrees with what
  # the persisted allowance already predicts to within 3pts -- "a few
  # percent" per brief -- so one lucky or unlucky concurrent-session
  # snapshot can never yank the calibration on its own. First-ever
  # calibration (no persisted allowance) is the one case allowed to set it
  # directly, since there is nothing yet to disagree with. Not used for
  # Not used for the premium family: that is a SHARE of the 7d allowance
  # (derived, not independently calibrated -- see the premium block below).
  # CALIBRATION FLOOR, arithmetic behind the number: allowance = tokens /
  # (p/100), so moving from p to p+-1 scales the allowance by a factor of
  # p/(p+-1). At p=10 that is a 9-11% swing from a single point of payload
  # noise; at p=20 it is a 5% swing -- "a few percent", not "about ten".
  # Went with 20 over the suggested 10 because the live failure was not a
  # one-point wobble: raw.five_hour flickered [19,1,19,1,19] (the same
  # concurrent-session cache rotation the ROOT CAUSE comment already
  # documents) and the smoothed MEDIAN itself hit exactly 0 more than once
  # -- and a 5h window sits below even a 10% floor for a large fraction of
  # every single 5h cycle (idle time, session start), not rarely. 20 keeps
  # calibration off during that idle stretch entirely and only resumes once
  # real usage has actually accumulated.
  def calibration_floor: 20;
  # STEP BOUND: a single recalibration can move the allowance by at most
  # +-20%, full stop, regardless of what the reading implies. This is what
  # was actually missing -- the 3pt agreement gate above did not catch the
  # real 5.8x collapse (a multi-billion-token allowance falling to a
  # fraction of itself in one step) because
  # AT NEAR-ZERO BOTH READINGS AGREE: a corrupted-small allowance predicts
  # a used% that still round-trips against a near-zero payload reading
  # within 3pts, so the gate opened and the blend walked the allowance
  # somewhere wrong anyway. The floor above stops that specific path; this
  # is the second, independent guard in case anything else ever feeds a
  # bad tokens_in_window/allowance pair through here.
  def clamp_step($prev; $fresh):
    [[$fresh, $prev * 1.2] | min, $prev * 0.8] | max;
  # AGREEMENT GATE vs STABILITY GATE. The 3pt agreement gate existed for one
  # reason: a single payload reading could not be trusted on its own, so it
  # had to be corroborated by the allowance’s own prediction before it was
  # allowed to move anything. payload_stable() is a strictly better version
  # of that same check -- it asks whether the payload is rotating DIRECTLY,
  # instead of inferring it from disagreement. So when the payload is
  # provably stable the agreement gate is skipped; when it is not, the gate
  # applies exactly as before.
  #
  # This is what makes the derived value a real fallback again rather than a
  # frozen wrong number. Live, 2026-08-29: predicted 45.03% vs a stable
  # payload 62% is a 17pt disagreement, so the gate slammed shut and the
  # allowance crawled by a few thousand tokens per refresh against a
  # multi-billion-token budget -- it could
  # never converge, so the derived percentage stayed 17 points low forever.
  # A fallback with no way to correct itself is the same bug as a fallback
  # with no validity check.
  #
  # The guards that actually stopped the collapse are UNCHANGED and still
  # cover this path: the 20pt calibration floor (no recalibration near zero,
  # where tokens/used_fraction is ill-conditioned) and the +-20% step bound
  # (no single move can be large, whatever the reading implies). Stability
  # only decides whether a reading is heard at all, never how far it moves
  # the allowance.
  # Returns {allowance, fresh}: the value to persist, and whether THIS refresh
  # actually derived it from a live reading (as opposed to carrying the
  # persisted one forward untouched). `fresh` is what stamps the vintage
  # below -- it must come from here rather than be re-derived at the call
  # site, or the two conditions drift apart and the stamp starts lying.
  def calibrate_allowance($prev_allowance; $tokens_in_window; $payload; $stable):
    if $tokens_in_window == null or $payload == null or $payload.provisional
       or $payload.value < calibration_floor
    then {allowance: $prev_allowance, fresh: false}
    elif $prev_allowance == null or $prev_allowance <= 0 then
      {allowance: ($tokens_in_window / ($payload.value / 100)), fresh: true}
    else
      ($tokens_in_window / $prev_allowance * 100) as $predicted_pct
      | (if ($stable | not) and ((($predicted_pct - $payload.value) | fabs) > 3)
         then {allowance: $prev_allowance, fresh: false}
         else
           ($tokens_in_window / ($payload.value / 100)) as $fresh
           | ($prev_allowance * 0.9 + $fresh * 0.1) as $blended
           | {allowance: clamp_step($prev_allowance; $blended), fresh: true}
         end)
    end;
  # --- ALLOWANCE VINTAGE: how old is the number we are about to divide by?
  #
  # An allowance is a LAST-KNOWN-GOOD measurement, not a constant, and the
  # two windows reach it on completely different schedules. 7d re-derives
  # itself on essentially every refresh (it sits far above the 20pt floor),
  # so its value is always seconds old. 5h is the opposite: it clears the
  # floor only during a burst -- measured over 3.3 days of real payload
  # samples, the 5-sample median is >= 20 on ~22% of refreshes and pinned
  # just under it the rest of the time -- so 5h must LEARN opportunistically
  # and then REUSE that value across window resets, because the 5h budget is
  # a fixed plan-level quantity that does not change when the window rolls.
  #
  # Reuse across resets is exactly where a value can quietly go stale: the
  # thing that invalidates it (a plan change, or Anthropic resizing the
  # limits) is invisible from here. So every reuse is age-checked, and a
  # value too old to stand behind is DROPPED rather than displayed -- both
  # for the arithmetic and as the calibration anchor, because anchoring a
  # 90/10 blend on a number we refuse to display is still believing it.
  #
  # HORIZON = one 7d window. Rationale: a limit change coincides with a new
  # billing window, so "have I re-measured this inside the current cycle" is
  # the question that actually matters; the observed re-calibration interval
  # while the machine is in use is far shorter than this; and expiring early
  # costs only a "–" (honest), never a wrong number.
  def allowance_max_age: 604800;
  # Vintage, in priority order: the explicit stamp; else the timestamp of the
  # last accepted change in allowance_history (a real recorded vintage --
  # every accepted calibration appends there, so a live state file always has
  # one); else, for a hand-seeded or pre-upgrade state that carries an
  # allowance with no provenance at all, start the clock now. That last case
  # is a one-time grandfather, not a licence: the very next accepted
  # calibration replaces it with a real stamp.
  def allowance_vintage($g; $now):
    (($g // {}).allowance_at)
    // ((($g // {}).allowance_history // []) | if length > 0 then .[-1].t else null end)
    // (if (($g // {}).allowance) == null then null else $now end);
  def allowance_is_fresh($allowance; $at; $now):
    $allowance != null and $allowance > 0 and $at != null
    and (($now - $at) <= allowance_max_age);

  # --- SUB-POINT RESOLUTION: the payload is truthful but coarse.
  #
  # rate_limits.used_percentage is an INTEGER. One point of the 7d window is
  # a large multiple of what even a flat-out hour of work spends -- measured
  # on a real plan, a busy hour moves it about half a point -- so the
  # displayed figure can only tick every two to four heavy hours. The gauge
  # read as frozen while two agents ran flat out.
  # The token derivation has the resolution the payload lacks (it moves every
  # refresh) but not the accuracy (local transcripts cannot see off-machine
  # spend; it read 17 points low on 2026-08-29). Neither is sufficient alone.
  #
  # So ANCHOR the level on the payload integer and INTERPOLATE between its
  # ticks using the tokens accrued since that integer first appeared:
  #
  #     used% = anchor.value + (tokens_now - anchor.tokens) / allowance * 100
  #
  # The anchor records the token count AT THE MOMENT the integer last
  # changed. A tick therefore snaps the display exactly onto the new integer
  # with zero interpolation, and the tokens already reflected in that integer
  # are never counted a second time -- no double count and no jump at the
  # boundary. Level comes from the server, movement comes from local tokens.
  #
  # CAP: interpolation may never add more than one full point. One point is
  # the payload’s own resolution, so one point ahead of it is the edge of
  # what this can honestly claim; past that either the payload is stuck or
  # the tokens are counting something the server is not, and holding at
  # +1.00 stops a stuck payload turning into an unbounded wrong number --
  # which is the exact shape of all three bugs in the README. It is also
  # never negative: a window reset drops tokens below the anchor, which
  # clamps to +0 until the payload notices, and re-anchors immediately.
  #
  # DEGRADES to the bare integer with no token source and no allowance --
  # to the payload, never to a guess.
  def interpolation_cap: 1.0;
  def anchor_used($anchor; $payload_value; $tokens_in_window; $allowance):
    if $payload_value == null then null
    elif $anchor == null or $anchor.value != $payload_value
         or $tokens_in_window == null or $anchor.tokens == null
         or $allowance == null or $allowance <= 0
    then $payload_value
    else
      (($tokens_in_window - $anchor.tokens) / $allowance * 100) as $gain
      | $payload_value + ([([$gain, interpolation_cap] | min), 0] | max)
    end;
  # Re-anchor when the integer moves (the normal tick) and also when the
  # token count falls below the baseline while the integer has not moved yet
  # (a window reset the payload has not reported): both mean the stored
  # baseline no longer belongs to the value on screen.
  def next_anchor($anchor; $payload_value; $tokens_in_window; $now):
    if $payload_value == null then $anchor
    elif $anchor == null or $anchor.value != $payload_value
         or ($tokens_in_window != null and $anchor.tokens != null
             and $tokens_in_window < $anchor.tokens)
    then {value: $payload_value, tokens: $tokens_in_window, t: $now}
    else $anchor end;
  # Small persisted trail of accepted allowance values (deduped -- only
  # appended when it actually changes) so a collapse is visible in the
  # state file on inspection, not only when someone happens to be
  # watching the status line at the moment it happens.
  def append_allowance_history($prev_hist; $prev_val; $new_val; $now):
    ($prev_hist // []) as $h
    | if $new_val == $prev_val or $new_val == null then $h
      else ($h + [{t: $now, allowance: $new_val}] | if length > 20 then .[-20:] else . end)
      end;

  # --- the shared math once used% and allowance are known, for any of the
  # three gauges: required rate to land at 100% at reset, actual rate from
  # real token spend (two different honest ways to measure it -- see the
  # $rate_mode branches), burn ratio (uncapped -- see the render pass for
  # why), lands_at (clamped [0,999]), and the ratio’s own trend history.
  # actual_rate <= 0 is handled explicitly (burn_ratio deliberately 0,
  # lands_at deliberately "stays where it is"), not by an accidental clamp:
  # a real observed case had used% dip 46->44 with no work done, and a
  # formula that does not special-case this ran the projection to -615%.
  def gauge_math($used_pct; $r; $now; $win_seconds; $allowance; $tokens_in_window;
                 $rate_src; $rate_mode; $prev_rt):
    (if $r == null then null else (($r - $now) / 3600) end) as $hrs_to_reset
    | (if $hrs_to_reset == null or $hrs_to_reset <= 0 or $used_pct == null then null
       else ((100 - $used_pct) / $hrs_to_reset) end) as $required_rate
    | (if $rate_mode == "elapsed" then
         # For a window short enough that "trailing complete hours" does not
         # fit (5h): the rate is real tokens spent since the window opened,
         # divided by real elapsed hours since the window opened -- no
         # assumption that spend is uniform within the current partial
         # hour, just an honest average over whatever time has actually
         # passed. Needs >=20 real minutes elapsed or one burst in the
         # window’s first minute would read as an alarming rate.
         ($win_seconds / 3600) as $win_hours
         | (if $hrs_to_reset == null then null else ($win_hours - $hrs_to_reset) end) as $elapsed_h
         | (if $elapsed_h == null or $elapsed_h < 0.333 or $tokens_in_window == null
               or $allowance == null or $allowance <= 0
            then null else ($tokens_in_window / $allowance * 100 / $elapsed_h) end)
       else
         # For a window long enough that a trailing block of complete
         # calendar hours is a meaningful "recent" sample (7d, and the
         # premium family’s share of it): needs >=2 complete hours or it is
         # one noisy hour, not a rate.
         #
         # HOURS OBSERVED vs HOURS PRESENT. $bh only contains hours that had
         # spend, so its own length answers "how many hours did I work",
         # which is the right denominator for 7d (its own rows ARE the
         # sample). It is the WRONG denominator for a filtered sub-stream
         # like the premium family: its rows only exist for hours it ran, so an
         # idle premium window produced an empty array and therefore a null rate --
         # "unknown" -- when the honest answer is a measured ZERO. The
         # caller passes $rate_src.hours_observed = the hour count the usage
         # file was actually READ for (7d’s own array), so premium is averaged
         # over the same hours 7d saw. Genuinely absent data (no usage file,
         # or 7d itself short of hours) still lands on < 2 and still reads
         # "–"; measured zero now reads as zero, which gauge_math already
         # handles below (rate 0 => lands where you are).
         #
         # CURRENT PARTIAL HOUR. Excluding it entirely meant work happening
         # right now contributed nothing for up to 60 minutes and then
         # arrived diluted to 1/6 -- two agents running hard moved nothing.
         # It is now included in the numerator immediately, with the elapsed
         # fraction of the hour as its weight in the denominator, FLOORED AT
         # 1/3 h. The floor is the whole anti-spike guard and it is the same
         # 20-minute floor the "elapsed" branch above uses, for the same
         # reason: without it a 2-minute burst divides by 0.033 h and reads
         # ~30x high. With it the worst case is bounded at 3x on ONE term of
         # a ~7-term average, and it decays as the hour fills. Chosen over a
         # dead-zone (ignore the hour until 20 min in) because a dead zone
         # keeps the latency this is meant to remove.
         ($rate_src.by_hour // []) as $bh
         | (($rate_src.hours_observed // ($bh | length))) as $nh
         | ([($rate_src.cur_frac // 0), 0.3333333] | max) as $cw
         | (if $nh < 2 or $allowance == null or $allowance <= 0 then null
            else ((($bh | map(.oe) | add // 0) + ($rate_src.cur_oe // 0))
                  / $allowance * 100 / ($nh + $cw)) end)
       end) as $actual_rate
    | (if $actual_rate == null or $required_rate == null then null
       elif $actual_rate <= 0 then 0
       else ($actual_rate / ([$required_rate, 0.01] | max))
       end) as $burn_ratio
    | (if $actual_rate == null or $hrs_to_reset == null or $used_pct == null then null
       elif $actual_rate <= 0 then $used_pct
       else ([($used_pct + $actual_rate * $hrs_to_reset), 999] | min)
       end) as $lands_raw
    | (if $lands_raw == null then null else ([$lands_raw, 0] | max) end) as $lands_at
    | (if $burn_ratio == null then ($prev_rt // [])
       else (($prev_rt // []) + [(($burn_ratio * 100 | round) / 100)]
             | if length > 10 then .[-10:] else . end)
       end) as $rt2
    | { hours_to_reset: $hrs_to_reset, actual_rate: $actual_rate,
        burn_ratio: $burn_ratio, lands_at: $lands_at, ratio_trend: $rt2 };

  (now) as $now
  | ($prev[0] // {}) as $prev
  | (.rate_limits // {}) as $rl

  # --- raw used_percentage history, last 5 samples per window. This is the
  # ROOT CAUSE, recorded here so nobody "fixes" it by averaging harder: the
  # payload’s own used_percentage is not one noisy sensor -- it is FOUR
  # stable, non-flickering values (observed on seven_day: 40/44/46/56, a
  # 16-point spread) in a fixed rotation, one per concurrently-running
  # Claude Code process (main session + subagents), each faithfully
  # reporting ITS OWN cached snapshot of the last time IT synced with the
  # server. None of the four readings is wrong; they are different
  # processes different snapshots, and the disagreement does not shrink
  # with a longer averaging window the way real noise would, because it
  # does not decay with time -- it only changes when a given process cache
  # happens to resync, on no fixed schedule.
  #
  # BUT the rotation is EPISODIC, not permanent -- it is present exactly
  # while the running processes disagree -- and the local token count has a
  # structural fault of its own that no amount of calibration can fix:
  # usage-hourly.jsonl is built from LOCAL transcripts, so it cannot see
  # spend from another machine, the web app, or a cloud session, and
  # therefore under-counts a shared plan by however much of it happened
  # somewhere else. So neither source is unconditionally right:
  #
  #   payload stable   -> the payload IS the server’s own figure. Trust it.
  #   payload rotating -> the payload is 4 disagreeing caches. Derive from
  #                       tokens instead (still exact for local spend, and
  #                       calibrated against the payload while it was stable).
  #
  # payload_stable() above decides which case we are in, per window, per
  # refresh. The token derivation stays as the fallback and stays honest:
  # it reconciles exactly against the collector’s own total for the
  # window, to the token, and actual_rate/lands are still computed
  # from it for every gauge, because a rate needs real spend over real time
  # and an integer percentage that only moves on resync cannot supply one.
  # $divergence now flags the reverse case from before: the displayed
  # payload figure disagreeing with the local token derivation -- usually
  # off-machine spend, or an allowance still converging. (the premium family
  # has no live payload reading at all -- see its block -- so it is always
  # token-derived and carries no cross-check/marker, by construction.)
  | ([["five_hour", 18000], ["seven_day", 604800]]
     | map(
         . as [$k, $win]
         | (($prev.raw // {})[$k] // []) as $rarr
         | ($rl[$k]) as $v
         | (if $v == null then $rarr
            else ($rarr + [$v.used_percentage // 0] | if length > 5 then .[-5:] else . end)
            end)
         | {key: $k, value: .}
       )
     | from_entries) as $raw
  | (smoothed($raw.five_hour // [])) as $fh_smoothed
  | (smoothed($raw.seven_day // [])) as $sd_smoothed
  | (payload_stable($raw.five_hour // [])) as $fh_stable
  | (payload_stable($raw.seven_day // [])) as $sd_stable

  # ================= seven_day =================
  | ($usage_agg.seven_day.tokens_in_window) as $tok_7
  | (($prev.gauge // {}).seven_day) as $pg7
  # An allowance older than the horizon is dropped BEFORE it is used and
  # before it can anchor a blend: a number we refuse to display is a number
  # we do not believe, and believing it 90% of the way is still believing it.
  # Dropping it also restores the direct-set path, which the 20pt floor makes
  # safe -- it is the same path a first-ever calibration takes.
  | (allowance_vintage($pg7; $now)) as $vint_7
  | (if allowance_is_fresh($pg7.allowance; $vint_7; $now) then $pg7.allowance
     else null end) as $prev_allow_7
  | (calibrate_allowance($prev_allow_7; $tok_7; $sd_smoothed; $sd_stable)) as $cal_7
  | ($cal_7.allowance) as $allow_7
  | (if $allow_7 == null then null elif $cal_7.fresh then $now else $vint_7 end) as $allow_at_7
  | (if $tok_7 == null or $allow_7 == null or $allow_7 <= 0 then null
     else ([($tok_7 / $allow_7 * 100), 0] | max) end) as $raw_pct_7
  # SANITY CLAMP: >150% is not a real reading on an independently-
  # calibrated window -- it is what a broken calibration produces (live,
  # observed: 799% then 867% off a 5h allowance that had collapsed 5.8x).
  # Fall back to the payload median (computed from the raw feed, so it
  # cannot have inherited the same corruption) rather than show a number
  # already known to be false.
  | ($raw_pct_7 != null and $raw_pct_7 > 150) as $insane_7
  # SOURCE SELECTION, in priority order (see the ROOT CAUSE comment above):
  #   1. stable payload -- the server’s own figure, and the only source that
  #      can see spend from other machines / web / cloud sessions;
  #   2. token derivation -- exact for local spend, used whenever the
  #      payload is rotating (or too new to have a spread yet);
  #   3. payload anyway -- when there is no usable derivation at all, or the
  #      derivation is already known false (>150%).
  # A corrupted allowance corrupts actual_rate exactly the same way it
  # corrupts the percentage (same division), so the same distrust applies:
  # the persisted $allow_7 is kept as-is (so the bounded step above can
  # still heal it over subsequent refreshes), but it is withheld from
  # gauge_math’s rate arithmetic -- and from the interpolation -- this round
  # when it looks broken.
  | (if $insane_7 then null else $allow_7 end) as $allow_7_for_math
  # Whenever the payload is what gets displayed, display it at sub-point
  # resolution: the integer as the level, local tokens as the movement
  # between its ticks. Both payload branches below go through this; with no
  # allowance or no tokens it returns the bare integer unchanged.
  | ($pg7.payload_anchor) as $panch_7
  | (anchor_used($panch_7; ($sd_smoothed.value // null); $tok_7; $allow_7_for_math)) as $payload_used_7
  | (next_anchor($panch_7; ($sd_smoothed.value // null); $tok_7; $now)) as $panch_7_next
  | (if $sd_stable and ($sd_smoothed.value // null) != null then $payload_used_7
     elif $insane_7 or $raw_pct_7 == null then $payload_used_7
     else $raw_pct_7 end) as $used_7
  # Divergence is computed from the RAW (pre-clamp) figure against the
  # payload, not from $used_7, so it stays the same number whichever source
  # won: the size of the disagreement between the two. Which of them it
  # indicts flips with the source -- token-derived shown => it warns the
  # derivation may be broken; payload shown => it warns the local token
  # count is missing spend, or the allowance has not finished converging.
  | (if $raw_pct_7 == null or $sd_smoothed == null then null
     else ($raw_pct_7 - $sd_smoothed.value) end) as $div_7
  | (valid_resets_at((($prev.gauge // {}).seven_day.resets_at); $now; 168)) as $prev_r7
  | (valid_resets_at(($rl.seven_day.resets_at | epoch); $now; 168)) as $live_r7
  | ($live_r7 // $prev_r7) as $r7
  # Visible counter, not a rediscovery from a negative number: how many
  # refreshes in a row (and total) the live payload arrived without a
  # resets_at we could actually use for this window.
  | (($prev.gauge // {}).seven_day.resets_at_missing_count // 0) as $prev_miss7
  | (if $live_r7 == null then $prev_miss7 + 1 else $prev_miss7 end) as $miss7
  | (gauge_math($used_7; $r7; $now; 604800; $allow_7_for_math; $tok_7;
                {by_hour: $usage_agg.seven_day.by_hour, hours_observed: null,
                 cur_oe: $usage_agg.seven_day.cur_oe, cur_frac: $usage_agg.cur_frac};
                "hours"; ($pg7.ratio_trend))) as $gm7
  | (append_allowance_history(($pg7.allowance_history);
                               $prev_allow_7; $allow_7; $now)) as $ahist_7
  | ({ median: ($used_7 // null), payload_median: ($sd_smoothed.value // null),
       payload_stable: $sd_stable, source: (if $sd_stable and ($sd_smoothed.value // null) != null
                                            then "payload" else "tokens" end),
       provisional: ($sd_smoothed.provisional // false), resets_at: $r7,
       allowance: $allow_7, allowance_at: $allow_at_7, payload_anchor: $panch_7_next,
       allowance_history: $ahist_7, divergence: $div_7, resets_at_missing_count: $miss7
     } + $gm7) as $gauge_seven_day

  # ================= five_hour =================
  # Independently calibrated, NOT derived from the 7d allowance -- checked
  # against real data before assuming otherwise: on a real plan the
  # calibrated five_hour allowance divided by the calibrated seven_day
  # allowance came out around 9%, not the ~3.0% (5/168)
  # that a shared per-hour rate would produce -- the 5h window runs at
  # roughly 3x the hourly rate of the 7d window. That is consistent with
  # 5h being a burst-capacity limit and 7d a sustained-usage limit, two
  # independently-sized budgets, not a fixed fraction of one another.
  # Deriving 5h from 7d would therefore systematically under-allow it by
  # ~3x and read "over pace" essentially always. The bug here was the
  # calibration’s ROBUSTNESS near zero, not the independence assumption.
  | ($usage_agg.five_hour.tokens_in_window) as $tok_5
  | (($prev.gauge // {}).five_hour) as $pg5
  # OPPORTUNISTIC CALIBRATION, then REUSE. This is the window the vintage
  # machinery exists for. 5h clears the 20pt floor only during a burst
  # (measured: the 5-sample median is >= 20 on ~22% of refreshes over 3.3
  # days, and pinned at 19 for hours at a time in between), so it cannot
  # relearn its allowance on demand the way 7d does. It does not have to:
  # the 5h budget is a fixed plan quantity that does NOT change when the
  # window rolls, so a value learned during one burst stays correct through
  # every reset until the plan itself changes. Hence: learn it whenever the
  # floor is cleared, carry it forward untouched the rest of the time, and
  # age-check every reuse so "carried forward" can never become "forever".
  | (allowance_vintage($pg5; $now)) as $vint_5
  | (if allowance_is_fresh($pg5.allowance; $vint_5; $now) then $pg5.allowance
     else null end) as $prev_allow_5
  | (calibrate_allowance($prev_allow_5; $tok_5; $fh_smoothed; $fh_stable)) as $cal_5
  | ($cal_5.allowance) as $allow_5
  | (if $allow_5 == null then null elif $cal_5.fresh then $now else $vint_5 end) as $allow_at_5
  | (if $tok_5 == null or $allow_5 == null or $allow_5 <= 0 then null
     else ([($tok_5 / $allow_5 * 100), 0] | max) end) as $raw_pct_5
  | ($raw_pct_5 != null and $raw_pct_5 > 150) as $insane_5
  # Same three-way source selection as seven_day. 5h benefits from this the
  # most in practice: its allowance is null for most of every cycle (the
  # 20pt calibration floor keeps it that way on purpose), so a stable
  # payload is the ONLY source that can give this window a percentage at
  # all. It still cannot give it a RATE -- actual_rate needs an allowance to
  # convert tokens into points -- so ratio/lands stay "–" until one exists.
  # That is the file’s rule working, not a gap: an unmeasurable rate must
  # read as unmeasurable.
  | (if $insane_5 then null else $allow_5 end) as $allow_5_for_math
  | ($pg5.payload_anchor) as $panch_5
  | (anchor_used($panch_5; ($fh_smoothed.value // null); $tok_5; $allow_5_for_math)) as $payload_used_5
  | (next_anchor($panch_5; ($fh_smoothed.value // null); $tok_5; $now)) as $panch_5_next
  | (if $fh_stable and ($fh_smoothed.value // null) != null then $payload_used_5
     elif $insane_5 or $raw_pct_5 == null then $payload_used_5
     else $raw_pct_5 end) as $used_5
  | (if $raw_pct_5 == null or $fh_smoothed == null then null
     else ($raw_pct_5 - $fh_smoothed.value) end) as $div_5
  | (valid_resets_at((($prev.gauge // {}).five_hour.resets_at); $now; 5)) as $prev_r5
  | (valid_resets_at(($rl.five_hour.resets_at | epoch); $now; 5)) as $live_r5
  | ($live_r5 // $prev_r5) as $r5
  | (($prev.gauge // {}).five_hour.resets_at_missing_count // 0) as $prev_miss5
  | (if $live_r5 == null then $prev_miss5 + 1 else $prev_miss5 end) as $miss5
  | (gauge_math($used_5; $r5; $now; 18000; $allow_5_for_math; $tok_5;
                null; "elapsed"; ($pg5.ratio_trend))) as $gm5
  | (append_allowance_history(($pg5.allowance_history);
                               $prev_allow_5; $allow_5; $now)) as $ahist_5
  | ({ median: ($used_5 // null), payload_median: ($fh_smoothed.value // null),
       payload_stable: $fh_stable, source: (if $fh_stable and ($fh_smoothed.value // null) != null
                                            then "payload" else "tokens" end),
       provisional: ($fh_smoothed.provisional // false), resets_at: $r5,
       allowance: $allow_5, allowance_at: $allow_at_5, payload_anchor: $panch_5_next,
       allowance_history: $ahist_5, divergence: $div_5, resets_at_missing_count: $miss5
     } + $gm5) as $gauge_five_hour

  # ================= premium family =================
  # The premium family is not a window of its own: it is a weighted SHARE of
  # the 7d window (per share.json premium_share_of_7d.allowance, 0.5 = half).
  # Its allowance is therefore DERIVED from the already-calibrated (and now
  # floor/step-guarded) 7d allowance rather than independently calibrated
  # against a payload reading -- there is no live "premium used%" field in
  # the Claude Code payload to calibrate against, and multiplying the 7d
  # allowance by the share fraction is exact (no agreement gate needed,
  # because nothing here can disagree with itself). It shares the 7d
  # resets_at/clock -- the slice resets when the 7d window does.
  # NOT sanity-clamped like seven_day/five_hour above: this allowance
  # cannot independently collapse (it is a fixed multiple of 7d’s, already
  # guarded), so a reading over 150% is a real signal -- the family
  # genuinely spending past its share -- not a broken calibration, and
  # clamping it would suppress the one thing this gauge exists to show
  # (see harness case 17, a real 220% overage rendered plainly).
  | ($prem.allowance // 0.5) as $prem_frac
  | (if $allow_7 == null then null else ($allow_7 * $prem_frac) end) as $allow_f
  | ($usage_agg.premium.tokens_in_window) as $tok_f
  | (if $tok_f == null or $allow_f == null or $allow_f <= 0 then null
     else ([($tok_f / $allow_f * 100), 0] | max) end) as $used_f
  # MEASURED ZERO IS NOT MISSING DATA -- and it is not "you do not run this
  # family" either. Those are three different things and they render three
  # different ways:
  #   no premium family resolved  -> $prem is null, tokens_in_window is null,
  #                                  and the render gate below drops the whole
  #                                  segment. Nothing is claimed.
  #   family resolved, no spend   -> a real, measured 0.00% (see below).
  #   family resolved, no data    -> "–". Unknown, and said so.
  # The middle case: the family’s by_hour only has rows for hours it actually
  # ran, so an idle window produced an empty array, a null rate and "lands –"
  # -- reported as unknown when it was known, and known to be zero. The proof
  # of which case we are in is 7d’s own by_hour: if the usage file yielded
  # >= 2 complete hours there, those hours WERE read, so the premium family
  # having none of them is a measurement, not a gap. So it is averaged over
  # the hours 7d observed (hours_observed), and rate 0 flows into
  # gauge_math’s existing $actual_rate <= 0 branch -- lands where you are,
  # which is the right answer for spending nothing. Genuinely absent data
  # (no usage file, or 7d itself short of complete hours) leaves
  # hours_observed < 2 and still renders "–".
  | (gauge_math($used_f; $r7; $now; 604800; $allow_f; $tok_f;
                {by_hour: $usage_agg.premium.by_hour,
                 hours_observed: ($usage_agg.seven_day.by_hour | length),
                 cur_oe: $usage_agg.premium.cur_oe, cur_frac: $usage_agg.cur_frac};
                "hours"; (($prev.gauge // {}).premium.ratio_trend))) as $gmf
  | (append_allowance_history((($prev.gauge // {}).premium.allowance_history);
                               (($prev.gauge // {}).premium.allowance); $allow_f; $now)) as $ahist_f
  # This is the one gauge with no payload alternative, so it is ALWAYS
  # token-derived -- which makes it the reason $allow_7 must be able to
  # converge at all. Its allowance is a fixed fraction of 7d’s, so once the
  # stability gate lets 7d’s allowance track the truth, this percentage
  # moves onto the same scale automatically; while 7d’s allowance was frozen
  # 17 points low, this was reading proportionally low too, silently.
  | ({ median: ($used_f // null), payload_median: null, provisional: false,
       payload_stable: false, source: "tokens",
       family: ($prem.family // null), weight: ($prem.weight // null),
       resets_at: $r7, allowance: $allow_f, allowance_history: $ahist_f,
       divergence: null } + $gmf) as $gauge_premium

  | {
      raw: $raw,
      smoothed: {five_hour: $fh_smoothed, seven_day: $sd_smoothed},
      gauge: {
        seven_day: $gauge_seven_day,
        five_hour: $gauge_five_hour,
        premium: $gauge_premium
      }
    }
' <<<"$input" 2>/dev/null)

[ -n "$trend_hist" ] || trend_hist='{"five_hour":[],"seven_day":[],"premium":[],"raw":{"five_hour":[],"seven_day":[]},"gauge":{"seven_day":{}}}'
# Multiple Claude Code sessions share this one file. Writing straight to it
# with `>` lets two concurrent writers interleave and corrupt it (seen in
# the wild: valid JSON with garbage trailing bytes), which then makes every
# future read fail and the arrows vanish for good. Write-to-temp-then-rename
# is atomic, so readers only ever see a fully old or fully new file, and a
# corrupt file self-heals on the next refresh instead of staying stuck.
trend_tmp="${trend_file}.tmp.$$"
if printf '%s' "$trend_hist" > "$trend_tmp" 2>/dev/null; then
  mv -f "$trend_tmp" "$trend_file" 2>/dev/null
fi

# Phase 1: pull out just what we need before shelling out to git.
eval "$(jq -r '@sh "cwd=\(.cwd // "") transcript=\(.transcript_path // "")"' <<<"$input" 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Git branch + dirty flag. --untracked-files=no keeps this fast in big trees.
branch=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -n "$branch" ] || branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  git -C "$cwd" diff --no-ext-diff --quiet 2>/dev/null || branch="${branch}*"
fi

# Cumulative session tokens come from the transcript; ~10ms for a 500KB file.
[ -f "$transcript" ] || transcript=/dev/null

jq -nr \
  --argjson s "$input" \
  --argjson cols "${COLUMNS:-0}" \
  --argjson trend_hist "$trend_hist" \
  --argjson usage_present "$({ [ -f "$usage_file" ] || [ -f "$share_file" ]; } && echo true || echo false)" \
  --argjson prem "$prem" \
  --arg branch "$branch" \
  --arg home "$HOME" \
  --arg cwd_fallback "$cwd" '
  # Monochrome: colour arguments are still accepted but ignored, so the layout
  # logic below is unchanged. Text renders in the terminal default foreground.
  def esc(n): .;
  def dim:    .;
  # The pace bar is the one element that keeps colour: green/red IS the signal.
  def paint($c): "\u001b[\($c)m" + . + "\u001b[0m";
  def vislen: gsub("\u001b\\[[0-9;]*m"; "") | length;
  def cells($pct; $n):
    ($pct / 100 * $n) | round | if . > $n then $n elif . < 0 then 0 else . end;
  # $mark is the pace cell (-1 for none): a | showing where usage should be now.
  def bar($n; $fill; $mark; $c):
    ("[" | dim)
    + ([range(0; $n)
        | if   . == $mark then "|"
          elif . <  $fill then "█"
          else "░" end] | join("") | paint($c))
    + ("]" | dim);
  # Context bands: Claude Code auto-compacts around 92% and recall degrades well
  # before that, so amber starts at 75% rather than tracking the hard limit.
  def ctx_colour:
    if   . >= 90 then 31
    elif . >= 75 then "38;5;208"
    elif . >= 50 then 33
    else 32 end;
  def fmtk:
    if . == null or . == 0 then "0"
    elif . >= 1000000 then "\(. / 100000 | floor / 10)M"
    elif . >= 1000    then "\(. / 100    | floor / 10)k"
    else "\(. | floor)" end;
  def dur:
    (. | floor) as $t
    | if   $t <= 0    then "now"
      elif $t < 3600  then "\($t / 60 | floor)m"
      elif $t < 86400 then "\($t / 3600 | floor)h\(($t % 3600) / 60 | floor)m"
      else "\($t / 86400 | floor)d" end;
  def pct_colour:
    if . >= 85 then 31 elif . >= 60 then 33 else 32 end;
  def epoch:
    if   . == null      then null
    elif type == "number" then (if . > 100000000000 then . / 1000 else . end)
    else (fromdateiso8601? // null) end;
  # Same invariant as the state update: a resets_at outside (now,
  # now+window_hours] is impossible and must be discarded here too, not
  # just when it is written -- the render pass re-derives $r5/$r7 from the
  # LIVE payload independently of what got persisted, so a bad live value
  # could otherwise reach the pace marker even with a clean state file.
  def valid_resets_at($r; $now; $window_hours):
    if $r == null then null
    elif $r > $now and $r <= ($now + $window_hours * 3600) then $r
    else null end;
  # Fixed 2-decimal-place string for a non-negative number, e.g. 11.2 -> "11.20".
  def dec2:
    (. * 100 | round) as $h
    | ($h / 100 | floor) as $w
    | ($h - ($w * 100)) as $f
    | ($w | tostring) + "." + ($f | tostring | if length < 2 then "0" + . else . end);
  # Trend arrow from a rolling history of pace-delta samples (oldest first):
  # least-squares slope sign over (index, value). A pure idle window still
  # trends down every refresh (frac keeps climbing while used% holds), so
  # this reports direction at whatever magnitude actually exists rather than
  # gating on a minimum move — two samples are enough to have a slope.
  def trend_sign($arr):
    ($arr | length) as $n
    | if $n < 2 then 0
      else
        ($arr | to_entries) as $pts
        | (($n - 1) / 2) as $mi
        | (($arr | add) / $n) as $mv
        | ($pts | map((.key - $mi) * (.value - $mv)) | add) as $cov
        | if   $cov > 0  then 1
          elif $cov < 0  then -1
          else 0 end
      end;
  def trend_arrow($sign):
    if   $sign > 0 then " ↑"
    elif $sign < 0 then " ↓"
    else "" end;

  # --- the usage gauges (5h / 7d / premium), on their own line ------------
  # Same shape for all three: a 20-cell bar whose |> fill is the used% the
  # state update chose for this window -- the payload’s own figure while it
  # is provably stable, the token derivation while it is rotating (see the
  # ROOT CAUSE comment in the state update above), a |> marker at the
  # window’s own elapsed-time fraction, then the burn ratio (actual/required
  # rate, capped at 9.99x for display), its trend arrow, and where it lands
  # at reset if the current rate holds. The bar fill AND the marker are
  # coloured by the same ratio bands as the ratio/lands figures (green <0.9,
  # amber 0.9-1.1, red >1.1); "no data" (ratio unmeasurable) is neutral, not
  # green by default -- "unmeasurable" must never read as "healthy".
  def band_colour($ratio):
    if   $ratio == null then null
    elif $ratio < 0.9   then 32
    elif $ratio <= 1.1  then 33
    else 31 end;
  def gauge_bar($n; $fill; $mark; $c):
    ("▕")
    + ([range(0; $n)
        | if   . == $mark then (if $c == null then ("┃" | dim) else ("┃" | paint($c)) end)
          elif . <  $fill then (if $c == null then ("▓" | dim) else ("▓" | paint($c)) end)
          else ("░" | dim) end
       ] | join(""))
    + ("▏");
  # POSITION (the bar) and RATE (the ratio/lands figures) answer different
  # questions and are coloured independently: position asks "am I ahead of
  # or behind the pace marker right now" (used% vs pace%, a statement about
  # the past); rate asks "where does the CURRENT burn land me at reset" (the
  # ratio, a statement about the future). They can disagree -- real case:
  # 7d at 45% used against a ~34% pace marker (ahead -> bar should warn) while
  # spending 0.31x the required rate (well under budget -> ratio/lands stay
  # green). Colouring the bar on the ratio made a real overshoot look green;
  # this must never happen again.
  def position_colour($used; $pace_pct):
    if $pace_pct == null then null
    # Division blows up at/near the very start of a window (pace_pct -> 0).
    # If nothing meaningful has been spent either, there is nothing to warn
    # about -- green, not a huge quotient. If something HAS been spent
    # already while pace is still ~0, that is a genuine early overshoot and
    # must still be evaluated (pace floored, never literally divided by 0).
    elif $used <= 0.5 and $pace_pct <= 0.5 then 32
    else
      ($used / ([$pace_pct, 0.5] | max)) as $pos
      | if   $pos < 1.00 then 32
        elif $pos <= 1.15 then 33
        else 31 end
    end;
  # Signed points-ahead/behind the pace line -- the same fact the bar
  # colour states visually, spelled out numerically, in the SAME colour.
  # -0.5..+0.5 renders bare "0" (never "-0"); unknown position (no
  # resets_at, same condition that makes the bar neutral) renders "-" dim,
  # never "+0" -- "no data" must not read as "on the line" either.
  # {raw, display}: raw is the unrounded used%-pace% gap (or null when
  # position is unknown); display is null (unknown), 0 (within -0.5..+0.5,
  # "on the line"), or the signed rounded points otherwise. Both delta_text
  # and the 7d-only catch-up parenthetical are derived from this ONE
  # computation so they can never disagree with each other.
  # display is null (unknown), 0 (within -0.5..+0.5 -- "on the line", the
  # sentinel that keeps a near-zero gap from ever printing "-0.00"), or the
  # RAW (unrounded) points gap otherwise -- kept at full precision because
  # the 2dp delta text and the catch-up hours/minutes conversion both read
  # from it and must never independently round it two different ways.
  def pace_delta($used; $pace_pct):
    if $pace_pct == null then {raw: null, display: null}
    else
      ($used - $pace_pct) as $raw
      | {raw: $raw, display: (if $raw >= -0.5 and $raw <= 0.5 then 0 else $raw end)}
    end;
  # Signed, 2dp, ALWAYS with a "%" -- these are points of the window, and
  # without the unit "+8.06" sitting next to a "(24m)" reads as a second
  # time figure (it was misread as exactly that). The 2dp also matches the
  # percentage next to it: "44.32% +10.34%" reads as arithmetic that agrees;
  # "44.32% +10" would read as a bug.
  def delta_text($pd; $c):
    if $pd.display == null then ("–" | dim)
    else
      (if   $pd.display == 0 then "0.00%"
       elif $pd.display > 0  then "+" + ($pd.display | dec2) + "%"
       else "-" + (($pd.display * -1) | dec2) + "%" end) | paint($c)
    end;
  # The SAME gap as delta_text, expressed in this window’s own time instead
  # of its points: (15m ahead) under 1h, (18h ahead) under 48h, (2.3d ahead)
  # at/above -- never a three-digit hour count.
  #
  # Rendered in BOTH directions, because both are things you act on:
  #   "ahead"  (positive) -- spent past the pace line; how long of spending
  #                          nothing puts you back on it.
  #   "behind" (negative) -- under the line; how long of spending at pace
  #                          you could do before reaching it. Headroom.
  # The word is what makes them safe: a bare signed time is one glance away
  # from meaning its own opposite, and the sign is already carrying the
  # delta percentage right next to it. Never omit the word to save width --
  # the width ladder drops the whole parenthetical instead.
  #
  # A zero or unknown delta still renders nothing: there is no gap to
  # express, and "no data" must not read as "on the line" here either.
  # $pph is points-per-hour for THIS gauge’s own window (100 /
  # window_hours) -- 5h=20, 7d=0.5952; premium rides the 7d clock (same
  # $frac7 marker as seven_day, confirmed at the call site below) so it
  # uses 7d’s 0.5952 too, not a share-scaled rate of its own.
  def catchup_text($pd; $c; $pph):
    if $pd.display == null or $pd.display == 0 then ""
    else
      (if $pd.display > 0 then "ahead" else "behind" end) as $dir
      | ((if $pd.display > 0 then $pd.display else ($pd.display * -1) end) / $pph) as $hours
      | (if   $hours < 1  then "\(($hours * 60) | round)m"
         elif $hours < 48 then "\($hours | round)h"
         else "\(($hours / 24 * 10 | round) / 10)d" end) as $val
      | (" (" + $val + " " + $dir + ")") | paint($c)
    end;
  def render_gauge($g; $frac; $label; $n; $window_hours):
    ($g // {}) as $g
    | (if $g.median == null then 0 else $g.median end) as $median
    | (($g.provisional // false) | if . then (" prov" | dim) else "" end) as $prov
    | (($g.divergence) as $d
       | if $d == null or ($d | fabs) <= 5 then "" else ("!" | paint(33)) end) as $diverge
    | (if $frac == null then null else ($frac * 100) end) as $pace_pct
    | (if $frac == null then -1
       else (($frac * $n) | floor | if . >= $n then $n - 1 else . end) end) as $mark
    | (cells($median; $n)) as $fill
    | (position_colour($median; $pace_pct)) as $pos_c
    | ($g.burn_ratio) as $ratio_raw
    | (if $ratio_raw == null then null else ([$ratio_raw, 9.99] | min) end) as $ratio
    | (band_colour($ratio)) as $c
    | ($g.lands_at) as $lands
    | (if $ratio == null then ("–" | dim)
       else (($ratio | dec2) + "×" | paint($c)) end) as $ratio_text
    | (trend_sign($g.ratio_trend // [])) as $rtsign
    | (if $ratio == null then ""
       elif $rtsign > 0 then ("↗" | paint(31))
       elif $rtsign < 0 then ("↘" | paint(32))
       else ("→" | dim) end) as $ratio_arrow
    # lands_at > 100 is always red, even if the ratio band rounded green --
    # the projection crossing 100 is the one fact this figure exists to
    # surface, so it cannot be softened by the ratio’s own banding. This
    # is RATE-side, unchanged, still keyed to $c (ratio colour), not $pos_c.
    | (if   $lands == null then null
       elif $lands > 100   then 31
       else ($c // 33) end) as $lc
    | (if $lands == null then ("–" | dim)
       else (($lands | round | tostring) + "%" | paint($lc)) end) as $lands_text
    | (pace_delta($median; $pace_pct)) as $pd
    | { text: $label,
        pct:  "\($median | dec2)%" + $diverge + $prov + " " + delta_text($pd; $pos_c),
        catchup: catchup_text($pd; $pos_c; (100 / $window_hours)),
        bar:  gauge_bar($n; $fill; $mark; $pos_c),
        # No usage source installed at all => omit the rate half of the
        # gauge rather than render a "-" that can never fill in. A "-" here
        # means "there is a source and it cannot answer right now".
        delta: (if $usage_present
                then " " + $ratio_text + $ratio_arrow + "  lands " + $lands_text
                else "" end) };

  # --- cumulative session token usage -------------------------------------
  (reduce inputs as $l (
      {i: 0, o: 0, cc: 0, cr: 0};
      ($l.message.usage // {}) as $u
      | {i:  (.i  + ($u.input_tokens          // 0)),
         o:  (.o  + ($u.output_tokens         // 0)),
         cc: (.cc + ($u.cache_creation_input_tokens // 0)),
         cr: (.cr + ($u.cache_read_input_tokens     // 0))}
   )) as $tok

  | ($s.context_window // {}) as $ctx
  | ($s.cost // {})           as $cost
  | ($s.rate_limits // {})    as $rl
  | (now)                     as $now
  | 12                        as $n

  # --- line 1 --------------------------------------------------------------
  | ("\($s.model.display_name // "?")" | esc("1;36")) as $model

  | ([ (if $s.fast_mode      then "fast"                 else empty end),
       (if $s.thinking.enabled == false then "no-think"  else empty end),
       ($s.effort.level // empty),
       (if ($s.output_style.name // "default") != "default"
          then $s.output_style.name else empty end),
       ($s.agent.name // empty)
     ] | if length > 0 then " " + (join(" ") | esc(35)) else "" end) as $flags

  | (($s.cwd // $cwd_fallback // "")
     | sub("^" + $home; "~")
     | split("/")
     | if length > 4 then ["…"] + .[-3:] else . end
     | join("/") | esc(34)) as $dir

  | (if $branch == "" then "" else "  " + ($branch | esc(33)) end) as $git

  | (($ctx.used_percentage // null) as $cp
     | if $cp == null then ""
       else "  " + ("ctx \($cp | floor)%" | paint($cp | ctx_colour))
            + " " + bar($n; cells($cp; $n); -1; ($cp | ctx_colour))
            + (" \($ctx.total_input_tokens | fmtk)/\($ctx.context_window_size | fmtk)" | dim)
       end) as $context
  # Line 1 drops the gauge rather than wrapping on a narrow terminal.
  | (if $cols > 0 and $ctx.used_percentage != null
        and ((($model + $flags) | vislen) + 3 + (($dir + $git + $context) | vislen)) > $cols
     then "  " + ("ctx \($ctx.used_percentage | floor)%" | paint($ctx.used_percentage | ctx_colour))
          + (" \($ctx.total_input_tokens | fmtk)/\($ctx.context_window_size | fmtk)" | dim)
     else $context end) as $context

  # --- line 2 --------------------------------------------------------------
  | (($s.session_id // "") | if . == "" then ""
     else ("sid:" | dim) + (.[0:8] | esc(36)) + "  " end) as $sid

  | (if $cost.total_cost_usd == null then ""
     else ("$" + ($cost.total_cost_usd * 100 | round / 100 | tostring)) | esc(32) end) as $spend

  | (if $cost.total_duration_ms == null then ""
     else ("  " + ($cost.total_duration_ms / 1000 | dur)) | dim end) as $elapsed

  | (if ($cost.total_lines_added // 0) + ($cost.total_lines_removed // 0) == 0 then ""
     else "  " + ("+\($cost.total_lines_added)" | esc(32))
                + ("/" | dim)
                + ("-\($cost.total_lines_removed)" | esc(31))
     end) as $lines

  | ("  " + ("sess " | dim)
          + ("↑\($tok.i + $tok.cc | fmtk)" | esc(36))
          + ("/" | dim)
          + ("↓\($tok.o | fmtk)" | esc(36))
          + (" (cache \($tok.cr | fmtk))" | dim)) as $session

  | 20 as $gn
  | (valid_resets_at(($rl.five_hour.resets_at | epoch); $now; 5)
     // valid_resets_at($trend_hist.gauge.five_hour.resets_at; $now; 5)) as $r5
  | (if $r5 == null then null
     else ((18000 - ($r5 - $now)) / 18000 | if . < 0 then 0 elif . > 1 then 1 else . end) end) as $frac5
  | (valid_resets_at(($rl.seven_day.resets_at | epoch); $now; 168)
     // valid_resets_at($trend_hist.gauge.seven_day.resets_at; $now; 168)) as $r7
  | (if $r7 == null then null
     else ((604800 - ($r7 - $now)) / 604800 | if . < 0 then 0 elif . > 1 then 1 else . end) end) as $frac7

  | (if $rl.five_hour == null then null
     else {key: "five_hour"} + render_gauge($trend_hist.gauge.five_hour; $frac5; "5h"; $gn; 5) end) as $g5
  | (if $rl.seven_day == null then null
     else {key: "seven_day"} + render_gauge($trend_hist.gauge.seven_day; $frac7; "7d"; $gn; 168) end) as $g7
  # The premium family shares the 7d clock (its slice resets when the 7d
  # window does), so it uses $frac7 too, not a marker of its own. No live
  # payload field feeds it at all -- there is nothing to cross-check it
  # against -- so it never carries a divergence "!" or a "prov" tag, only
  # share.json’s own staleness (the collector refreshes every 5 min; three
  # missed cycles means the number is no longer describing now, so say so
  # instead of pretending).
  #
  # $prem is null when the collector resolved no premium family -- this
  # machine does not run one -- and the segment is then omitted entirely.
  # That is the whole point: a gauge for a policy you are not exercising is
  # noise, and a 0.00% bar with a pace delta beside it is worse than noise,
  # because it reads as a measurement of under-use. Two gauges, no claim.
  # The label is the family’s own name (or CLAUDE_STATUSLINE_PREMIUM_LABEL),
  # so the third gauge says which family it is rationing.
  | (if ($prem.age // 0) > 900 then (" stale" | dim) else "" end) as $prem_stale
  | (if $prem == null or $prem.share == null or $rl.seven_day == null then null
     else ({key: "premium"}
           + render_gauge($trend_hist.gauge.premium; $frac7; ($prem.label // "prm"); $gn; 168)
           | .pct += $prem_stale) end) as $gf

  | ([$g5, $g7, $gf] | map(select(. != null))) as $gauges
  | (def part($withbar; $withcatchup):
       .text
       + (if $withbar and .bar != "" then " " + .bar + .pct
          elif .pct != "" then " " + .pct
          else "" end)
       + (if $withcatchup then .catchup else "" end)
       + (if .delta != "" then " " + .delta else "" end);
     # Drop order: catch-up parentheticals go first everywhere (each is
     # only the elaboration on a delta that already carries the signal),
     # least-protected gauge first -- premium (level 1), then 5h (level 2),
     # then 7d (level 3, all three catch-ups now gone). Only past that do
     # bars start dropping, same priority -- premium’s bar (level 4), then
     # 5h’s (level 5). 7d’s bar never drops; the percentage always
     # survives even when its bar does not. The gauges have their own
     # line now (width pressure from the rest of the status line is
     # gone), and keeping everything beats dropping it, so
     # this should essentially never trigger on a normal terminal.
     def withbar($key; $level):
       if   $key == "seven_day" then true
       elif $key == "premium"   then $level < 4
       elif $key == "five_hour" then $level < 5
       else true end;
     def withcatchup($key; $level):
       if   $key == "premium"   then $level < 1
       elif $key == "five_hour" then $level < 2
       elif $key == "seven_day" then $level < 3
       else true end;
     [range(0; 6) as $level
      | ($gauges | map(part(withbar(.key; $level); withcatchup(.key; $level))))]
     | map(join("  "))) as $gauge_variants
  | (first($gauge_variants | to_entries[]
           | select($cols == 0 or (.value | vislen) <= $cols)
           | .value)
     // ($gauge_variants | last)) as $gauge_line

  | ([$sid + $spend + $elapsed + $lines + $session] | join("")) as $base

  | (" │ " | dim) as $sep
  | ([$model + $flags, $dir + $git + $context] | join($sep)),
    ($base),
    ($gauge_line)
  ' "$transcript"
