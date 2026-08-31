#!/usr/bin/env bash
# Synthetic-payload test harness for the token-derived usage gauges
# (5h / 7d / premium) in ~/.claude/statusline.sh, rendered on their own status
# line. Runs the SCRIPT under test with HOME pointed at an isolated per-case
# temp dir (never touches your real ~/.claude state). Cases seed the real
# inputs the gauges read -- usage-hourly.jsonl (real token spend) and the
# persisted .pace-trend.json (calibrated allowances / raw payload history)
# -- rather than pre-computing gauge output fields, so this exercises the
# real calibration + aggregation code, not just its rendering.
set -u

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/statusline.sh}"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
NOW=$(date +%s)
CUR_HOUR=$(date -u +%Y-%m-%dT%H)
hours_ago() { date -u -v-"$1"H +%Y-%m-%dT%H; }   # BSD date (macOS)

usage_row() {  # $1=hour $2=tokens $3=family(default sonnet)
  local fam="${3:-sonnet}"
  printf '{"cache_creation_input_tokens":%s,"cache_read_input_tokens":0,"family":"%s","hour":"%s","input_tokens":0,"kind":"main","messages":1,"model":"claude-%s-5","output_tokens":0}\n' "$2" "$fam" "$1" "$fam"
}

run_case() {
  # $1=name $2=trend-state seed (json or "") $3=payload $4=usage-hourly.jsonl content (or "") $5=share.json content (or "")
  local name="$1" seed="$2" payload="$3" usage="${4:-}" share="${5:-}"
  local th="$WORKDIR/harness-home-$name"
  local cols="${HARNESS_COLS:-}"
  rm -rf "$th"; mkdir -p "$th/.claude/usage"
  [ -n "$seed" ] && printf '%s' "$seed" > "$th/.claude/.pace-trend.json"
  [ -n "$usage" ] && printf '%s' "$usage" > "$th/.claude/usage/usage-hourly.jsonl"
  [ -n "$share" ] && printf '%s' "$share" > "$th/.claude/usage/share.json"
  local out
  if [ -n "$cols" ]; then
    out=$(printf '%s' "$payload" | HOME="$th" COLUMNS="$cols" bash "$SCRIPT" 2>&1 | tail -1)
  else
    out=$(printf '%s' "$payload" | HOME="$th" bash "$SCRIPT" 2>&1 | tail -1)
  fi
  printf '%-28s %s\n' "$name" "$out"
  rm -rf "$th"
}

# --- assertion machinery -------------------------------------------------
# The 38 cases above/below this block are eyeball cases: they render and are
# read. The cases at the bottom ASSERT, so a regression fails the run instead
# of quietly changing a line nobody re-reads. capture() leaves the rendered
# gauge line in $CAP (ANSI stripped) and the persisted state in $STATE.
PASSED=0; FAILED=0; CAP=""; STATE=""
capture() {  # $1=name $2=seed $3=payload $4=usage $5=share  ($6=COLUMNS)
  local name="$1" seed="$2" payload="$3" usage="${4:-}" share="${5:-}" cols="${6:-}"
  local th="$WORKDIR/harness-home-$name"
  rm -rf "$th"; mkdir -p "$th/.claude/usage"
  [ -n "$seed" ]  && printf '%s' "$seed"  > "$th/.claude/.pace-trend.json"
  [ -n "$usage" ] && printf '%s' "$usage" > "$th/.claude/usage/usage-hourly.jsonl"
  [ -n "$share" ] && printf '%s' "$share" > "$th/.claude/usage/share.json"
  CAP=$(printf '%s' "$payload" | HOME="$th" COLUMNS="${cols:-0}" bash "$SCRIPT" 2>&1 \
        | tail -1 | sed $'s/\033\\[[0-9;]*m//g')
  STATE=$(cat "$th/.claude/.pace-trend.json" 2>/dev/null)
  printf '%-34s %s\n' "$name" "$CAP"
  rm -rf "$th"
}
ok()   { PASSED=$((PASSED+1)); printf '    ok    %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf '    FAIL  %s\n       (%s)\n' "$1" "$2"; }
expect()    { if printf '%s' "$CAP" | grep -qF -- "$1"; then ok "$2"; else bad "$2" "missing: $1"; fi; }
refute()    { if printf '%s' "$CAP" | grep -qF -- "$1"; then bad "$2" "must not contain: $1"; else ok "$2"; fi; }
expect_re() { if printf '%s' "$CAP" | grep -qE -- "$1"; then ok "$2"; else bad "$2" "no match: $1"; fi; }
refute_re() { if printf '%s' "$CAP" | grep -qE -- "$1"; then bad "$2" "must not match: $1"; else ok "$2"; fi; }
# $1=jq filter over the persisted state, must evaluate true
expect_state() { if [ "$(printf '%s' "$STATE" | jq -r "$1" 2>/dev/null)" = "true" ]
                 then ok "$2"; else bad "$2" "state check false: $1 :: $(printf '%s' "$STATE" | jq -c '.gauge.seven_day.allowance' 2>/dev/null)"; fi; }

base_payload() {
  # $1 = rate_limits object as a JSON string fragment
  printf '{"model":{"display_name":"Sonnet 5"},"cwd":"%s","transcript_path":"/dev/null","session_id":"testcase00000000","rate_limits":%s}' "$WORKDIR" "$1"
}

# The premium gauge's inputs. The collector resolves WHICH family is premium,
# what it weighs and what it is called, and writes all three here; statusline.sh
# reads them rather than re-deriving, so these fixtures are the whole contract.
SHARE_PREM='{"premium_share_of_7d":{"family":"fable","label":"fable","weight":2,"share":0.15,"allowance":0.5},"generated_at_epoch":'"$NOW"'}'
# No premium family on this install at all: not a zero, an absence.
SHARE_NONE='{"premium_share_of_7d":null,"generated_at_epoch":'"$NOW"'}'
# A share.json written before the schema was generalised. It only ever
# described one family, so it has to keep working, read as exactly that.
SHARE_OLD='{"fable_share_of_7d":{"share":0.15,"allowance":0.5},"generated_at_epoch":'"$NOW"'}'

# Seeds a non-provisional payload history (5 identical raw samples => stable
# median, agrees with itself so calibration never gets vetoed by the 3pt
# agreement gate) for whichever of five_hour/seven_day is given, plus a
# persisted allowance for each and shared resets_at values.
seed_state() {
  # $1=5h pct or "" $2=5h allowance or "" $3=7d pct or "" $4=7d allowance or ""
  # $5=resets_at_7d (default now+3d) $6=resets_at_5h (default now+1h)
  local p5="$1" a5="$2" p7="$3" a7="$4"
  local r7="${5:-$((NOW+3*86400))}" r5="${6:-$((NOW+3600))}"
  python3 - "$p5" "$a5" "$p7" "$a7" "$r7" "$r5" << 'PYEOF'
import sys, json
p5,a5,p7,a7,r7,r5 = sys.argv[1:7]
gauge = {}
raw = {"five_hour": [], "seven_day": []}
if p5:
    raw["five_hour"] = [float(p5)]*5
    gauge["five_hour"] = {"resets_at": int(r5)}
    if a5: gauge["five_hour"]["allowance"] = float(a5)
if p7:
    raw["seven_day"] = [float(p7)]*5
    gauge["seven_day"] = {"resets_at": int(r7)}
    if a7: gauge["seven_day"]["allowance"] = float(a7)
print(json.dumps({"raw": raw, "gauge": gauge}))
PYEOF
}

ALLOW=1000000000   # 1e9 tokens == 100% of a window, for round-number arithmetic

echo "--- synthetic scenarios ---"

# 1. fresh window: nothing persisted, no usage-hourly.jsonl, windows just reset.
run_case "1-fresh-window" "" \
  "$(base_payload '{"seven_day":{"used_percentage":2,"resets_at":'"$((NOW+604800))"'},"five_hour":{"used_percentage":1,"resets_at":'"$((NOW+18000))"'}}')"

# 2. 7d mid-window, comfortably UNDER pace (tokens=400M/1e9=40%, 3 complete
#    hours at 5M/hr => actual_rate 0.5pt/hr; required=(100-40)/72h=0.833 =>
#    ratio ~0.60 green).
run_case "2-under-pace" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 385000000
     usage_row "$(hours_ago 3)" 5000000
     usage_row "$(hours_ago 2)" 5000000
     usage_row "$(hours_ago 1)" 5000000)"

