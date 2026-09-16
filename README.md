# claude-statusline

A two-row status line for [Claude Code](https://claude.com/claude-code): context
fill, plan usage windows, and prompt-cache health, as painted gauge bars.

![Two rows beneath the Claude Code prompt, with a two-row WIFO wordmark in
the left column. Row one: MODEL Opus 5 (1M context), EFFORT high, DIR and
BRANCH, SESSION id. Row two: cyan CONTEXT 5%, magenta 5H 78% (-59m) with a
warning marker, green WK 21% (-6d19h), gold FABLE 10% (-6d19h), violet CACHE
97% (-59m).](docs/statusline.png)

Each gauge is a solid rectangle: the filled part is the metric's own colour with
the percentage in black on top, the rest is a grey trough with the percentage in
the metric's colour. The number stays readable either way and flips as the bar
grows past it.

## What the fields mean

**Row 1** — `MODEL:` · `EFFORT:` · `DIR:` · `BRANCH:` · `SESSION:`. Every field
carries a grey label, so a value is readable on its own without counting
separators. `SESSION:` prints the full session id — the one `claude --resume`
takes, and the one that names the transcript file.

**Row 2** — one gauge per usage window, prompt-cache health last.

| Gauge | Shows | Countdown |
|---|---|---|
| `CONTEXT` | Context window fill | — |
| `5H` | 5-hour plan window | until it resets |
| `WK` | 7-day plan window | until it resets |
| *model name* | Per-model weekly window, if your plan has one | until it resets |
| `SPEND` | Gateway spend limit, if you're behind one | until the period resets |
| `CACHE` | Prompt-cache **hit ratio** | until the cached prefix goes **cold** |

Countdowns carry two units where the second one is non-zero: `45m`, `3h20m`,
`1d4h`. A bare `1d` would leave up to 24 hours open.

Two things about `CACHE` are deliberately inverted, because for a hit ratio high
is healthy:

- the `!` marker fires when it drops **below** 50% (yellow) and 25% (red)
- its countdown is time until you *lose* something, not until a window refills.
  `CACHE(cold)` means the prefix is already gone and your next message pays to
  rebuild it.

Every other gauge marks `!` at 70% and 90%.

## Install

```sh
git clone https://github.com/stefjow/claude-statusline
cd claude-statusline
bash install.sh
```

Or, if you'd rather not clone:

```sh
curl -fsSL https://raw.githubusercontent.com/stefjow/claude-statusline/main/install.sh -o install.sh
less install.sh     # it reads your credentials file - see below
bash install.sh
```

`bash install.sh --logo` turns the logo column on (see Configuration);
`--logo=NAME` picks another mark, and `--help` prints the usage.

The installer writes `~/.claude/statusline.sh` and `~/.claude/usage-refresh.sh`,
then adds a `statusLine` entry to `~/.claude/settings.json` with everything else
preserved. Anything it overwrites is backed up with a `.bak-<timestamp>` suffix,
and re-running it is safe. Claude Code picks the change up within ~30 seconds —
no restart needed.

**Requirements:** `jq`, `curl`, and Claude Code **2.1.267 or newer**. The
`rate_limits` and `prompt_cache` fields this depends on are recent additions;
on older versions those gauges simply won't appear. Works on Linux and macOS
(including the stock bash 3.2).

## It reads your credentials file — here's why

Claude Code's status line payload carries the 5-hour and 7-day windows, but
**not** per-model weekly windows. Those exist only on the account usage
endpoint. So `usage-refresh.sh`:

1. reads the OAuth token from `~/.claude/.credentials.json` — the same file
   Claude Code itself uses,
2. makes a read-only `GET https://api.anthropic.com/api/oauth/usage`,
3. writes the response to `~/.claude/usage-cache.json` (mode 600, no token in
   it).

It runs detached, at most once every 180 seconds, guarded by a lock, and exits
quietly if the token is missing or expired. The status line itself never makes
a network call — it only reads the cache, and hides those gauges if the cache is
older than 15 minutes. Nothing is sent anywhere except that one request to
Anthropic's own API.

If you'd rather not have a script touch your credentials, delete
`usage-refresh.sh` and remove the block that reads the cache from
`statusline.sh`. Everything else keeps working.

That endpoint is undocumented and may change without notice. When it does, the
per-model gauge disappears and the rest of the row is unaffected.

## Without a subscription login

On API key, Bedrock, Vertex or gateway auth there are no plan windows to show.
`CONTEXT` and `CACHE` still work — they come from the payload and need no
credentials. Gauges with no data are omitted rather than shown as zero.

## Configuration

Environment variables, all optional:

| Variable | Default | Effect |
|---|---|---|
| `CLAUDE_STATUSLINE_BAR_CELLS` | `8` | Gauge width in cells |
| `CLAUDE_STATUSLINE_RULE` | `∗` | Separator glyph; empty string for a plain gap |
| `CLAUDE_STATUSLINE_RULE_COLOR` | `38;5;220` | Separator colour (ANSI SGR) |
| `CLAUDE_USAGE_TTL` | `180` | Seconds between usage-endpoint refreshes |
| `CLAUDE_USAGE_MAX_AGE` | `900` | Hide cached windows older than this |
| `CLAUDE_STATUSLINE_LOGO` | unset | `wifo` draws a two-row wordmark left of both rows |

The default row widths are 109 and 104 columns, of which the session id alone
is 36. Drop `CLAUDE_STATUSLINE_BAR_CELLS` to `6` if you run a narrower
terminal.

`CLAUDE_STATUSLINE_LOGO=wifo` prepends a logo column to both rows, drawn from
box-drawing glyphs so it needs no font the gauges don't already assume:

```
┃ ┃┳┏━┏┓ MODEL:… ∗ EFFORT:… ∗ DIR:… ∗ BRANCH:…
┗┻┛┻┣ ┗┛ CONTEXT 37% ∗ 5H(-3h20m) 15% ∗ …
```

It costs 9 columns on both rows. Add your own house mark as another `case`
branch next to `wifo` in the emit section.

## Docs

[`docs/payload.md`](docs/payload.md) is a full field reference for the status
line JSON — every key, when it's present, and the rendering and refresh
behaviour, verified against 2.1.267. Useful whether or not you use this status
line.

## Development

`install.sh` embeds the two scripts, so it's generated rather than hand-edited:

```sh
bash build-installer.sh
```

Run that after changing `statusline.sh` or `usage-refresh.sh`.

## License

MIT
