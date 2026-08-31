# claude-statusline-gauge

A two-line status line for [Claude Code](https://claude.com/claude-code) that tells you where
your plan usage actually stands: not just "63% used", but whether that is ahead of or behind
the pace that would use the window up exactly as it resets, and where your current burn rate
lands you if you keep going.

<!-- render:full -->
```
Opus 5 │ …/dev/src/checkout-service  ctx 38% [█████░░░░░░░] 76.4k/200k
sid:a3f19c7d  $4.62  1h31m  +214/-87  sess ↑236.7k/↓31.2k (cache 3.7M)
5h ▕▓▓▓▓▓░░░░░░░┃░░░░░░░▏23.00% -37.00% (2h behind)  0.20×→  lands 38%  7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.50% +17.64% (30h ahead)  0.44×→  lands 78%  fbl ▕▓▓▓░░░░░┃░░░░░░░░░░░▏16.46% -26.39% (44h behind)  0.17×→  lands 30%
```
<!-- /render:full -->

That is three gauges — the 5-hour window, the 7-day window, and the premium model's share of
the 7-day window — plus the usual cwd/branch/context/session information above them.

It is coloured in a real terminal. Everything below describes what each piece means.

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/aronmarden/claude-statusline-gauge/main/install.sh | bash
```

Then restart Claude Code.

The installer:

- checks that `jq` is present (and new enough) before touching anything;
- backs up an existing `~/.claude/statusline.sh` and `~/.claude/settings.json` **once**, to
  `*.pre-statusline-gauge`, and prints both paths;
- installs `~/.claude/statusline.sh`, `~/.claude/usage-collector.sh` and an uninstaller;
- adds exactly one key — `.statusLine` — to `settings.json` **with jq**. Every other key you
  have (permissions, hooks, env, model, whatever) is read and written back by jq and comes
  through unchanged. If your `settings.json` is not valid JSON the installer stops and changes
  nothing rather than guessing.

It is safe to run again; re-running does not overwrite the original backup and does not change
`settings.json` a second time.

Options: `--no-collector` (core only, see below), `--with-governor`
([pace governor](#pace-governor-opt-in)), `--dir <path>`, `--from <local checkout>`.

### Uninstall

```sh
bash ~/.claude/uninstall-statusline-gauge.sh
```

Restores `settings.json` and `statusline.sh` byte-for-byte from the backups the installer took.
If there were no backups (a clean install) it removes the `.statusLine` key with jq and leaves
the rest of the file alone. `--keep-usage` keeps the collected usage data.

### Requirements

| | |
|---|---|
| `bash` | 3.2 or newer — **macOS's stock `/bin/bash` is fine**, nothing to install |
| `jq` | 1.6 or newer. `brew install jq` / `apt install jq` / `dnf install jq` |
| everything else | `find`, `grep`, `sed`, `awk`, `date`, `stat` — already on macOS and Linux |

Verified against Claude Code 2.1.220 on macOS. It should work anywhere bash and jq do; nothing
in it is macOS-specific.

---

## What works without anything else, and what needs the collector

This matters, so it is stated plainly rather than buried.

Claude Code hands the status line a JSON payload on stdin. That payload contains your window
percentages and reset times, but **no token counts over time** — so it can tell you where you
are, and it cannot tell you how fast you are moving.

| Element | Needs | Why |
|---|---|---|
| the bar, the `┃` pace marker | payload + clock | position vs elapsed time is pure arithmetic |
| `60.50%` used | payload | it is in the payload — but see the next row |
| the fractional part of that `60.50%` | **token history** | the payload only ever sends a **whole number**. Without a token source the percentage is still truthful, it just cannot move until the next whole point |
| `+17.64%` pace delta | payload + clock | used% minus the elapsed-time fraction |
| `(30h ahead)` | payload + clock | the same gap expressed in the window's own time |
| `0.44×` burn ratio | **token history** | a rate needs real spend over real time |
| `lands 78%` | **token history** | it is a projection of that rate |
| the whole `fbl` gauge | **token history** | the payload has no premium-model window at all |

So there are two tiers:

**Core (zero dependencies).** Install and it works immediately. You get:

<!-- render:core -->
```
5h ▕▓▓▓▓▓░░░░░░░┃░░░░░░░▏23.00% -37.00% (2h behind)  7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.00% +17.14% (29h ahead)
```
<!-- /render:core -->

Two things to notice. The rate half of each gauge is **omitted**, not shown as a permanent
`–`: a `–` in this status line always means "there is a source and it cannot answer right
now", never "you did not install something". And the 7-day percentage reads `60.00%` here
against `60.50%` above — the payload sends whole numbers only, and one whole point of a
7-day window is worth far more than even a flat-out hour of work, so without a token source
the figure is exactly right and simply does not move for hours at a time.

**With the collector (bundled, on by default).** `usage-collector.sh` reads Claude Code's own
transcripts under `~/.claude/projects/`, aggregates tokens per hour per model family, and writes
two small files. Nothing leaves your machine; it reads nothing else. `statusline.sh` fires it
detached on every refresh and the collector decides whether anything is due, so there is no cron
job or launchd plist to set up.

Cost, measured against a ~600 MB, 600-file transcript history: **13 s** for the one-off backfill
(in the background, during install), **0.2 s** for a normal incremental run, **9 ms** for the
throttled no-op that happens on most refreshes. The status line itself renders in ~60 ms.

If you already have your own usage aggregator, point `CLAUDE_STATUSLINE_USAGE_DIR` at it — the
two file formats it needs are documented at the top of `usage-collector.sh`.

---

## Reading it

### Line 1

| | |
|---|---|
| `Opus 5` | active model, plus any active flags (`fast`, `no-think`, effort level, output style, agent name) |
| `…/dev/src/checkout-service` | cwd, `$HOME` shortened to `~`, trimmed to the last three segments |
| `main*` | git branch, `*` if the working tree is dirty |
| `ctx 38% [█████░░░░░░░] 76.4k/200k` | context window. Amber from 75%, red from 90% — Claude Code auto-compacts around 92% and recall degrades well before that |

### Line 2

| | |
|---|---|
| `sid:a3f19c7d` | session id, first 8 characters |
| `$4.62` | session cost |
| `1h31m` | session wall time |
| `+214/-87` | lines added / removed this session |
| `sess ↑236.7k/↓31.2k (cache 3.7M)` | cumulative session tokens: input+cache-creation, output, cache reads |

### The gauges

Each gauge is the same six pieces:

<!-- render:anatomy -->
```
7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.50% +17.64% (30h ahead)  0.44×→  lands 78%
   └────────bar─────────┘└used┘└delta─┘└─time gap─┘└─rate─┘└──lands──┘
```
<!-- /render:anatomy -->

| Element | Meaning |
|---|---|
| `▓` / `░` | used vs remaining, 20 cells |
| `┃` | the **pace marker**: where usage *should* be right now if you spent the window evenly. It moves with the clock, not with your spending |
| bar colour | **position** — `used% ÷ pace%`. Green under 1.00, amber to 1.15, red above. Grey means the reset time is unknown and the position cannot be computed |
| `60.50%` | how much of the window is used |
| `+17.64%` | **points of the window** ahead of (`+`) or behind (`-`) the pace marker. Coloured like the bar. The `%` is deliberate: these are percentage points, not minutes |
| `(30h ahead)` | the same gap in this window's own time. `ahead` = you have spent past the line, and this is how long of spending *nothing* puts you back on it. `behind` = you are under the line, and this is how long of spending *at pace* before you reach it. Always labelled — a signed time with no word is one glance from meaning its opposite |
| `0.44×` | **rate** — your current burn divided by the rate that would land exactly on 100% at reset. Under 1.00 means headroom. `↗`/`↘` is the trend over recent refreshes. The still-filling current hour counts, weighted by how much of it has elapsed with a 20-minute floor, so a burst two minutes into an hour cannot read as an hour-long spike |
| `lands 78%` | where the window ends up at reset if the current rate holds. Over 100% is always red |
| `!` | the two independent sources for this percentage disagree by more than 5 points (see below) |
| `prov` | fewer than 3 payload samples so far — the reading is a single raw sample, not a median. Clears itself within a minute or two of starting Claude Code |
| `0.00×` | a **measured zero**: the source is present and the answer really is "nothing spent this window", so `lands` equals the used% — you stay exactly where you are. Deliberately not `–` |
| `–` | genuinely absent data — there is nothing to measure. Never a guess, and never confused with a measured zero |

The three windows:

| | |
|---|---|
| `5h` | the rolling 5-hour window |
| `7d` | the rolling 7-day window |
| `fbl` | the premium model family (weighted 2×, since it costs about twice as much) as a share of the 7-day window. **This is a policy you set, not a limit the API enforces** — the default is "no more than half of the 7-day window should be premium tokens", configurable with `CLAUDE_STATUSLINE_PREMIUM_SHARE` |

## Position and rate answer different questions

This is the single most confusing thing about the display, so it is worth a section.

**The bar is about the past.** Am I ahead of where the clock says I should be? It compares
used% against the pace marker.

**The ratio and `lands` are about the future.** Does my *current* burn rate blow the budget? It
compares my recent tokens-per-hour against the rate that would exactly exhaust the window at
reset.

They disagree all the time, and both are right. In the example above:

<!-- render:disagree -->
```
7d ▕▓▓▓▓▓▓▓▓┃▓▓▓░░░░░░░░▏60.50% +17.64% (30h ahead)  0.44×→  lands 78%
```
<!-- /render:disagree -->

The bar is **red**: 60.50% used against a 42.86% pace marker, +17.64 points ahead — a heavy session
earlier in the window put you well past the line. The ratio is **green**: right now you are
burning at 0.44× the rate that would exhaust the window, so if you keep going like this you
land at 78%, comfortably inside. Past you overspent; present you is fine.

The reverse happens too — a green bar with a red `1.4× lands 130%` means you are still under
the line but accelerating hard enough that you will not be for long. That is the case worth
catching early, and it is exactly the case a single "63% used" number hides.

Colouring the bar on the rate instead of the position was a real bug at one point: it made a
genuine overshoot look green. They are deliberately independent now.

## Where the percentage comes from

There are two possible sources for "how much of this window is used", and **neither is
unconditionally right**, so the gauge picks per window, per refresh.

**The payload's `used_percentage`** is the server's own figure, but it can rotate: each
concurrently-running Claude Code process reports its own cached snapshot, resynced on no fixed
schedule, so several individually-stable values alternate between refreshes. It is not jitter
around a true value, so averaging harder does not fix it.

**The token derivation** (spend ÷ a calibrated allowance) has no flicker at all, but it is built
from local transcripts only, so it cannot see spend from another machine, the web app, or a
cloud session. On a shared plan it structurally under-counts.

So each refresh runs a stability test on the last 5 raw payload samples:

| | |
|---|---|
| spread ≤ 3 points, ≥3 samples | not rotating → the payload is the server's own figure. Use it |
| spread > 3 points, or <3 samples | rotating → fall back to the token derivation |

Rates are **always** token-derived: a rate needs real spend over real time, and an integer
percentage that only moves on resync cannot supply one.

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
transcripts cannot see, or a calibrated allowance that has not finished converging. It is
information, not an error.

The allowance calibration is guarded, because getting this wrong is how a gauge lies: no
recalibration below 20% used (the arithmetic is ill-conditioned near zero and once produced a
reading of 799%), no single step moving the allowance more than 20%, a sanity clamp above 150%,
and the reset time validated against `now < resets_at <= now + window` on every read and every
write — a stale reset time was once kept for 40 hours because the payload intermittently omits
it. The rule the whole script follows: **never display a number you cannot stand behind.** An
unmeasurable rate renders `–`; an unknown position renders a neutral grey bar. "No data" must
never look like "healthy".

## Configuration

Environment variables, all optional:

| | |
|---|---|
| `CLAUDE_STATUSLINE_USAGE_DIR` | where the usage aggregate lives (default `~/.claude/usage`) |
| `CLAUDE_STATUSLINE_COLLECTOR` | path to the collector (default `~/.claude/usage-collector.sh`) |
| `CLAUDE_STATUSLINE_THROTTLE` | seconds between real collector runs (default `300`) |
| `CLAUDE_STATUSLINE_RETAIN_DAYS` | days of hourly history to keep (default `9`) |
| `CLAUDE_STATUSLINE_PREMIUM_SHARE` | the `fbl` gauge's target share of the 7-day window (default `0.5`) |
| `CLAUDE_STATUSLINE_PROJECTS_DIR` | transcript location (default `~/.claude/projects`) |

Set them in `settings.json` under `env`, or in the `statusLine.command` itself.

The gauge line degrades on narrow terminals in a fixed order: the `(30h ahead)` parentheticals
go first (`fbl`, then `5h`, then `7d`), then bars (`fbl`, then `5h`). The 7-day bar and every
percentage always survive.

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
where the current burn rate lands the window at its reset — rather than on how much is used
so far. `used%` is backward-looking: by the time it reads badly, the spend has happened.

| projected landing | how the work is done |
|---|---|
| under 85% | normally, and it says nothing about usage |
| 85–100% | cheaper tier for mechanical work, no wide speculative fan-outs, mentioned once |
| over 100% | cheapest adequate tier, asks before a parallel fan-out, states the cost before anything large |

It governs on whichever of the 5-hour and 7-day windows is tighter, and the block says why the
two are not interchangeable: 5h is a burst limit that bites within the hour, 7d is the
strategic one.

**What it does not do.** It never refuses work, never defers it, and never quietly delivers
less than you asked for. It changes *how* a job is done — model tier, parallelism, batch size
— not *whether*. An explicit instruction from you overrides it outright. An assistant that
declines real work to protect a usage budget is worse than the blowout it was avoiding.

It is also built to say "I don't know" rather than "you're fine": a `.pace-trend.json` older
than 15 minutes counts as no data, `null` is unknown rather than zero, and with no collector
installed there is no landing figure at all, so it falls back to used% over the elapsed
fraction of the window — a whole-window average that lags, and that the block labels as such.

Read [`pace-governor.md`](pace-governor.md) before you install it; it is short, and it is
going into every session you run.

**Adding it to an existing install** — either re-run the installer with `--with-governor`
(it replaces the block rather than appending a second copy), or:

```sh
{ printf '\n'; curl -fsSL https://raw.githubusercontent.com/aronmarden/claude-statusline-gauge/main/pace-governor.md; } \
  >> ~/.claude/CLAUDE.md
```

**Removing it** — `bash ~/.claude/uninstall-statusline-gauge.sh` lifts the block out and
leaves the rest of your `CLAUDE.md` byte-for-byte, including anything you added after
installing; that is why it strips in place instead of restoring the backup it took. To remove
it by hand without uninstalling the status line, delete everything between and including:

```
<!-- BEGIN claude-statusline-gauge pace governor -->
<!-- END claude-statusline-gauge pace governor -->
```

## Files it writes

| | |
|---|---|
| `~/.claude/.pace-trend.json` | rolling payload samples, calibrated allowances, trend history. Small, rewritten each refresh |
| `~/.claude/.plan-usage.json` | the current window snapshot, so Claude itself can read your remaining capacity when you ask it to |
| `~/.claude/usage/usage-hourly.jsonl` | per-hour token aggregates, pruned to 9 days |
| `~/.claude/usage/share.json` | the premium-model share of the last 7 days |
| `~/.claude/CLAUDE.md` | one delimited block, **only** with `--with-governor`; backed up first |

All local, all removed by the uninstaller.

## Troubleshooting

**The status line is blank or shows a jq error.** Run it by hand with a fake payload:

```sh
echo '{"model":{"display_name":"x"},"cwd":"/tmp","rate_limits":{"seven_day":{"used_percentage":50,"resets_at":'"$(( $(date +%s) + 200000 ))"'}}}' \
  | bash ~/.claude/statusline.sh
```

**No `0.44×` or `lands` figures.** The collector has not produced data yet. Check with
`~/.claude/usage-collector.sh --status`, then force a full rebuild with
`~/.claude/usage-collector.sh --full`. If `~/.claude/projects` is empty, there is nothing to
read yet.

**`5h` shows `– lands –` and the others do not.** Expected, and not a broken install. The
5-hour window needs a calibrated allowance before tokens can be converted into points, and
calibration deliberately refuses to run below 20% used — the arithmetic is ill-conditioned
down there and that is where it once produced a reading of 799%. The 5-hour window sits below
20% for most of every cycle, so it seeds its allowance the first time a refresh catches it
above that line, and keeps it. Until then the position half is fully live and the rate half
honestly says it does not know.

**No `fbl` gauge.** It only appears when `share.json` exists *and* the 7-day gauge has a
calibrated allowance, which needs the 7-day window past 20% used. Below that it is deliberately
absent rather than wrong.

**Everything reads `–`, or the percentage looks stuck.** Delete `~/.claude/.pace-trend.json`;
it rebuilds from scratch within a few refreshes.

**`prov` never goes away.** It clears after 3 refreshes of a live session. If it persists, the
payload is not carrying `rate_limits` — check your Claude Code version.

**The percentage is lower than the app says.** That is the `!` case: local transcripts cannot
see spend from another machine or the web app. The calibration converges on the payload's
figure over subsequent refreshes.

## Testing

```sh
bash test_harness.sh    # 38 render cases + 28 assertions on the gauge logic
bash test_install.sh    # 57 assertions on the installer, uninstaller and governor
```

Both exit non-zero on failure and both run entirely inside disposable `HOME=` sandboxes under
`$TMPDIR`; neither reads or writes your real `~/.claude`.

The render cases cover fresh windows, missing/past/impossible reset times, partial hours,
negative and unmeasurable rates, divergence markers, allowance-calibration refusal, and width
degradation at 200/120/80/60 columns. The assertions cover source selection from both sides of
the stability threshold, the unit on every delta, the direction word on every time figure, the
guards that stop an allowance collapse, and the no-usage-source case.

The installer suite is the paranoid one, because the worst possible bug here is eating somebody's
`settings.json`: it installs over a populated config and diffs every other key, re-runs itself
four times, and checks that uninstall restores the original byte-for-byte. The governor
cases do the same to `CLAUDE.md`, including a file with no trailing newline and one the
user kept editing on both sides of the block after installing, and run the block's own jq
verbatim out of `pace-governor.md` against fresh, stale, degraded and all-null fixtures.

## Licence

MIT. See [LICENSE](LICENSE).