# 3. 7d mid-window, moderately OVER pace (ratio ~5.27, red).
run_case "3-over-pace" \
  "$(seed_state "" "" 59 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":59,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 500000000
     usage_row "$(hours_ago 3)" 30000000
     usage_row "$(hours_ago 2)" 30000000
     usage_row "$(hours_ago 1)" 30000000)"

# 4. usage-hourly.jsonl exists but only 1 complete hour -- below the
#    >=2-complete-hours floor for the 7d/fable "hours" rate mode.
run_case "4-ratio-unmeasurable" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 395000000
     usage_row "$(hours_ago 1)" 5000000)"

# 5. exactly 1 prior payload sample (5h): below the 3-sample floor, must show
#    "prov" -- no usage-hourly.jsonl seeded either (no calibration yet).
run_case "5-one-sample" \
  '{"raw":{"five_hour":[18]}}' \
  "$(base_payload '{"five_hour":{"used_percentage":19,"resets_at":'"$((NOW+3600))"'}}')"

# 6. 7d used already at 100%, still climbing: required_rate hits 0
#    (div-by-zero guard); burn_ratio caps at 9.99x, lands_at at 999.
run_case "6-used-at-100" \
  "$(seed_state "" "" 100 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":100,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 850000000
     usage_row "$(hours_ago 3)" 50000000
     usage_row "$(hours_ago 2)" 50000000
     usage_row "$(hours_ago 1)" 50000000)"

# 7. resets_at missing entirely (7d): hours_to_reset/ratio/lands all null,
#    bar still renders (no marker), no crash.
run_case "7-resets-missing" \
  '{"raw":{"seven_day":[40,40,40,40,40]}}' \
  "$(base_payload '{"seven_day":{"used_percentage":40}}')"

# 8. resets_at already in the past (7d): hours_to_reset negative, must not
#    divide by a negative/zero and must not crash.
run_case "8-resets-in-past" \
  '{"raw":{"seven_day":[40,40,40,40,40]}}' \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW-3600))"'}}')"

# 10. flat real spend (tokens cannot go backward like a percentage reading
#     can -- 2 complete hours with ZERO tokens => actual_rate exactly 0).
#     burn_ratio must render 0.00x, lands_at must equal used_pct (45).
run_case "10-flat-rate" \
  "$(seed_state "" "" 45 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":45,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 450000000
     usage_row "$(hours_ago 2)" 0
     usage_row "$(hours_ago 1)" 0)"

# 9. degenerate payload: {} has no cwd/rate_limits/anything. Must render,
#    never a jq error (that error would land straight in your prompt).
th="$WORKDIR/harness-home-9-degenerate"
rm -rf "$th"; mkdir -p "$th/.claude/usage"
out=$(printf '{}' | HOME="$th" bash "$SCRIPT" 2>&1)
rc=$?
printf '%-28s exit=%s :: %s\n' "9-degenerate-payload" "$rc" "$(echo "$out" | tr '\n' '|')"
rm -rf "$th"

# 11. no usage-hourly.jsonl at all, but an allowance WAS already persisted.
#     Must fall back cleanly to the payload median, no crash on null tokens
#     against a non-null allowance.
run_case "11-no-usage-file" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'}}')"

# 12. window-boundary crossing (7d): one row 1h BEFORE window_start (168h
#     before resets_at) carrying a huge token count that must be EXCLUDED,
#     one row inside the window carrying the real count.
run_case "12-window-boundary" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3600))"'}}')" \
  "$(usage_row "$(hours_ago 169)" 999000000
     usage_row "$(hours_ago 40)" 400000000)"

# 13. partial current hour (7d): a huge row dated THIS hour must count
#     toward tokens_in_window (real spend so far) but NOT toward
#     actual_rate's by_hour (excluded, not scaled) -- compare against
#     case 2's 0.60x/76% to confirm the rate is unaffected by the surge.
run_case "13-partial-current-hour" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 385000000
     usage_row "$(hours_ago 3)" 5000000
     usage_row "$(hours_ago 2)" 5000000
     usage_row "$(hours_ago 1)" 5000000
     usage_row "$CUR_HOUR" 200000000)"

# 14. token/payload divergence over the 5pt marker threshold (7d): allowance
#     predicts 50%, payload (non-provisional) says 40% -- a 10pt gap. Must
#     render "!" and must NOT recalibrate (agreement gate is 3pt).
run_case "14-divergence-marker" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 500000000)"

# 15. 5h window with a partial hour DOMINATING it: window is only 5h wide,
#     ~50min elapsed, almost all of it in the still-forming current hour.
#     actual_rate uses "elapsed" mode (real tokens / real elapsed hours),
#     never the 7d "6 complete hours" span (6h is longer than the whole 5h
#     window). Needs >=20min elapsed; this case has ~50min, so a rate
#     should appear, honestly averaged over that real elapsed time.
# resets_at = now + (5h - 50min): ~50 minutes elapsed into the window, and
# the only usage-hourly.jsonl row is dated THIS (still-forming) hour --
# i.e. the current partial hour IS effectively the whole window so far.
R5_50MIN=$((NOW + 5*3600 - 50*60))
run_case "15-5h-partial-hour-dominant" \
  "$(seed_state 12 "$ALLOW" "" "" "" "$R5_50MIN")" \
  "$(base_payload '{"five_hour":{"used_percentage":12,"resets_at":'"$R5_50MIN"'}}')" \
  "$(usage_row "$CUR_HOUR" 120000000)"

# 16. fable at zero spend: fable's derived allowance exists (via a
#     calibrated 7d allowance) but no fable-family rows at all in the tail
#     -- median must be 0%, actual_rate/ratio/lands must be honestly "-",
#     never fabricated, and the bar must be neutral (no ratio => no green).
run_case "16-fable-zero-spend" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 400000000)" \
  "$SHARE_PREM"

# 17. fable OVER its allowance: fable-family tokens alone exceed the
#     derived fable allowance (7d allowance * 0.5 share) -- median must
#     render >100%, ratio must be red (>1.1), lands must be red (>100%).
run_case "17-fable-over-allowance" \
  "$(seed_state "" "" 40 "$ALLOW")" \
  "$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 100000000
     usage_row "$(hours_ago 40)" 400000000 fable
     usage_row "$(hours_ago 3)" 50000000 fable
     usage_row "$(hours_ago 2)" 50000000 fable
     usage_row "$(hours_ago 1)" 50000000 fable)" \
  "$SHARE_PREM"

# 19. position EXACTLY at the pace line (used%==pace%==50%, position=1.00):
#     per brief 1.00 falls in the 1.00-1.15 band -> amber, not green.
R7_HALF=$((NOW + 84*3600))
run_case "19-position-at-line" \
  "$(seed_state "" "" 50 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":50,"resets_at":'"$R7_HALF"'}}')"

