# The Claude Code status line payload

Claude Code runs your `statusLine` command once per refresh and pipes a JSON
object to it on **stdin**. This is a field-by-field reference for that object.

Verified against **Claude Code 2.1.267**. Fields marked *optional* are absent
entirely rather than `null` unless stated otherwise — read them with
`// empty` in `jq`, not `// 0`.

---

## Top level

| Field | Type | Notes |
|---|---|---|
| `session_id` | string | Unique session id |
| `session_name` | string, optional | Set via `/rename` |
| `prompt_id` | string, optional | UUID of the prompt being processed (same as the OTel `prompt.id`) |
| `transcript_path` | string | Path to the conversation transcript |
| `cwd` | string | Current working directory |
| `version` | string | Claude Code version, e.g. `"2.1.267"` |
| `exceeds_200k_tokens` | boolean | Context is past 200k |
| `fast_mode` | boolean | Fast mode active |
| `output_style.name` | string | `"default"`, `"Explanatory"`, … |
| `thinking.enabled` | boolean | Extended thinking on for this session |

## `model`

```json
{ "id": "claude-opus-5", "display_name": "Opus 5 (1M context)" }
```

## `workspace`

| Field | Type | Notes |
|---|---|---|
| `current_dir` | string | |
| `project_dir` | string | Project root |
| `added_dirs` | string[] | Added via `/add-dir` |
| `git_worktree` | string, optional | Present when cwd is in a linked worktree |
| `repo` | object, optional | `{ host, owner, name }` from the origin remote |

## `context_window`

| Field | Type | Notes |
|---|---|---|
| `total_input_tokens` | number | Tokens in the context window, including cache reads/writes |
| `total_output_tokens` | number | Output tokens from the most recent API response |
| `context_window_size` | number | e.g. `200000`, `1000000` |
| `current_usage` | object \| null | `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` from the last call; `null` before the first |
| `used_percentage` | number \| null | Pre-computed 0–100 |
| `remaining_percentage` | number \| null | Pre-computed 0–100 |

`used_percentage` is the field to reach for — it already accounts for the
model's window size.

## `effort`

Present only on models that support reasoning effort.

```json
{ "level": "low" | "medium" | "high" | "xhigh" | "max" }
```

## `rate_limits`

Subscription plan usage, or a gateway spend limit. **Only present** for
subscribers (or behind a gateway that sets you a spend limit), **after the
first API response of the session**, and only while at least one window is
reported. Each window disappears once its `resets_at` has passed.

| Field | Type | Notes |
|---|---|---|
| `five_hour.used_percentage` | number | 0–100 |
| `five_hour.resets_at` | number | Unix epoch **seconds** |
| `seven_day.*` | same shape | Weekly limit |
| `spend_limit.*` | same shape | Gateway spend limit; can exceed 100 |

