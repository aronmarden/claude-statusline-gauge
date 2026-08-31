<!-- BEGIN claude-statusline-gauge pace governor -->
## Pace governor

The status line rewrites `~/.claude/.pace-trend.json` on every refresh. It projects where the
current burn rate lands each usage window. Read it at the start of a session and before
starting anything large, and let it shape **how** work is done — never **whether**.

```sh
jq -c 'def r($n): if . == null then null else (. * $n | round) / $n end;
  def proj($w; $win):
    if   $w.lands_at != null then $w.lands_at
    elif $w.median != null and $w.hours_to_reset != null
         and (1 - $w.hours_to_reset / $win) > 0.2
    then $w.median / (1 - $w.hours_to_reset / $win)
    else null end;
  def win($w; $h): {used: ($w.median | r(10)), lands: (proj($w; $h) | r(10)),
                    ratio: ($w.burn_ratio | r(100))};
  .gauge as $g
  | (($g.seven_day.resets_at // $g.five_hour.resets_at) as $t
     | ($g.seven_day.hours_to_reset // $g.five_hour.hours_to_reset) as $h
     | if $t == null or $h == null then null else (now - ($t - $h * 3600) | floor) end) as $age
  | {age_s: $age, five_hour: win($g.five_hour; 5), seven_day: win($g.seven_day; 168),
     fable: win($g.fable; 168)}
  | . + {worst: ([.five_hour.lands, .seven_day.lands] | map(select(. != null)) | max)}
' ~/.claude/.pace-trend.json 2>/dev/null
```

No output, or `age_s` null, means no usable data — proceed normally.

`lands` is the projected final % of a window at its reset. `worst` is the higher of the
5-hour and 7-day projections; govern on it, and note which window it came from. The 5-hour is
a burst limit that bites within the hour; the 7-day is the strategic one, and overshooting it
costs days rather than minutes.

| `worst` | how to work |
|---|---|
| under 85 | normally. Say nothing about usage. |
| 85–100 | cheaper model tier for mechanical, checkable work; batch rather than fan out; skip speculative parallel exploration. Mention it once, then drop it. |
| over 100 | cheapest tier that can actually do the job; ask before any parallel fan-out; state the cost before starting anything large. |

**This never refuses work, defers it, or quietly delivers less than was asked.** It changes
model tier, parallelism and batch size, and nothing else. If a job needs the expensive path,
take it and say why in one line. An explicit instruction from the user beats every row above,
with no argument and no reminder.

`ratio` is the burn ratio, where 1.0 is exactly on pace to finish at 100%. It is not a second
trigger: `ratio > 1` and `lands > 100` are the same condition, and near a reset `ratio` is the
misleading one — 5× with ten minutes left lands you about one point higher. Use it for
magnitude only, and only once it has held across several refreshes.

`fable` is the premium-model **share** of the 7-day window: a self-imposed target, not a plan
limit, and its spend is already counted inside `seven_day`. `fable.lands` over 100 means the
model mix is too expensive — move mechanical work down a tier. It is never a reason to stop.

**null means unknown — never zero, never fine.** Skip a null window and govern on the other.
`five_hour` is null for much of every cycle by design.

**Stale is the same as absent.** `age_s` over 900, or negative, means nothing has rendered the
status line recently. Proceed normally; do not govern on it.

**Without the usage collector** every `ratio` is null and `lands` falls back to used% ÷
elapsed fraction of the window — payload and clock only. That is a whole-window average, so it
lags a change of pace by hours, and it is withheld until the window is 20% elapsed. Same
bands, less confidence.
<!-- END claude-statusline-gauge pace governor -->