# 20. position just OVER the line (used=55% vs pace=50% -> 1.10 -> amber).
run_case "20-position-just-over" \
  "$(seed_state "" "" 55 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":55,"resets_at":'"$R7_HALF"'}}')"

# 21. position WELL over the line (used=70% vs pace=50% -> 1.40 -> red).
run_case "21-position-well-over" \
  "$(seed_state "" "" 70 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":70,"resets_at":'"$R7_HALF"'}}')"

# 22. start-of-window, pace% ~0 (division would blow up): nothing spent
#     either -> must render green, not a huge quotient.
R7_FRESH=$((NOW + 168*3600 - 60))
run_case "22-start-of-window-near-zero-pace" \
  "$(seed_state "" "" 0 "$ALLOW" "$R7_FRESH")" \
  "$(base_payload '{"seven_day":{"used_percentage":0,"resets_at":'"$R7_FRESH"'}}')"

# 23. negative delta (well BEHIND the pace line): used=20% vs pace=50%
#     (same R7_HALF marker as cases 19-21) -> delta -30.
run_case "23-delta-negative" \
  "$(seed_state "" "" 20 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":20,"resets_at":'"$R7_HALF"'}}')"

# 24. delta of exactly zero (used%==pace%==50%, same marker as case 19):
#     must render bare "0", never "+0"/"-0".
run_case "24-delta-zero" \
  "$(seed_state "" "" 50 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":50,"resets_at":'"$R7_HALF"'}}')"

# 25. unknown-position delta (no resets_at at all, same as case 7): must
#     render "-" dim, never "+0" -- "no data" is not "on the line".
run_case "25-delta-unknown-position" \
  '{"raw":{"seven_day":[40,40,40,40,40]}}' \
  "$(base_payload '{"seven_day":{"used_percentage":40}}')"

# 26. catch-up parenthetical, well under 48h: delta +6 -> 6/0.5952=10.08h
#     -> "(10h)". used=56% vs pace=50% (R7_HALF).
run_case "26-catchup-under-48h" \
  "$(seed_state "" "" 56 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":56,"resets_at":'"$R7_HALF"'}}')"

# 27. catch-up parenthetical, at/over 48h -> day formatting: delta +50 ->
#     50/0.5952=84.0h -> ">=48" -> "(3.5d)". used=100% vs pace=50%.
run_case "27-catchup-over-48h-days" \
  "$(seed_state "" "" 100 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":100,"resets_at":'"$R7_HALF"'}}')"

# 28. negative delta -> NO catch-up parenthetical (nothing to catch up).
run_case "28-catchup-negative-none" \
  "$(seed_state "" "" 20 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":20,"resets_at":'"$R7_HALF"'}}')"

# 29. narrow-width path: catch-up drops BEFORE the bar. A lone 7d gauge
#     (no 5h/fable) with a positive catch-up: full width shows the bar AND
#     "(Nh)"; a width that fits without the parenthetical but not with it
#     must show the bar with no parenthetical, never the reverse (bar gone,
#     parenthetical still showing).
run_case "29a-catchup-drops-before-bar-full" \
  "$(seed_state "" "" 56 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":56,"resets_at":'"$R7_HALF"'}}')"
HARNESS_COLS=45 run_case "29b-catchup-drops-before-bar-narrow" \
  "$(seed_state "" "" 56 "$ALLOW" "$R7_HALF")" \
  "$(base_payload '{"seven_day":{"used_percentage":56,"resets_at":'"$R7_HALF"'}}')"
unset HARNESS_COLS

# 30. 5h catch-up in MINUTES format: 5h pts/hr=20, delta=+5 -> 5/20=0.25h
#     -> "(15m)". used=55% vs pace=50% (2.5h elapsed of the 5h window).
R5_HALF=$((NOW + 5*3600/2))
run_case "30-5h-catchup-minutes" \
  "$(seed_state 55 "$ALLOW" "" "" "" "$R5_HALF")" \
  "$(base_payload '{"five_hour":{"used_percentage":55,"resets_at":'"$R5_HALF"'}}')"

# 31. sub-1h 5h catch-up, a second data point close to the m/h boundary:
#     delta=+15 -> 15/20=0.75h -> "(45m)", confirms the <1h branch holds
#     up to just under the boundary, not just at a round 15-minute value.
run_case "31-5h-catchup-minutes-near-boundary" \
  "$(seed_state 65 "$ALLOW" "" "" "" "$R5_HALF")" \
  "$(base_payload '{"five_hour":{"used_percentage":65,"resets_at":'"$R5_HALF"'}}')"

# 32. window just reset, near-zero used%: must NOT calibrate an allowance
#     at all (floor=20) -- allowance stays null/unchanged, no 5.8x-style
#     collapse can start from here. used=2% is below the 20pt floor.
run_case "32-near-zero-no-calibration" \
  '{"raw":{"seven_day":[2,2,2,2,2]},"gauge":{"seven_day":{"resets_at":'"$((NOW+604800))"'}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":2,"resets_at":'"$((NOW+604800))"'}}')"

# 33. a reading that implies a >20% allowance jump must be bounded. prev
#     allowance=1e9 at 50% used; usage-hourly implies tokens_in_window=1e9,
#     i.e. predicted_pct=100% against the OLD allowance -- a 50pt
#     disagreement with the live payload's 50%. The payload here is STABLE
#     (5 identical samples), so the 3pt agreement gate is deliberately
#     skipped and the step bound is what holds; case 45 asserts the bound.
run_case "33-large-jump-bounded" \
  '{"raw":{"seven_day":[50,50,50,50,50]},"gauge":{"seven_day":{"resets_at":'"$((NOW+3*86400))"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":50,"resets_at":'"$((NOW+3*86400))"'}}')" \
  "$(usage_row "$(hours_ago 40)" 1000000000)"

# 34. an allowance corrupted down to a fraction of its real size,
#     producing a >150% derived percentage: must fall back to the payload
#     median with the divergence marker, never show the false number, and
#     must not compute a rate off the untrustworthy allowance either.
run_case "34-corrupted-allowance-sanity-clamp" \
  '{"raw":{"five_hour":[19,1,19,1,19]},"gauge":{"five_hour":{"resets_at":'"$((NOW+3600))"',"allowance":470000000.0}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":19,"resets_at":'"$((NOW+3600))"'}}')" \
  "$(usage_row "$CUR_HOUR" 800000000)"

# 35. resets_at in the past (the real 40.9h-stale incident): must discard,
#     not position against it -- no marker, no delta, no catch-up.
run_case "35-resets-at-in-past" \
  '{"raw":{"five_hour":[19,19,19,19,19]},"gauge":{"five_hour":{"resets_at":'"$((NOW-40*3600-3240))"'}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":19}}')"

# 36. resets_at further ahead than the window can ever be (5h window,
#     resets_at=now+10h): equally impossible, must discard the same way.
run_case "36-resets-at-too-far-ahead" \
  "" \
  "$(base_payload '{"five_hour":{"used_percentage":19,"resets_at":'"$((NOW+10*3600))"'}}')"

# 37. resets_at absent from the live payload, but a VALID persisted one
#     exists: must use it (this is what a real fallback should do).
run_case "37-resets-at-absent-valid-persisted" \
  '{"raw":{"five_hour":[19,19,19,19,19]},"gauge":{"five_hour":{"resets_at":'"$((NOW+3600))"'}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":19}}')"

# 38. resets_at absent from the live payload AND the persisted one is
#     invalid (stale): must degrade to neutral, never invent a marker.
run_case "38-resets-at-absent-invalid-persisted" \
  '{"raw":{"five_hour":[19,19,19,19,19]},"gauge":{"five_hour":{"resets_at":'"$((NOW-3600))"'}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":19}}')"

