# cc-cache-monitor

A diagnostic statusline extension for Claude Code that surfaces prompt-cache health in real time.

Claude Code's prompt cache has been silently breaking since at least March 2026, inflating subscription token consumption by 10–20× per [community-confirmed bug reports](https://github.com/anthropics/claude-code/issues/41788). The data needed to detect cache flushes is already in your local session transcripts — it just isn't surfaced anywhere in the UI. This tool closes that gap.

## What it shows

After install, your Claude Code statusline gets new fields at the end:

```
Opus4.7 | high | $0.42 | 23% ██░░░░░░ | 127k | 5h 96% | 7d 67% | cache 98% (3f) | chat: 1.1M | lifetime: 384M
```

Three scopes, increasing in time horizon:

### `cache NN%` — last-turn cache health

| Display              | Meaning                                                                |
|----------------------|------------------------------------------------------------------------|
| `cache 98%`          | Last turn's cache hit rate — healthy (≥90% cache_read dominant).       |
| `cache 67%`          | Soft miss — partial cache reuse this turn.                             |
| `cache ⚠2%`          | Flush event — full context rewritten as cache_creation, billed at 1.25×. |
| `cache 99% (3f)`     | 3 flush events detected this session. Bug fired 3 times.               |
| `cache --`           | First turn, no usage data yet.                                         |

The flush counter `(Nf)` only appears when N > 0. It's the bug-detection signal — if you see it climb during normal work, your subscription is being silently overcharged.

### `chat: NN.NM` — current conversation's bug-induced waste

Tokens lost to bug-induced flushes in **this conversation only**. Updates each turn. Hidden when zero.

### `lifetime: NN.NM` — every session ever

Cumulative across **every** JSONL in `~/.claude/projects/`. Both fields use the same per-flush formula; they differ only in scope.

### How "bug-induced" is determined

A flush counts as bug-induced (and contributes to `chat`/`lifetime`) when **both**:
- Per-turn hit rate < 50%, AND
- Time since previous turn < 60 min — cache should still have been alive per the paid 1h TTL

Genuine idle past 1h (you went to lunch for 90 min) is excluded. Bug-A/Bug-B flushes (mid-session cache invalidation) are included. TTL-regression flushes (Anthropic silently dropped TTL from 1h to 5m per #46829) are also included — because you paid for the 1h TTL and didn't get it.

Per-flush waste: `(cache_creation_observed - baseline) × 1.15`, where 1.15 is the price gap between cache_write rate (1.25×) and cache_read rate (0.1×). Waste is in **input-token-equivalents** — the unit Anthropic bills against your rate limit.

The `lifetime:` number only grows. When it's big, that's a quantified cost of Anthropic shipping below their stated 1h TTL spec.

Performance: lifetime waste is cached per-file at `~/.claude/cc-cache-monitor/waste-cache.json`, keyed by JSONL mtime. First run walks all your JSONLs (~50-100ms for ~500 files); subsequent refreshes only re-parse files whose mtime changed.

## Why this exists

Anthropic's prompt cache lets long prompts be billed at 10% rate on subsequent turns instead of 100%. When it works, a 400K-token context costs ~40K-token-equivalents per turn. When it breaks (current state of Claude Code), the cache is invalidated by [bugs in the binary](https://news.ycombinator.com/item?id=47587509), forcing the entire context to be re-billed at 1.25× rate as a fresh cache write.

The 5-hour rolling window on Pro/Max plans gets eaten 12× faster when the bug fires. Users see "I'm at 70% after 10 minutes" with no UI signal explaining why. This tool gives you that signal.

## Install

```bash
git clone https://github.com/AlexZan/cc-cache-monitor.git
cd cc-cache-monitor
./install.sh
```

The installer:
- Backs up your existing `~/.claude/statusline-command.sh` to `.bak.<timestamp>`
- Appends the cache-health block before the final `printf`
- Adds `"$cache_str"` to the printf argument list

If you don't have a statusline configured yet, the installer creates a minimal one and prints the `settings.json` snippet to wire it up.

Refreshes happen automatically — no restart required.

## Manual install

If you'd rather inspect and paste:

1. Open `statusline-cache.sh` in this repo.
2. Paste the contents into your `~/.claude/statusline-command.sh`, immediately before the final `printf` line.
3. In that `printf`, add `"$cache_str"` as the last argument and add `%s` to the format string.

## How it works

Reads from `~/.claude/projects/<project>/<session_id>.jsonl` — the local transcript Claude Code writes for every session. The most recent assistant message's `usage` field contains:

```json
{
  "input_tokens": 34,
  "cache_creation_input_tokens": 65185,
  "cache_read_input_tokens": 558680,
  "output_tokens": 9533
}
```

The hit rate is computed as:

```
hit_rate = cache_read / (cache_read + cache_creation + input)
```

A healthy turn has `cache_read` dominant (cached prefix reused, billed at 10% rate). A flush has `cache_creation` dominant (entire prefix rewritten as fresh cache, billed at 1.25× rate).

Session flush count = number of messages in the current session where `hit_rate < 50%`.

No daemon, no extra dependencies, recomputes on every statusline refresh at negligible cost.

## What this tool does NOT do

This is a **diagnostic** tool. It detects flushes after they happen. It does not prevent them or fix the bug.

For an actual fix, see [`claude-code-cache-fix`](https://github.com/cnighswonger/claude-code-cache-fix) — a community patch that addresses the underlying cache invalidation bugs in the Claude Code binary.

For broader usage analysis (per-session breakdowns, daily/weekly cost tables), see [`ccusage`](https://github.com/ryoppippi/ccusage).

## License

MIT