There is **no per-model window here** — see [Per-model weekly windows](#per-model-weekly-windows-not-in-the-payload).

## `prompt_cache`

Prompt-cache health for the main conversation. Present after the first API
response.

| Field | Type | Notes |
|---|---|---|
| `warm` | boolean | Cached prefix is inside its TTL right now. `false` when the last response reported no cache tokens |
| `caching_observed` | boolean | Any response reported cache tokens. `false` means the provider doesn't do caching — gate your display on this |
| `ttl` | `"5m"` \| `"1h"` | TTL the last request wrote |
| `expires_at` | number \| null | Unix seconds when the prefix goes cold |
| `requests` | number | Main-conversation requests this session |
| `misses` | number | Requests whose cached prefix shrank materially with no compaction explaining it |
| `expected_rebuilds` | number | Rebuilds a compaction or tool-result clearing announced — not failures |
| `hit_ratio` | number \| null | `cache_read / (cache_read + cache_creation + uncached input)`, 0–1 |
| `cache_write_tokens` | number | All `cache_creation` tokens this session |
| `miss_recache_tokens` | number | `cache_creation` tokens written by the requests counted as misses |
| `last_miss_at` | number \| null | Unix seconds |
| `last_miss_cause` | object \| null | See below |
| `miss_causes` | `{ cause: count }` | Misses per diagnosed cause |
| `recache_tokens_if_cold` | number \| null | Tokens the next request re-caches if the cache is cold by then; `null` right after a compaction |

`last_miss_cause.causes[]` comes from a closed set:

```
system_prompt_changed   tools_changed        model_changed
messages_rewritten      ttl_expired_5m       ttl_expired_1h
likely_server_side      unknown
```

Some causes carry extra counts: `tools_added`, `tools_removed`,
`system_char_delta`.

> **Read the booleans with `== true` / `== false`, not `// empty`.** `jq`'s
> `//` operator treats `false` as absent, so `.prompt_cache.warm // empty`
> silently discards a cold cache.

## `cost`

| Field | Type | Notes |
|---|---|---|
| `total_cost_usd` | number | Session tokens priced at the model's list rates. On a subscription this is **notional** — you are not billed it |
| `total_duration_ms` | number | Wall clock since session start |
| `total_api_duration_ms` | number | Time spent in API calls |
| `total_lines_added` | number | |
| `total_lines_removed` | number | |

## `pr`

Open PR/MR for the current branch, mirroring the footer badge.

| Field | Type | Notes |
|---|---|---|
| `number` | number | PR number, or GitLab MR iid |
| `url` | string | |
| `review_state` | string, optional | `approved`, `pending`, `changes_requested`, `draft` |
| `kind` | `"mr"`, optional | Present for GitLab merge requests; absent for GitHub PRs |

## `worktree`

Present only in a `--worktree` session: `name`, `path`, `branch` (optional),
`original_cwd`, `original_branch` (optional).

## `agent`, `vim`, `remote`

- `agent` — present when started with `--agent`: `{ name, type? }`
- `vim` — present when vim mode is on: `{ mode: "INSERT" | "NORMAL" | "VISUAL" | "VISUAL LINE" }`
- `remote` — `{ session_id }` for remote sessions

---

## Per-model weekly windows (not in the payload)

Plans with a per-model bucket (e.g. a weekly window scoped to one model) expose
that **only** through the account usage endpoint, not the status line payload:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token from ~/.claude/.credentials.json>
anthropic-beta: oauth-2025-04-20
```

The response carries a `limits[]` array alongside the flat windows:

```json
{
  "kind": "weekly_scoped",
  "group": "weekly",
  "percent": 13,
  "severity": "normal",
  "resets_at": "2026-09-16T11:00:00.397913+00:00",
  "scope": { "model": { "id": null, "display_name": "Fable" } },
  "is_active": false
}
```

`kind` is one of `session`, `weekly_all`, `weekly_scoped`. Note `resets_at`
here is an **ISO 8601 string**, unlike the epoch seconds in the payload.

> This endpoint is **undocumented** and may change or disappear without
> notice. Everything else in this document is part of the status line
> contract; this is not. `usage-refresh.sh` in this repo treats a failure as
> "no data" and hides the gauge rather than breaking the row.

---

## Rendering and refresh

- **Multi-line output is supported.** Print `\n` and each line renders as its
  own row beneath the input box.
- **ANSI escapes are honoured**, including 256-colour foreground and
  background (`\033[38;5;Nm`, `\033[48;5;Nm`). Claude Code paints unstyled
  status line text in grey `38;5;246`; your own colours pass through, and each
  `\033[0m` returns to that grey rather than the terminal default.
- **The dim attribute (`\033[2m`) renders very dark** on top of that grey. Use
  an explicit light grey such as `38;5;252` instead.
- **Avoid East Asian "ambiguous" width glyphs** (`★` U+2605, for example) —
  some terminals give them two columns and shift the rest of the row. `⋆`
  U+22C6 and `∗` U+2217 are narrow everywhere and sit vertically centred.
- **Block glyphs (`█ ▏ ░`) render at inconsistent heights** across fonts. A bar
  painted with background colours on plain spaces never misaligns.

### When it re-runs

- Every `refreshInterval` seconds (see settings below).
- On changes to: token usage, permission mode, vim mode, main loop model, fast
  mode, effort, thinking enabled, PR status.
- On a new assistant message.

Changes are debounced ~300 ms. The command is skipped entirely if workspace
trust has not been accepted.

## Settings

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "padding": 0,
    "refreshInterval": 30
  }
}
```

`refreshInterval` is in seconds, minimum 1. `padding: 0` lets the line start at
the left edge. Adding `statusLine` to a running session works — Claude Code
picks it up without a restart.