echo
echo "--- asserted cases: payload-vs-token source, delta unit, signed catch-up ---"

R7_3D=$((NOW+3*86400))          # 7d pace marker = 57.14% (3 days left of 7)
R7_HALF=$((NOW + 84*3600))      # 7d pace marker = 50.00%

# 39. PAYLOAD STABLE => the payload is the source of truth. Seeded raw
#     history is 5 identical 62s (spread 0), so the concurrent-process
#     rotation is provably not happening and used_percentage is the
#     server's own figure. tokens (450M against a 1e9 allowance) would
#     derive ~45-46%; the payload's 62% must win, and the divergence "!"
#     must fire because the two disagree by 17 points. This is the live
#     2026-08-29 bug: 7d read 45% while the truth was 62%.
capture "39-payload-stable-trusted" \
  '{"raw":{"seven_day":[62,62,62,62,62]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":62,"resets_at":'"$R7_3D"'}}')" \
  "$(usage_row "$(hours_ago 40)" 450000000)"
expect "62.00%" "39: stable payload is displayed, not the token derivation"
refute "45.00%" "39: the stale token-derived 45% is NOT displayed"
refute "46.2"   "39: nor the token derivation after this refresh's recalibration"
expect "!"      "39: divergence marker still fires (now flagging the token side)"

# 40. PAYLOAD ROTATING => fall back to the token derivation. Seeded raw
#     history spans 18 points (the 4-value concurrent-cache rotation the
#     README documents), so no single payload reading can be trusted and
#     the derived 45.00% (450M / a 1e9 allowance the rotation is NOT
#     allowed to move) must be shown instead of the 62 payload median.
capture "40-payload-rotating-derived" \
  '{"raw":{"seven_day":[60,62,64,78,60]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":60,"resets_at":'"$R7_3D"'}}')" \
  "$(usage_row "$(hours_ago 40)" 450000000)"
expect "45.00%" "40: rotating payload => token derivation is displayed"
refute "62.00%" "40: the rotating payload median is NOT displayed"

# 41. stability threshold, both sides of it. Seeded arrays get the live
#     sample appended, so the array actually tested is seed+live trimmed
#     to 5. 41a spans exactly 3 (stable, payload wins); 41b spans 4
#     (rotating, tokens win). Same tokens, same allowance, both cases.
capture "41a-spread-3-stable" \
  '{"raw":{"seven_day":[60,61,62,63]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":63,"resets_at":'"$R7_3D"'}}')" \
  "$(usage_row "$(hours_ago 40)" 450000000)"
expect "62.00%" "41a: spread of 3 counts as stable => payload"
capture "41b-spread-4-rotating" \
  '{"raw":{"seven_day":[59,61,62,63]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":63,"resets_at":'"$R7_3D"'}}')" \
  "$(usage_row "$(hours_ago 40)" 450000000)"
expect "45.00%" "41b: spread of 4 counts as rotating => tokens"
refute "62.00%" "41b: payload median not used once the spread crosses 3"

# 42. THE "%" ON THE PACE DELTA, on all three bars at once. It is points of
#     the window, and a bare "-2.46" beside a "(24m)" reads as a second
#     time figure -- it was misread as exactly that. 5h/7d/premium all route
#     through the one delta_text, so all three must carry it.
#     Deterministic by construction: 7d pace 57.14% vs 45% used => -12.14;
#     5h pace 80% vs 19% => -61.00; premium 100M oe of a 500M derived
#     allowance = 20% vs the same 57.14% 7d pace => -37.14. Tokens are
#     chosen so the 7d allowance predicts exactly the payload (450M / 1e9
#     == 45%) and therefore does not move this refresh.
ALL3_SEED='{"raw":{"five_hour":[19,19,19,19,19],"seven_day":[45,45,45,45,45]},"gauge":{"five_hour":{"resets_at":'"$((NOW+3600))"',"allowance":1000000000.0},"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}'
ALL3_PAYLOAD="$(base_payload '{"seven_day":{"used_percentage":45,"resets_at":'"$R7_3D"'},"five_hour":{"used_percentage":19,"resets_at":'"$((NOW+3600))"'}}')"
ALL3_USAGE="$(usage_row "$(hours_ago 40)" 350000000
              usage_row "$(hours_ago 40)" 50000000 fable)"
capture "42-delta-percent-all-three" "$ALL3_SEED" "$ALL3_PAYLOAD" "$ALL3_USAGE" "$SHARE_PREM"
expect_re '5h .*-61\.0[0-9]%'  "42: 5h delta carries %"
expect_re '7d .*-12\.1[0-9]%'  "42: 7d delta carries %"
expect_re 'fable .*-37\.1[0-9]%' "42: premium delta carries %"
refute_re '[-+][0-9]+\.[0-9][0-9] ' "42: no unitless delta survives anywhere on the line"

# 43. TIME FIGURE IN BOTH DIRECTIONS, and never confusable between them.
#     Same case as 42: every gauge is behind its pace line, so every gauge
#     must show the gap in its own window-time, labelled "behind" -- the
#     direction word is the thing that stops "4h ahead" being read as
#     "4h behind". 5h: 61.0pts / 20pts-per-hour = 3.05h. 7d: 12.14 /
#     0.5952 = 20.4h. premium rides the 7d clock: 37.14 / 0.5952 = 62.4h,
#     past the 48h day-formatting boundary => 2.6d.
expect "(3h behind)"   "43: 5h negative delta renders its time, labelled"
expect "(20h behind)"  "43: 7d negative delta renders its time, labelled"
expect "(2.6d behind)" "43: premium negative delta renders its time, in days"
refute "(3h)"          "43: no bare unlabelled time survives"
refute "ahead"         "43: nothing is labelled ahead when every gauge is behind"

# 44. the positive direction still says "ahead", with the same shape --
#     the two labels must be different words, not a sign on the same one.
capture "44-positive-direction-ahead" \
  '{"raw":{"seven_day":[56,56,56,56,56]},"gauge":{"seven_day":{"resets_at":'"$R7_HALF"'}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":56,"resets_at":'"$R7_HALF"'}}')"
expect "+6.00% (10h ahead)" "44: positive delta => % on the delta and a labelled time"
refute "behind"            "44: an ahead gauge is never labelled behind"

# 45. TRAP: the stability gate must NOT reopen the allowance-collapse path.
#     A stable payload skips the 3pt agreement gate, so the +-20% STEP
#     BOUND is now the last thing standing between a bad tokens/payload
#     pair and a 5.8x-style move. Sized so the bound is what actually
#     binds: the 90/10 blend alone caps a step at 10% of the gap, so a
#     jump only reaches the clamp past 3x. 5e9 tokens against a 1e9
#     allowance at a stable 50% implies 10e9 -- the blend would still land
#     on 1.9e9, and the clamp must pull that back inside +-20%.
#     (Verified by deliberate break: removing clamp_step fails this.)
capture "45-step-bound-holds-when-stable" \
  '{"raw":{"seven_day":[50,50,50,50,50]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":50,"resets_at":'"$R7_3D"'}}')" \
  "$(usage_row "$(hours_ago 40)" 5000000000)"
expect_state '(.gauge.seven_day.allowance >= 800000000) and (.gauge.seven_day.allowance <= 1200000000)' \
  "45: a 10x-implied jump is still clamped to +-20%"

