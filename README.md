# claude-statusline-gauge

Claude Code will tell you that 63% of your weekly window is gone. It will not tell you whether
that is fine.

63% on day six is fine. 63% on day two, at your current rate, is a window that runs out on
Thursday. Same number, opposite decision — and the difference is pace, which the percentage
alone cannot express.

This is a status line for [Claude Code](https://claude.com/claude-code) that answers the pace
question. For each usage window it shows where you are against the clock, how fast you are
currently spending, and **where you end up at reset if you keep going**.

<!-- render:full -->
```
Opus 5 │ …/dev/src/checkout-service  ctx 38% [█████░░░░░░░] 76.4k/200k
sid:a3f19c7d  $4.62  1h31m  +214/-87  sess ↑236.7k/↓31.2k (cache 3.7M)
5h ▕▓▓▓▓▓░░░░░░░┃░░░░░░░▏23.00% -37.00% (2h behind)  0.20×→  lands 38%  7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.50% +17.64% (30h ahead)  0.42×→  lands 77%  fable ▕▓▓▓░░░░░┃░░░░░░░░░░░▏16.46% -26.39% (44h behind)  0.16×→  lands 30%
```
<!-- /render:full -->

Three lines: the usual model/cwd/context information, the usual session information, and then
the gauges. It is coloured in a real terminal.

**The reading that matters is the last one on each gauge.** In the 7-day gauge above,
`lands 77%` says: carry on working the way you have for the last few hours, and the week
ends there. Under 100 means you have room. Over 100 means you run out early — and it says
so long before the used-percentage does.

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/aronmarden/claude-statusline-gauge/main/install.sh | bash
```

Then restart Claude Code. It needs `bash` (macOS's stock 3.2 is fine) and `jq` 1.6 or newer;
the installer checks `jq` before touching anything and stops if it is missing or too old.

The first gauges appear immediately. The rate half of each gauge — the burn ratio and the
`lands` projection — needs a few minutes of collected token history before it can say
anything, and the installer starts that collection in the background. See
[what needs the collector](#what-works-out-of-the-box-and-what-needs-the-collector).

<details>
<summary>What the installer touches, and how to undo it</summary>

- backs up an existing `~/.claude/statusline.sh` and `~/.claude/settings.json` **once**, to
  `*.pre-statusline-gauge`, and prints both paths;
- installs `~/.claude/statusline.sh`, `~/.claude/usage-collector.sh` and
  `~/.claude/uninstall-statusline-gauge.sh`;
- adds exactly one key — `.statusLine` — to `settings.json` **with jq**. Every other key you
  have (permissions, hooks, env, model, whatever) is read and written back by jq and comes
  through unchanged. If your `settings.json` is not valid JSON the installer stops and changes
  nothing rather than guessing;
- kicks off a one-off background backfill of your token history, if `~/.claude/projects` exists.

Re-running is safe: it does not overwrite the original backup, and the `.statusLine` value it
writes is the same one, so a second run leaves the file's content as it was.

Options: `--no-collector`, `--with-governor` ([pace governor](#pace-governor-opt-in)),
`--dir <path>`, `--from <local checkout>`, `--help`.

To remove it:

```sh
bash ~/.claude/uninstall-statusline-gauge.sh
```

That restores `settings.json` and `statusline.sh` byte-for-byte from the backups. If there
were no backups (a clean install) it removes the `.statusLine` key with jq and leaves the rest
of the file alone. `--keep-usage` keeps the collected token history.

Verified against Claude Code 2.1.220 on macOS. Nothing in it is macOS-specific; it should work
anywhere bash and jq do. `find`, `grep`, `sed`, `awk`, `date` and `stat` are the only other
things it calls, and they ship with both macOS and Linux.

</details>

---

## Reading it

You can stop after this section and the next one and use the thing correctly. Everything
below them is reference.

### The one number

`lands N%` — the projection at the far right of each gauge. It is where that window finishes
at its reset if your current burn rate holds. Under 100, you have room. Over 100, you do not,
and the number tells you by how much.

Everything else on the line explains how it got there.

### One gauge, part by part

<!-- render:anatomy -->
```
7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.50% +17.64% (30h ahead)  0.42×→  lands 77%
   └────────bar─────────┘└used┘└delta─┘└─time gap─┘└─rate─┘└──lands──┘
```
<!-- /render:anatomy -->

| Part | What it is |
|---|---|
| `7d` | which window this gauge is for |
| **bar** | 20 cells. `▓` used, `░` remaining, and one cell is the pace marker |
| **`┃`** | the *pace marker*: where usage would be right now if you spent the window evenly from start to reset. It moves with the clock, not with your spending |
| **bar colour** | how far past the pace marker you are: green under it, amber up to 15% over, red beyond. Grey means the reset time is unknown, so there is nothing to compare against |
| **used** | how much of the window is gone |
| **delta** | how far past (`+`) or short of (`-`) the pace marker, in **points of the window**. Same colour as the bar. The `%` sign is literal — these are percentage points, not minutes |
| **time gap** | the same distance expressed in this window's own time. `ahead` = spending *nothing* for this long puts you back on the line. `behind` = spending *at pace* for this long brings you up to it. Always carries the word, because a signed time with no word is one glance from meaning its opposite |
| **rate** | your current burn divided by the burn that would land exactly on 100% at reset. Under 1.00 is headroom, over 1.00 is overspend. `↗` `↘` `→` is the trend across recent refreshes |
| **lands** | the projection. Always red over 100 |

The bar and the rate are coloured independently and they can legitimately disagree — see
[Ahead of the line, but not burning](#ahead-of-the-line-but-not-burning).

### The windows

| | |
|---|---|
| `5h` | the rolling 5-hour window |
| `7d` | the rolling 7-day window |
| `fable` | one model family's share of the 7-day window, weighted by what it costs. The label is the family's own name. It only appears if you actually run such a family — see [the premium gauge](#the-premium-gauge-and-when-it-is-not-there) |

### Markers

| | |
|---|---|
| `!` | the two independent sources for this percentage disagree by more than 5 points. Usually spend from another machine that local transcripts cannot see. Information, not an error |
| `prov` | fewer than 3 payload samples so far, so the reading is one raw sample rather than a median. Clears itself a minute or two after Claude Code starts |
| `0.00×` | a *measured* zero. The source is there and the answer really is "nothing spent recently", so `lands` equals used% — you stay exactly where you are |
| `–` | no data at all. Nothing to measure, and it will not pretend otherwise |

Those last two are deliberately different characters. "No data" must never look like "healthy".

### The other two lines

<details>
<summary>Line 1 and line 2 in detail</summary>

**Line 1**

| | |
|---|---|
| `Opus 5` | active model, plus any active flags (`fast`, `no-think`, effort level, output style, agent name) |
| `…/dev/src/checkout-service` | cwd, `$HOME` shortened to `~`, trimmed to the last three segments when it is deeper than that |
| `main*` | git branch, `*` if the working tree is dirty |
| `ctx 38% [█████░░░░░░░] 76.4k/200k` | context window. Yellow from 50%, amber from 75%, red from 90% — Claude Code auto-compacts around 92% and recall degrades well before that |

**Line 2**

| | |
|---|---|
| `sid:a3f19c7d` | session id, first 8 characters |
| `$4.62` | session cost |
| `1h31m` | session wall time |
| `+214/-87` | lines added / removed this session |
| `sess ↑236.7k/↓31.2k (cache 3.7M)` | cumulative session tokens: input + cache-creation, output, cache reads |

</details>

---

## What to do about it

Four readings you will actually see, and the call each one implies.

### Comfortable

<!-- render:situation-comfortable -->
```
7d ▕▓▓▓▓▓▓░░┃░░░░░░░░░░░▏30.00% -10.48% (18h behind)  0.52×→  lands 66%
```
<!-- /render:situation-comfortable -->

Behind the pace line, burning about half of what the window can afford, projected to finish
well inside it.

**Do nothing.** Use the model you actually want, fan out across agents, run the expensive
search. Headroom you do not spend is not saved for later — the window resets whether you used
it or not.

### Ahead of the line, but not burning

<!-- render:situation-ahead -->
```
7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.50% +17.64% (30h ahead)  0.42×→  lands 77%
```
<!-- /render:situation-ahead -->

Red bar, green rate. A heavy session earlier in the window put you well past the line; the
last few hours have been light. The bar is reporting history. The rate is reporting now.

**Also do nothing** — and specifically, do not start rationing. A red bar on its own is a
record of spending that has already happened; you cannot un-spend it, and the projection says
the way you are working right now still finishes inside the window. Watch `lands`, not the
bar. If it starts climbing toward 100, that is a different situation.

### Tight

<!-- render:situation-tight -->
```
7d ▕▓▓▓▓▓▓▓▓┃░░░░░░░░░░░▏38.00% -2.48% (4h behind)  1.11×→  lands 107%
```
<!-- /render:situation-tight -->

The bar is green — you are still *under* the pace line — and that is exactly the trap. Nothing
looks wrong. But the rate is over 1.00, so the projection has crossed 100: keep working like
this and you finish the week short. This is the reading worth catching, because the correction
is small now and will not be later.

**Do:** move mechanical, checkable work down a model tier. Batch rather than fan out. Drop
speculative parallel exploration. A rate barely over 1.00 needs a modest trim, not a stop —
and every hour you spend under 1.00 pulls the projection back down.

### Blowing out

<!-- render:situation-blowout -->
```
7d ▕▓▓▓▓▓▓▓▓┃▓▓░░░░░░░░░▏55.00% +14.52% (24h ahead)  4.58×→  lands 261%
```
<!-- /render:situation-blowout -->

Past the line and burning several times what the window can carry. A projection that far over
100 is not something you will ever observe — you hit the limit well before the reset. It is a
statement of scale: at this rate the window is worth roughly a third of what you are asking of
it.

**Do:** stop the fan-out now. Cheapest tier that can actually do the job, and say what
something will cost before starting it. Ask whether the remaining work has to happen inside
this window at all. The `(24h ahead)` figure is the concrete version of the fix: that is how
long of spending nothing puts you back on the line.

If you would rather Claude made these calls itself instead of you watching for them, see
[the pace governor](#pace-governor-opt-in).

---

## What works out of the box, and what needs the collector

Claude Code hands the status line a JSON payload on stdin. That payload carries your window
percentages and reset times, but **no token counts over time** — so it can say where you are,
and it cannot say how fast you are moving.

| Element | Needs | Why |
|---|---|---|
| the bar and the `┃` pace marker | payload + clock | position against elapsed time is pure arithmetic |
| the used percentage | payload | it is in the payload — but see the next row |
| the *fractional* part of it | **token history** | the payload only ever sends a whole number, so without a token source the figure is truthful but cannot move until the next whole point |
| the pace delta | payload + clock | used% minus the elapsed fraction of the window |
| the time gap | payload + clock | the same distance in the window's own time |
| the burn rate | **token history** | a rate needs real spend over real time |
| `lands` | **token history** | it is a projection of that rate |
| the whole premium gauge | **token history** | the payload has no premium-model window in it at all |

**Core — no dependencies.** Install and this works immediately:

<!-- render:core -->
```
5h ▕▓▓▓▓▓░░░░░░░┃░░░░░░░▏23.00% -37.00% (2h behind)  7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.00% +17.14% (29h ahead)
```
<!-- /render:core -->

Two things to notice. The rate half of each gauge is **omitted**, not shown as a permanent
`–`: a `–` in this status line always means "there is a source and it cannot answer right
now", never "you did not install something". And the 7-day percentage
reads `60.00%` here against `60.50%` in the full render — the payload sends whole numbers
only, and one whole point of a 7-day window is worth far more than even a flat-out hour of
work, so without a token source the figure is exactly right and simply does not move for
hours at a time.

**With the collector — bundled, on by default.** `usage-collector.sh` reads Claude Code's own
transcripts under `~/.claude/projects/`, aggregates tokens per hour per model family, and
writes two small files. Nothing leaves your machine and it reads nothing else — there is no
network call anywhere in it. `statusline.sh` fires it detached on every refresh with
`--if-stale`, and the collector itself decides whether anything is due, so there is no cron job
or launchd plist to set up.

Cost, measured against a ~600 MB, 600-file transcript history: **13 s** for the one-off
backfill (in the background, during install), **0.2 s** for a normal incremental run, **9 ms**
for the throttled no-op that happens on most refreshes. The status line itself renders in
about 65 ms.

**Its limits, stated plainly.** It counts what is in your local transcripts. It cannot see
spend from another machine, from the web app, or from a cloud session — on a shared plan it
structurally under-counts, and that is what the `!` marker is for.

If you already have your own usage aggregator, point `CLAUDE_STATUSLINE_USAGE_DIR` at it; the
two file formats it needs are documented at the top of `usage-collector.sh`.

Collector commands worth knowing:

| | |
|---|---|
| `~/.claude/usage-collector.sh --status` | what it resolved: directories, row counts, which family is premium |
| `~/.claude/usage-collector.sh --full` | rebuild the whole retention window from transcripts |
| `~/.claude/usage-collector.sh --if-stale` | collect only if the aggregate is older than the throttle. This is how the status line calls it |

---

## Configuration

Environment variables, all optional. Set them in `settings.json` under `env`, or in the
`statusLine.command` itself.

| | |
|---|---|
| `CLAUDE_STATUSLINE_USAGE_DIR` | where the usage aggregate lives (default `~/.claude/usage`) |
| `CLAUDE_STATUSLINE_COLLECTOR` | path to the collector (default `~/.claude/usage-collector.sh`) |
| `CLAUDE_STATUSLINE_THROTTLE` | seconds between real collector runs, under `--if-stale` (default `300`) |
| `CLAUDE_STATUSLINE_RETAIN_DAYS` | days of hourly history to keep (default `9`) |
| `CLAUDE_STATUSLINE_PROJECTS_DIR` | transcript location (default `~/.claude/projects`) |
| `CLAUDE_STATUSLINE_PREMIUM_SHARE` | the premium gauge's target share of the 7-day window (default `0.5`) |
| `CLAUDE_STATUSLINE_PREMIUM_FAMILY` | which family the premium gauge rations: an extended regex matched case-insensitively against the model id. Default: auto-detected |
| `CLAUDE_STATUSLINE_PREMIUM_WEIGHT` | what one of its tokens costs in opus-equivalents — that is, relative to an opus token, which is `1` by definition (default: the cost table's figure for the family, else `1`) |
| `CLAUDE_STATUSLINE_PREMIUM_LABEL` | what the premium gauge is called on screen (default: the family's name) |

The `CLAUDE_STATUSLINE_PREMIUM_*` four are read by the **collector**, not by the status line.
It resolves them once and writes the answer into `share.json`; the status line reads it back
from there rather than working it out again. That is deliberate — a collector counting one set
of rows while the gauge weighted a different set would be a silently wrong number rather than a
visible bug. Changing `PREMIUM_FAMILY` changes how rows are classified, and rows already
written keep their old family, so follow the change with `~/.claude/usage-collector.sh --full`.

**Narrow terminals.** The gauge line degrades in a fixed order: the `(30h ahead)`
parentheticals go first (premium, then `5h`, then `7d`), then bars (premium, then `5h`). The
7-day bar and every percentage survive at every width.

---

## The premium gauge, and when it is not there

The third gauge exists to ration **one** model family: the one that costs materially more per
token than the rest of your mix, so that moving mechanical work off it actually buys back
window. Which family that is depends on what you run, so nothing is hardcoded to a model name.

**The default is auto-detection.** The collector holds a small cost table of families that
cost more than the opus-equivalent baseline, priciest first, and picks the priciest one that
actually appears in your retained history. If none of them do, it writes no premium block and
**the gauge does not render**. You get two gauges, which is the correct answer for most
installs — a gauge for a policy you are not exercising is noise, and a `0.00%` bar with a large
"behind" figure beside it is worse than noise: it reads as a measurement that you are
*under*-using something you should use more.

**Three states, three different renders**, deliberately not interchangeable:

| State | Renders as |
|---|---|
| you do not run a premium family | no third gauge at all. Nothing is claimed |
| you do, but spent none of it this window | a real `0.00%`, with a `0.00×` rate and a `lands` equal to used%. A measurement |
| you do, but there is no usage history yet | `–`. Unknown, and it says so |

The difference between the first two is where the history is read from. Selection looks at the
**whole retained file** (`CLAUDE_STATUSLINE_RETAIN_DAYS`, default 9 days); the share is measured
over the **trailing 7 days**. Retention is deliberately longer than the window, so "used it last
week, none this window" still selects the family and reports a genuine zero, while "never
appears at all" selects nothing. Nine days of silence and the gauge stops rendering, which is
the honest statement — at that point there is no evidence left that you run it.

**Naming a family yourself opts you in unconditionally.** Setting
`CLAUDE_STATUSLINE_PREMIUM_FAMILY` *is* the statement that the policy applies to you, so the
gauge renders even at zero:

```sh
# ration opus against your sonnet/haiku work
CLAUDE_STATUSLINE_PREMIUM_FAMILY=opus
CLAUDE_STATUSLINE_PREMIUM_LABEL=opus
CLAUDE_STATUSLINE_PREMIUM_SHARE=0.4        # no more than 40% of the window

# something that costs 3x the baseline
CLAUDE_STATUSLINE_PREMIUM_FAMILY='big-model|bigger-model'
CLAUDE_STATUSLINE_PREMIUM_WEIGHT=3
CLAUDE_STATUSLINE_PREMIUM_LABEL=big
```

Two things this gauge is not. It is **not a limit the API enforces** — the share is a policy
you set, defaulting to "no more than half the 7-day window goes to that family". And its spend
is already counted inside the 7-day gauge; it is a breakdown, not a fourth budget.

---

## Pace governor (opt-in)

The gauges are for you. The same numbers are just as useful to *Claude*, which is the thing
actually spending the window — but only if it reads them **before** deciding how to do the
work rather than after.

```sh
curl -fsSL https://raw.githubusercontent.com/aronmarden/claude-statusline-gauge/main/install.sh \
  | bash -s -- --with-governor
```

That appends one delimited block to `~/.claude/CLAUDE.md`. It has to be the global one: a
`CLAUDE.md` in a project only loads while you are working in that project, and a status-line
repo's own `CLAUDE.md` would load exactly when it does not matter.

The block tells Claude to read `~/.claude/.pace-trend.json` and band on the **projection** —
`lands`, where the current rate finishes the window — rather than on how much is used so far.
Used% is backward-looking: by the time it reads badly, the spend has happened.

| Projected landing | How the work gets done |
|---|---|
| under 85 | normally, and it says nothing about usage |
| 85–100 | cheaper tier for mechanical work, batch rather than fan out, mentioned once |
| over 100 | cheapest adequate tier, asks before a parallel fan-out, states the cost before anything large |

It governs on whichever of the 5-hour and 7-day projections is worse, and notes which one that
was — 5h is a burst limit that bites within the hour, 7d is the strategic one, and they are not
interchangeable. The premium share is deliberately left out of that comparison, because its
spend is already inside the 7-day figure.

**What it does not do.** It never refuses work, never defers it, and never quietly delivers
less than you asked for. It changes *how* a job is done — model tier, parallelism, batch size —
not *whether*. An explicit instruction from you overrides it outright. An assistant that
declines real work to protect a usage budget is worse than the blowout it was avoiding.

It is also built to say "I don't know" rather than "you're fine": a `.pace-trend.json` older
than 15 minutes counts as no data, `null` is unknown rather than zero, and with no collector
installed there is no landing figure at all, so it falls back to used% over the elapsed
fraction of the window — a whole-window average that lags, and that the block labels as such.

Read [`pace-governor.md`](pace-governor.md) before you install it. It is short, and it is going
into every session you run.

**Adding it to an existing install** — either re-run the installer with `--with-governor` (it
replaces the block rather than appending a second copy), or:

```sh
{ printf '\n'; curl -fsSL https://raw.githubusercontent.com/aronmarden/claude-statusline-gauge/main/pace-governor.md; } \
  >> ~/.claude/CLAUDE.md
```

**Removing it** — `bash ~/.claude/uninstall-statusline-gauge.sh` lifts the block out and leaves
the rest of your `CLAUDE.md` byte-for-byte, including anything you added after installing; that
is why it strips in place instead of restoring the backup it took. To remove it by hand without
uninstalling the status line, delete everything between and including:

```
<!-- BEGIN claude-statusline-gauge pace governor -->
<!-- END claude-statusline-gauge pace governor -->
```

---

## Files it writes

| | |
|---|---|
| `~/.claude/.pace-trend.json` | rolling payload samples, calibrated allowances, trend history. Small, rewritten each refresh |
| `~/.claude/.plan-usage.json` | the current window snapshot straight from the payload, so Claude itself can read your remaining capacity when you ask it to |
| `~/.claude/usage/usage-hourly.jsonl` | per-hour token aggregates, pruned to 9 days |
| `~/.claude/usage/share.json` | which family is the premium one, what it weighs, and its share of the last 7 days |
| `~/.claude/CLAUDE.md` | one delimited block, **only** with `--with-governor`; backed up first |

All local, all removed by the uninstaller.

---

## Troubleshooting

**The status line is blank or shows a jq error.** Run it by hand with a fake payload:

```sh
echo '{"model":{"display_name":"x"},"cwd":"/tmp","rate_limits":{"seven_day":{"used_percentage":50,"resets_at":'"$(( $(date +%s) + 200000 ))"'}}}' \
  | bash ~/.claude/statusline.sh
```

**No rate or `lands` figures.** The collector has not produced data yet. Check with
`~/.claude/usage-collector.sh --status`, then force a full rebuild with
`~/.claude/usage-collector.sh --full`. If `~/.claude/projects` is empty, there is nothing to
read yet.

**`5h` shows `– lands –` and the others do not.** Expected, and not a broken install. The
5-hour window needs a calibrated allowance before tokens can be turned into points, and
calibration deliberately refuses to run below 20% used — the arithmetic is ill-conditioned down
there, and that is where it once produced a reading of 799%. The 5-hour window sits below 20%
for most of every cycle, so it seeds its allowance the first time a refresh catches it above
that line, and keeps it. Until then the position half is fully live and the rate half honestly
says it does not know.

**No third gauge.** Most often this is correct and deliberate: nothing in your history costs
more than the baseline, so there is no premium family to ration. Check with
`~/.claude/usage-collector.sh --status`, which prints what it resolved. Otherwise the gauge also
needs `share.json` to exist *and* the 7-day gauge to have a calibrated allowance, which needs
the 7-day window past 20% used. Below that it is deliberately absent rather than wrong. To
ration a family the cost table does not know about, name it with
`CLAUDE_STATUSLINE_PREMIUM_FAMILY` and re-run the collector with `--full`.

**Everything reads `–`, or the percentage looks stuck.** Delete `~/.claude/.pace-trend.json`;
it rebuilds from scratch within a few refreshes.

**`prov` never goes away.** It clears after 3 refreshes of a live session. If it persists, the
payload is not carrying `rate_limits` — check your Claude Code version.

**The percentage is lower than the app says.** That is the `!` case: local transcripts cannot
see spend from another machine or the web app. The calibration converges on the payload's
figure over subsequent refreshes.

---

## Testing

```sh
bash test_harness.sh    # 38 render cases + 89 assertions on the gauge logic
bash test_install.sh    # 62 assertions on the installer, uninstaller and governor
```

Both exit non-zero on failure, and both run entirely inside disposable `HOME=` sandboxes under
`$TMPDIR`; neither reads or writes your real `~/.claude`.

The render cases cover fresh windows, missing/past/impossible reset times, partial hours,
negative and unmeasurable rates, divergence markers, allowance-calibration refusal, and width
degradation at 200/120/80/60 columns. The assertions cover source selection from both sides of
the stability threshold, the unit on every delta, the direction word on every time figure, the
guards that stop an allowance collapse, and the no-usage-source case.

The installer suite is the paranoid one, because the worst possible bug here is eating
somebody's `settings.json`: it installs over a populated config and diffs every other key,
re-runs itself four times, and checks that uninstall restores the original byte-for-byte. The
governor cases do the same to `CLAUDE.md`, including a file with no trailing newline and one
the user kept editing on both sides of the block after installing, and they run the block's own
jq verbatim out of `pace-governor.md` against fresh, stale, degraded and all-null fixtures.

---

## Design notes

Not needed to use it. This is why it behaves the way it does.

### Position and rate answer different questions

**The bar is about the past.** Am I ahead of where the clock says I should be? It compares
used% against the pace marker.

**The rate and `lands` are about the future.** Does my *current* burn blow the budget? They
compare recent tokens-per-hour against the burn that would exactly exhaust the window at reset.

They disagree all the time, and both are right — the
[Ahead of the line](#ahead-of-the-line-but-not-burning) reading above is the standard case.
There, the bar is **red**: 60.50% used against a 42.86% pace marker, +17.64 points ahead — a
heavy session earlier in the window put you well past it. The rate is **green**: right now you
are burning at 0.42× the burn that would exhaust the window, so if you keep going like this
you land at 77%, comfortably inside. Past you overspent; present you is fine.

The reverse is the [Tight](#tight) reading: still under the line, but accelerating hard enough
that you will not be for long. That is the case worth catching early, and it is exactly the
case a single "63% used" number hides.

Colouring the bar on the rate instead of the position was a real bug at one point: it made a
genuine overshoot look green. They are deliberately independent now.

### Where the percentage comes from

There are two possible sources for "how much of this window is used", and **neither is
unconditionally right**, so the gauge picks per window, per refresh.

**The payload's `used_percentage`** is the server's own figure, but it can rotate: each
concurrently-running Claude Code process reports its own cached snapshot, resynced on no fixed
schedule, so several individually-stable values alternate between refreshes. It is not jitter
around a true value, so averaging harder does not fix it.

**The token derivation** (spend ÷ a calibrated allowance) has no flicker at all, but it is
built from local transcripts only, so it cannot see spend from another machine, the web app, or
a cloud session. On a shared plan it structurally under-counts.

So each refresh runs a stability test on the last 5 raw payload samples:

| | |
|---|---|
| spread ≤ 3 points, and ≥ 3 samples | not rotating → the payload is the server's own figure. Use it |
| spread > 3 points, or fewer than 3 samples | rotating → fall back to the token derivation |

The burn rate is **always** measured from tokens, whichever source won: an integer percentage
that only moves on resync cannot supply a rate. (The target it is divided by — the burn that
would land exactly on 100% — is derived from the current level and reset time, so that half can
inherit the payload's figure.)

### The payload is truthful but coarse, so its level is interpolated

`used_percentage` is an **integer**. One point of a 7-day window is a large multiple of what
even a flat-out hour of work spends, so a perfectly truthful payload can sit still for hours
while two agents run at full tilt — the gauge reads as frozen exactly when you most want to
watch it move.

Level and movement are available from different places, so they are taken from different
places: **the level from the server's integer, the movement from local tokens.**

```
used% = anchor.value + (tokens_since_the_anchor / allowance) × 100
```

The anchor records the token count at the moment the integer last changed, so when the payload
does tick, the display snaps exactly onto the new integer and the tokens already inside that
tick are never counted twice. Three guards, the same shape as everything else here: the
interpolation is capped at **+1.00 point** (one point is the payload's own resolution, so one
point past it is the edge of what this can honestly claim), it is never negative (a window
reset drops tokens below the anchor, which clamps to +0 and re-anchors immediately), and with
no token source it falls back to the bare integer rather than to an extrapolation.

`!` means the two sources disagree by more than 5 points — usually off-machine spend the local
transcripts cannot see, or a calibrated allowance that has not finished converging.

### Guards on the allowance

Getting the allowance wrong is how a gauge lies, so calibration is fenced: no recalibration
below 20% used (the arithmetic is ill-conditioned near zero and once produced a reading of
799%), no single step moving the allowance by more than 20%, a sanity clamp above 150%, and the
reset time validated against `now < resets_at <= now + window` on every read and every write —
a stale reset time was once kept for 40 hours because the payload intermittently omits it.

The rule the whole script follows: **never display a number you cannot stand behind.** An
unmeasurable rate renders `–`; an unknown position renders a neutral grey bar. "No data" must
never look like "healthy".

### Why the current partial hour counts

Excluding the still-filling hour meant work happening right now contributed nothing for up to
60 minutes and then arrived diluted — two agents running hard moved the rate not at all. It is
now counted immediately, weighted by how much of the hour has elapsed, with that weight
**floored at 20 minutes**. Without the floor, a two-minute burst divides by 0.03 h and reads
roughly 30× high. With it, the worst case is bounded at 3× on one term of a multi-hour average,
and it decays as the hour fills.

### Why the premium gauge weights tokens

A plain token-mix ratio would say "40% of my tokens were model X". That is not the question.
The question is what fraction of the *window* model X consumed, and a window is spent in cost,
not in token count. So each family's tokens are multiplied by what they cost relative to an
opus token, which is `1` by definition — that is the unit. A weight above `1` is what makes the
gauge a cost claim, which is also why auto-detection only ever picks from the cost table, and
why a weight-`1` family has to be opted into by name.

## Licence

MIT. See [LICENSE](LICENSE).