# 46. TRAP: the 20pt calibration floor must also survive the stability
#     gate. A rock-steady 2% payload is exactly where tokens/used_fraction
#     is ill-conditioned (the 799% incident). Stable or not, the allowance
#     must not move at all down there.
capture "46-floor-holds-when-stable" \
  '{"raw":{"seven_day":[2,2,2,2,2]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":2,"resets_at":'"$R7_3D"'}}')" \
  "$(usage_row "$(hours_ago 40)" 30000000)"
expect_state '.gauge.seven_day.allowance == 1000000000' \
  "46: no recalibration below the 20pt floor, however stable the payload"

# 47. 5h with a stable payload and NO allowance ever calibrated (the live
#     state: 5h sits under the 20pt floor most of every cycle). The
#     percentage must now come through from the payload -- but the RATE
#     still cannot: actual_rate needs an allowance to turn tokens into
#     points. "-" is the correct answer there, not a guess.
capture "47-5h-stable-no-allowance" \
  '{"raw":{"five_hour":[2,2,2,2,2]},"gauge":{"five_hour":{"resets_at":'"$((NOW+3600))"'}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":2,"resets_at":'"$((NOW+3600))"'}}')" \
  "$(usage_row "$(hours_ago 2)" 5000000)"
expect "2.00%"     "47: 5h percentage comes from the stable payload"
expect "lands –"   "47: 5h rate stays unmeasurable without an allowance"

# 58. NO usage source at all (the zero-dependency install). The rate half of
#     every gauge must be OMITTED, not rendered as a "-" that can never fill
#     in -- while the position half (bar, used%, delta, catch-up) still works,
#     because it needs nothing but the payload and the clock.
capture "58-no-usage-source-omits-rate" \
  '{"raw":{"seven_day":[45,45,45,45,45]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"'}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":45,"resets_at":'"$R7_3D"'}}')"
expect "45.00%"    "58: used% still renders with no usage source"
expect "behind"    "58: the pace delta and its time still render"
refute "lands"     "58: no \"lands\" placeholder without a usage source"
refute "–"         "58: no dangling en-dash without a usage source"

echo
echo "--- asserted cases: premium measured-zero, 5h allowance lifecycle ---"

# Tokens are sized so the 7d allowance predicts the payload EXACTLY
# (450M oe / 1e9 == 45%), so calibration accepts and lands back on 1e9 --
# which makes the premium family's derived allowance exactly 0.5e9 and its
# used% exactly 20.00. Recent hours 1/2/3 give 7d three complete observed
# hours; the premium spend sits 40h back, so its OWN by_hour is empty.
ZERO_SEED='{"raw":{"seven_day":[45,45,45,45,45]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}'
ZERO_PAYLOAD="$(base_payload '{"seven_day":{"used_percentage":45,"resets_at":'"$R7_3D"'}}')"
ZERO_USAGE="$(usage_row "$(hours_ago 40)" 320000000
              usage_row "$(hours_ago 40)" 50000000 fable
              usage_row "$(hours_ago 3)" 10000000
              usage_row "$(hours_ago 2)" 10000000
              usage_row "$(hours_ago 1)" 10000000)"

# 48. PREMIUM MEASURED ZERO. The premium family has no rows in the trailing
#     complete hours, but 7d has three -- so the usage file WAS read for those
#     hours and the family's absence from them is a measurement of zero, not
#     missing data. Rate 0 => "spend nothing more, land where you are".
capture "48-premium-measured-zero" "$ZERO_SEED" "$ZERO_PAYLOAD" "$ZERO_USAGE" "$SHARE_PREM"
expect_re 'fable .*20\.00%.*0\.00×.*lands 20%' "48: idle premium reads a measured zero rate, lands where it is"
expect_state '.gauge.premium.actual_rate == 0'  "48: premium actual_rate is 0, not null"
expect_state '.gauge.premium.lands_at == .gauge.premium.median' "48: lands == used% at rate 0"

# 49. THE OTHER SIDE OF IT: genuinely absent data must STILL read "–".
#     Same seed, same payload, no usage-hourly.jsonl at all -- so 7d has no
#     complete observed hours either, and there is nothing to measure. This
#     is the case case 48 must not swallow: "no file" is not "zero spend".
capture "49-absent-data-still-dash" "$ZERO_SEED" "$ZERO_PAYLOAD" "" "$SHARE_PREM"
expect_re 'fable .*–  lands –' "49: no usage file => premium rate is unknown, not zero"
expect_state '.gauge.premium.actual_rate == null' "49: premium actual_rate is null with no data"
expect_state '.gauge.seven_day.actual_rate == null' "49: 7d likewise has no measurable rate"

# 50. 5h OPPORTUNISTIC CALIBRATION. 5h clears the 20pt floor only during a
#     burst; when it does, the allowance must be learned and STAMPED, and
#     the gauge must immediately gain a rate. 250M oe against a stable 25%
#     => a 1e9 allowance, exactly.
R5_4H_IN=$((NOW+3600))          # 5h window, 4h elapsed
capture "50-5h-opportunistic-calibration" \
  '{"raw":{"five_hour":[25,25,25,25,25]},"gauge":{"five_hour":{"resets_at":'"$R5_4H_IN"'}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":25,"resets_at":'"$R5_4H_IN"'}}')" \
  "$(usage_row "$(hours_ago 3)" 250000000)"
expect_state '.gauge.five_hour.allowance == 1000000000' "50: 5h learns its allowance above the floor"
expect_state '.gauge.five_hour.allowance_at != null'    "50: and stamps its vintage"
expect_re '5h .*lands [0-9]+%'  "50: 5h gains a rate the moment it has an allowance"

# 51. 5h REUSE ACROSS A WINDOW RESET. The 5h budget is a fixed plan
#     quantity: it does not change when the window rolls. So a value learned
#     yesterday must survive into a brand-new window that sits far below the
#     floor -- carried forward untouched, NOT relearned from nothing. Window
#     is 1h old, 30M spent => 3.00 pt/h, 4h to run => lands 15%.
R5_FRESH=$((NOW+18000-3600))    # 5h window, 1h elapsed
A5_YESTERDAY=$((NOW-86400))
capture "51-5h-allowance-survives-reset" \
  '{"raw":{"five_hour":[3,3,3,3,3]},"gauge":{"five_hour":{"resets_at":'"$R5_FRESH"',"allowance":1000000000.0,"allowance_at":'"$A5_YESTERDAY"',"allowance_history":[{"t":'"$A5_YESTERDAY"',"allowance":1000000000.0}]}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":3,"resets_at":'"$R5_FRESH"'}}')" \
  "$(usage_row "$CUR_HOUR" 30000000)"
expect_state '.gauge.five_hour.allowance == 1000000000' "51: allowance survives the reset intact"
expect_state '.gauge.five_hour.allowance_at == '"$A5_YESTERDAY" "51: and keeps its ORIGINAL vintage (no false restamp)"
expect "lands 15%" "51: a reused allowance gives the new window a real projection"

# 52. 5h STALE-ALLOWANCE REJECTION. Same case, same arithmetic -- but the
#     allowance was last measured 8 days ago, past the one-7d-window
#     horizon. A months-stale allowance is a lie, so it is dropped from the
#     arithmetic AND from the state, and the gauge degrades to "–". The
#     percentage still comes through from the payload: losing the rate must
#     not cost the level.
A5_STALE=$((NOW-8*86400))
capture "52-5h-stale-allowance-rejected" \
  '{"raw":{"five_hour":[3,3,3,3,3]},"gauge":{"five_hour":{"resets_at":'"$R5_FRESH"',"allowance":1000000000.0,"allowance_at":'"$A5_STALE"',"allowance_history":[{"t":'"$A5_STALE"',"allowance":1000000000.0}]}}}' \
  "$(base_payload '{"five_hour":{"used_percentage":3,"resets_at":'"$R5_FRESH"'}}')" \
  "$(usage_row "$CUR_HOUR" 30000000)"
expect_state '.gauge.five_hour.allowance == null' "52: an allowance past the horizon is dropped, not reused"
expect_re '5h .*–  lands –' "52: and the rate degrades to unmeasurable"
expect "3.00%"              "52: the payload level survives the loss of the rate"
refute "lands 15%"          "52: the stale-allowance projection is NOT shown"

echo
echo "--- asserted cases: sub-point interpolation, current-hour rate ---"

# The payload is an integer, and one point of a 7d window is worth far more
# than even a full-tilt hour of work, so a truthful payload alone cannot
# move for hours. These four cases pin
# the interpolation that restores resolution without letting it run away.
# All four seed a payload_anchor directly so the arithmetic is exact.
INTERP_PAYLOAD="$(base_payload '{"seven_day":{"used_percentage":63,"resets_at":'"$R7_3D"'}}')"
interp_seed() {  # $1=anchor value $2=anchor tokens
  printf '{"raw":{"seven_day":[63,63,63,63,63]},"gauge":{"seven_day":{"resets_at":%s,"allowance":1000000000.0,"allowance_at":%s,"payload_anchor":{"value":%s,"tokens":%s,"t":%s}}}}' \
    "$R7_3D" "$((NOW-3600))" "$1" "$2" "$((NOW-3600))"
}
# 635M oe against a stable 63 keeps the allowance within a whisper of 1e9
# (the 90/10 blend lands on 1.0008e9), so a 5M gain reads as 0.50 points.
INTERP_USAGE="$(usage_row "$(hours_ago 40)" 635000000)"

# 53. INTERPOLATION ADVANCES between payload ticks: the payload has said 63
#     since 630M, 635M have now accrued, so the honest figure is 63.50 --
#     the level from the server, the movement from local tokens.
capture "53-interpolation-advances" "$(interp_seed 63 630000000)" "$INTERP_PAYLOAD" "$INTERP_USAGE"
expect "63.50%" "53: used% moves between payload ticks"
refute "63.00%" "53: it does not sit frozen on the payload integer"

# 54. SNAP WITH NO DOUBLE COUNT when the payload does tick. The anchor still
#     says 62; the payload now says 63. The display must land exactly on 63
#     -- not 63 plus the tokens that were already inside the tick -- and the
#     baseline must move to the current count so the next interpolation
#     starts from zero.
capture "54-tick-snaps-no-double-count" "$(interp_seed 62 500000000)" "$INTERP_PAYLOAD" "$INTERP_USAGE"
expect "63.00%" "54: a payload tick snaps cleanly onto the new integer"
expect_state '.gauge.seven_day.payload_anchor.value == 63' "54: the anchor follows the tick"
expect_state '.gauge.seven_day.payload_anchor.tokens == 635000000' \
  "54: the baseline resets to the current count -- no double count next refresh"

# 55. CAPPED WHEN THE PAYLOAD IS STUCK. 535M have accrued since the anchor,
#     which is over 53 points; if the payload has not ticked in that time
#     something is wrong with one of the two sources. Interpolation is
#     capped at one point -- the payload's own resolution, and the edge of
#     what it can honestly claim -- so a stuck payload can never become an
#     unbounded wrong number.
capture "55-interpolation-capped" "$(interp_seed 63 100000000)" "$INTERP_PAYLOAD" "$INTERP_USAGE"
expect "64.00%" "55: interpolation is capped one point ahead of the payload"
refute_re '(6[5-9]|[7-9][0-9]|1[0-9][0-9])\.[0-9][0-9]%' "55: it never runs away from the payload"

# 56. DEGRADES TO THE INTEGER with no token source. Same anchor, same
#     allowance, but no usage-hourly.jsonl: with nothing to interpolate FROM
#     the answer is the payload's own figure, not an extrapolation of the
#     last known rate.
capture "56-no-tokens-bare-integer" "$(interp_seed 63 100000000)" "$INTERP_PAYLOAD" ""
expect "63.00%" "56: no token source => the bare payload integer"

# 57. CURRENT PARTIAL HOUR: counted immediately, weighted so it cannot
#     spike. Two complete hours at 10M, plus a 100M burst in the still-
#     filling hour. Rate = (20M + 100M) / 1e9 * 100 / (2 + w) where w is the
#     elapsed fraction of the current hour FLOORED AT 1/3 -- so the answer
#     is pinned to 12/(2+w) and cannot be either 0.86 (current hour dropped)
#     or 6.0 (current hour divided by its own two minutes). The anchor is
#     seeded at the exact token total so used% stays a clean 45.00.
#     The expected weight is read off the wall clock, which can roll into a
#     new hour mid-case, so it is sampled BOTH sides of the capture and the
#     rate has to match one of them -- sharp, and never flaky.
CW_BEFORE=$(python3 -c "import time;f=(time.time()%3600)/3600;print(max(f,1.0/3.0))")
capture "57-current-hour-weighted" \
  '{"raw":{"seven_day":[45,45,45,45,45]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0,"allowance_at":'"$((NOW-3600))"',"payload_anchor":{"value":45,"tokens":450000000,"t":'"$((NOW-3600))"'}}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":45,"resets_at":'"$R7_3D"'}}')" \
  "$(usage_row "$(hours_ago 40)" 330000000
     usage_row "$(hours_ago 2)" 10000000
     usage_row "$(hours_ago 1)" 10000000
     usage_row "$CUR_HOUR" 100000000)"
CW_AFTER=$(python3 -c "import time;f=(time.time()%3600)/3600;print(max(f,1.0/3.0))")
RATE_A=$(python3 -c "print(12.0/(2+$CW_BEFORE))")
RATE_B=$(python3 -c "print(12.0/(2+$CW_AFTER))")
expect_state '(.gauge.seven_day.actual_rate) as $x
              | ['"$RATE_A"', '"$RATE_B"'] | map(((($x - .) | fabs) / .) <= 0.02) | any' \
  "57: current-hour spend counts, at exactly the floored elapsed weight"
# Clock-independent ceiling: 12 points over (2 complete hours + the 1/3 h
# floor) is the largest rate the floored formula can ever produce here.
# Dividing the burst by its own two minutes would read up to 6.0.
expect_state '.gauge.seven_day.actual_rate <= 5.1429 and .gauge.seven_day.actual_rate >= 4.0' \
  "57: a two-minute burst can never be divided by two minutes"

echo
echo "--- asserted cases: which family is premium, and when it is not rendered ---"

# 59. NO PREMIUM FAMILY => NO GAUGE. The collector writes a null premium block
#     when the install has never run a family that costs more than baseline.
#     That is an ABSENCE, not a zero, and the one thing it must never do is
#     render a confident 0.00% bar with a pace delta beside it -- which reads
#     as "you are under-using something", a measurement nobody took.
capture "59-no-premium-family" "$ZERO_SEED" "$ZERO_PAYLOAD" "$ZERO_USAGE" "$SHARE_NONE"
refute_re '(fable|fbl|prm|premium)' "59: no premium family => no third segment at all"
refute_re '0\.00%'                  "59: and no zero percentage pretending to be one"
refute_re '▏[^▕]*▕'                 "59: exactly one gauge bar on the line, not two"
expect_re '7d .*45\.00%'            "59: the 7d gauge is untouched by the absence"
expect_state '.gauge.premium.median == null' "59: nothing is claimed in the state file either"

# 60. OLD-SCHEMA share.json. A file written before the key was generalised
#     described exactly one family, weighted 2x, so it is read as exactly that
#     and keeps working until the collector rewrites it. Same arithmetic as 48.
capture "60-old-schema-share" "$ZERO_SEED" "$ZERO_PAYLOAD" "$ZERO_USAGE" "$SHARE_OLD"
expect_re 'fable .*20\.00%'  "60: an old-schema share.json still renders the gauge"
expect_state '.gauge.premium.weight == 2' "60: and is read at the weight it was written with"

# 61. A COMPLETELY DIFFERENT FAMILY. Nothing in either script is tied to one
#     model name: family, weight and on-screen label all come from share.json.
#     30M raw at weight 3 = 90M oe against a 0.5e9 derived allowance => 18.00%.
#     Every case in this group sizes the payload so the seeded 1e9 allowance
#     predicts it EXACTLY, which keeps recalibration out of the arithmetic --
#     otherwise changing the weight moves the 7d allowance too and the numbers
#     stop being round for reasons that have nothing to do with the weight.
OTHER_SHARE='{"premium_share_of_7d":{"family":"gpt5","label":"gpt5","weight":3,"share":0.2,"allowance":0.5},"generated_at_epoch":'"$NOW"'}'
OTHER_USAGE="$(usage_row "$(hours_ago 40)" 330000000
               usage_row "$(hours_ago 40)" 30000000 gpt5
               usage_row "$(hours_ago 3)" 10000000
               usage_row "$(hours_ago 2)" 10000000
               usage_row "$(hours_ago 1)" 10000000)"
# 360M non-premium oe + 30M gpt5 raw. At weight w the window totals 360+30w M.
wseed()    { printf '{"raw":{"seven_day":[%s,%s,%s,%s,%s]},"gauge":{"seven_day":{"resets_at":%s,"allowance":1000000000.0}}}' "$1" "$1" "$1" "$1" "$1" "$R7_3D"; }
wpayload() { base_payload '{"seven_day":{"used_percentage":'"$1"',"resets_at":'"$R7_3D"'}}'; }
capture "61-custom-family" "$(wseed 45)" "$(wpayload 45)" "$OTHER_USAGE" "$OTHER_SHARE"
expect_re 'gpt5 .*18\.00%'   "61: an arbitrary family renders under its own label"
refute_re '(fable|fbl)'      "61: and nothing anywhere still says fable"
expect_state '.gauge.premium.family == "gpt5"' "61: the state file names the family it measured"

# 62. THE WEIGHT IS ACTUALLY APPLIED, and it is not a constant. Identical rows,
#     identical allowance, weight 1 vs weight 2 -- the used% must double. If the
#     weight were ignored (or hardcoded) both runs would read the same.
W1_SHARE='{"premium_share_of_7d":{"family":"gpt5","label":"gpt5","weight":1,"share":0.2,"allowance":0.5},"generated_at_epoch":'"$NOW"'}'
W2_SHARE='{"premium_share_of_7d":{"family":"gpt5","label":"gpt5","weight":2,"share":0.2,"allowance":0.5},"generated_at_epoch":'"$NOW"'}'
capture "62a-weight-1" "$(wseed 39)" "$(wpayload 39)" "$OTHER_USAGE" "$W1_SHARE"
expect_re 'gpt5 .*6\.00%'  "62a: weight 1 => 30M oe of a 0.5e9 slice"
capture "62b-weight-2" "$(wseed 42)" "$(wpayload 42)" "$OTHER_USAGE" "$W2_SHARE"
expect_re 'gpt5 .*12\.00%' "62b: weight 2 => exactly double, so the weight is real"

echo
echo "--- asserted cases: the collector's own premium resolution ---"

COLLECTOR="$WORKDIR/usage-collector.sh"
SHARE_OUT=""; HOURLY_OUT=""
# Builds one synthetic transcript line per "model:hours_back:tokens" argument.
transcript() {
  local i=0 spec m rest hb tk
  for spec in "$@"; do
    m="${spec%%:*}"; rest="${spec#*:}"; hb="${rest%%:*}"; tk="${rest##*:}"
    i=$((i+1))
    printf '{"type":"assistant","timestamp":"%s","requestId":"r%s","message":{"model":"%s","id":"m%s","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":%s,"cache_read_input_tokens":0}}}\n' \
      "$(date -u -v-"$hb"H +%Y-%m-%dT%H:%M:%SZ)" "$i" "$m" "$i" "$tk"
  done
}
# Runs the REAL collector over a transcript on stdin, in a disposable HOME.
# $1 = case name, the rest = VAR=VALUE environment for the run.
run_collector() {
  local name="$1"; shift
  local ch="$WORKDIR/collector-home-$name"
  rm -rf "$ch"; mkdir -p "$ch/.claude/projects/p"
  cat > "$ch/.claude/projects/p/session.jsonl"
  env HOME="$ch" "$@" bash "$COLLECTOR" --full >/dev/null 2>&1
  SHARE_OUT=$(cat "$ch/.claude/usage/share.json" 2>/dev/null)
  HOURLY_OUT=$(cat "$ch/.claude/usage/usage-hourly.jsonl" 2>/dev/null)
  printf '%-34s %s\n' "$name" "$(printf '%s' "$SHARE_OUT" | jq -c '.premium_share_of_7d' 2>/dev/null)"
  rm -rf "$ch"
}
expect_share() {  # $1 = jq filter over share.json, must evaluate true
  if [ "$(printf '%s' "$SHARE_OUT" | jq -r "$1" 2>/dev/null)" = "true" ]
  then ok "$2"; else bad "$2" "share check false: $1 :: $SHARE_OUT"; fi
}

# 63. THE DEFAULT, ON A MACHINE THAT HAS NEVER RUN A PREMIUM FAMILY. This is
#     the reported defect: six hours of opus-only work used to produce a
#     0.00% third gauge with a pace delta and a "days behind" figure. Nothing
#     in that history costs more than the opus-equivalent baseline, so there
#     is no premium family to resolve and the block is null -- and case 59
#     above proves null means the gauge does not render.
run_collector "63-default-no-premium" < <(transcript \
  opus:6:5000000 opus:5:5000000 opus:4:5000000 \
  opus:3:5000000 opus:2:5000000 opus:1:5000000)
expect_share '.premium_share_of_7d == null' "63: opus-only history resolves no premium family"
expect_share '.generated_at_epoch != null'  "63: the rest of share.json is still written"

# 64. THE DEFAULT, WHEN A PREMIUM FAMILY IS ACTUALLY THERE. Auto-detection
#     picks the priciest COST-TABLE family present in the retained history and
#     writes family/label/weight down, so statusline.sh never has to guess.
#     20M fable at weight 2 = 40M oe; 60M sonnet = 60M oe; share = 40/100.
run_collector "64-default-autodetect" < <(transcript \
  fable:3:10000000 fable:2:10000000 sonnet:3:30000000 sonnet:2:30000000)
expect_share '.premium_share_of_7d.family == "fable"' "64: the priciest family present is detected"
expect_share '.premium_share_of_7d.weight == 2'       "64: at the cost table's weight, not 1"
expect_share '.premium_share_of_7d.label  == "fable"' "64: labelled with its own name by default"
expect_share '.premium_share_of_7d.share  == 0.4'     "64: share is weighted, 40M oe of 100M"

# 65. "NEVER USES IT" vs "ZERO THIS WINDOW" -- the distinction the null block
#     must not swallow. Selection reads the whole RETAINED file (9 days);
#     the share is measured over the trailing 7. So a family last used 8 days
#     ago is still SELECTED, and its zero is a real, measured zero.
run_collector "65-zero-in-window" < <(transcript \
  fable:192:10000000 sonnet:3:30000000 sonnet:2:30000000 sonnet:1:30000000)
expect_share '.premium_share_of_7d.family == "fable"' "65: used 8d ago => still selected"
expect_share '.premium_share_of_7d.share == 0'        "65: and this window is a measured zero"
expect_share '.premium_share_of_7d.premium_opus_equivalent_tokens == 0' "65: zero premium tokens in the 7d window"
expect_share '.premium_share_of_7d.total_opus_equivalent_tokens > 0'    "65: while the window itself is not empty"
# ... and statusline renders exactly that: a real 0.00%, distinct both from
# case 59's absent gauge and from an unknown "–". Same 450M oe window as the
# other cases, but not one premium row inside it.
NOPREM_USAGE="$(usage_row "$(hours_ago 40)" 420000000
                usage_row "$(hours_ago 3)" 10000000
                usage_row "$(hours_ago 2)" 10000000
                usage_row "$(hours_ago 1)" 10000000)"
capture "65b-zero-renders" "$(wseed 45)" "$(wpayload 45)" "$NOPREM_USAGE" \
  "$(printf '%s' "$SHARE_OUT" | jq -c '.generated_at_epoch = '"$NOW")"
expect_re 'fable .*0\.00%.*0\.00×.*lands 0%' "65b: a selected family with no spend this window is a measured zero"
refute_re 'fable .*–'  "65b: and never an unknown -- the difference case 59 must not swallow"
expect_state '.gauge.premium.median == 0' "65b: zero in the state file too, not null"

# 66. AN ENTIRELY DIFFERENT PREMIUM FAMILY, configured. The regex is matched
#     against the model id, so it can name anything -- and rows are then filed
#     under that family, which is what keeps the collector and the gauge
#     counting the same tokens.
run_collector "66-configured-family" CLAUDE_STATUSLINE_PREMIUM_FAMILY=opus < <(transcript \
  opus:3:30000000 sonnet:3:30000000 sonnet:2:40000000)
expect_share '.premium_share_of_7d.family == "opus"' "66: the configured family wins"
expect_share '.premium_share_of_7d.weight == 1'      "66: weight 1 -- opus IS the opus-equivalent unit"
expect_share '.premium_share_of_7d.share == 0.3'     "66: 30M of 100M"

# 67. CONFIGURED WEIGHT AND LABEL. The 2x was one family's cost ratio, never a
#     universal constant, so it has to be settable independently.
run_collector "67-configured-weight" \
  CLAUDE_STATUSLINE_PREMIUM_FAMILY=opus CLAUDE_STATUSLINE_PREMIUM_WEIGHT=4 \
  CLAUDE_STATUSLINE_PREMIUM_LABEL=big CLAUDE_STATUSLINE_PREMIUM_SHARE=0.25 < <(transcript \
  opus:3:25000000 sonnet:3:100000000)
expect_share '.premium_share_of_7d.weight == 4'    "67: the configured weight is used"
expect_share '.premium_share_of_7d.label == "big"' "67: and the configured label"
expect_share '.premium_share_of_7d.share == 0.5'   "67: 25M at 4x = 100M oe of 200M"
expect_share '.premium_share_of_7d.allowance == 0.25' "67: the policy fraction is carried through"

# 68. THE SILENT-WRONG-NUMBER GUARD: the collector and the gauge must count the
#     SAME rows at the SAME weight. Run the real collector, then hand statusline
#     ITS OWN outputs and check the identity median/100 * allowance == the
#     collector's own premium token total. If either side used a different
#     family or a different weight, this number is wrong and nothing else says
#     so. Every row sits in the last four hours, so both window definitions
#     (collector: now-7d, gauge: resets_at-7d) enclose all of them.
run_collector "68-consistency" CLAUDE_STATUSLINE_PREMIUM_WEIGHT=3 < <(transcript \
  fable:3:10000000 fable:2:10000000 fable:1:10000000 \
  sonnet:3:30000000 sonnet:2:30000000 sonnet:1:30000000)
expect_share '.premium_share_of_7d.premium_opus_equivalent_tokens == 90000000' \
  "68: the collector counted 30M fable at weight 3"
capture "68b-consistency" \
  '{"raw":{"seven_day":[40,50,44,52]},"gauge":{"seven_day":{"resets_at":'"$R7_3D"',"allowance":1000000000.0}}}' \
  "$(base_payload '{"seven_day":{"used_percentage":46,"resets_at":'"$R7_3D"'}}')" \
  "$HOURLY_OUT" "$(printf '%s' "$SHARE_OUT" | jq -c '.generated_at_epoch = '"$NOW")"
expect_state '((.gauge.premium.median / 100 * .gauge.premium.allowance) - 90000000 | fabs) < 1' \
  "68b: the gauge weighed exactly the rows the collector counted, at the same weight"
expect_state '.gauge.premium.weight == 3' "68b: and it took the weight from share.json, not a constant"

echo
echo "--- all three gauges at once, at four widths (COLUMNS=200/120/80/60) ---"
FULL_SEED="$(seed_state 19 "$ALLOW" 45 "$ALLOW" "$((NOW+3*86400))" "$((NOW+3600))")"
FULL_PAYLOAD="$(base_payload '{"seven_day":{"used_percentage":45,"resets_at":'"$((NOW+3*86400))"'},"five_hour":{"used_percentage":19,"resets_at":'"$((NOW+3600))"'}}')"
FULL_USAGE="$(usage_row "$(hours_ago 40)" 750000000
              usage_row "$(hours_ago 3)" 10000000
              usage_row "$(hours_ago 2)" 10000000
              usage_row "$(hours_ago 1)" 10000000
              usage_row "$(hours_ago 40)" 100000000 fable)"
for c in 200 120 80 60; do
  HARNESS_COLS="$c" run_case "18-all-three-cols$c" "$FULL_SEED" "$FULL_PAYLOAD" "$FULL_USAGE" "$SHARE_PREM"
done
unset HARNESS_COLS

echo
echo "--- timing: median wall time over 10 runs (real payload shape, WITH a real usage-hourly.jsonl in play) ---"
payload="$(base_payload '{"seven_day":{"used_percentage":40,"resets_at":'"$((NOW+3*86400))"'},"five_hour":{"used_percentage":19,"resets_at":'"$((NOW+3600))"'}}')"
th="$WORKDIR/harness-home-timing"
rm -rf "$th"; mkdir -p "$th/.claude/usage"
printf '%s' "$(seed_state 19 "$ALLOW" 40 "$ALLOW")" > "$th/.claude/.pace-trend.json"
{ usage_row "$(hours_ago 40)" 385000000; usage_row "$(hours_ago 3)" 5000000; usage_row "$(hours_ago 2)" 5000000; usage_row "$(hours_ago 1)" 5000000; } > "$th/.claude/usage/usage-hourly.jsonl"
times=()
for i in $(seq 1 10); do
  t0=$(date +%s%N)
  printf '%s' "$payload" | HOME="$th" bash "$SCRIPT" >/dev/null 2>&1
  t1=$(date +%s%N)
  times+=( $(( (t1 - t0) / 1000000 )) )
done
rm -rf "$th"
sorted=$(printf '%s\n' "${times[@]}" | sort -n)
echo "runs (ms): $(echo "$sorted" | tr '\n' ' ')"
median=$(echo "$sorted" | awk '{a[NR]=$1} END{n=NR; if(n%2==1) print a[(n+1)/2]; else print (a[n/2]+a[n/2+1])/2}')
echo "median: ${median}ms"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "ASSERTIONS: $PASSED passed, $FAILED FAILED"
  exit 1
fi
echo "ASSERTIONS: $PASSED passed, 0 failed"
