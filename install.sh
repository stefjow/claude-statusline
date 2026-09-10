#!/usr/bin/env bash
# Installs the two-row Claude Code status line (context, plan usage, prompt cache).
# https://github.com/stefjow/claude-statusline
#
#   bash install.sh
#
# Writes ~/.claude/statusline.sh and ~/.claude/usage-refresh.sh, then adds a
# "statusLine" entry to ~/.claude/settings.json, preserving everything else.
# Safe to re-run: existing files are backed up with a .bak-<timestamp> suffix.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
STAMP=$(date +%Y%m%d%H%M%S)

missing=""
for dep in jq curl; do command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"; done
if [ -n "$missing" ]; then
  echo "missing required tool(s):$missing" >&2
  echo "install them first (e.g. apt install jq curl / brew install jq curl)" >&2
  exit 1
fi

mkdir -p "$CLAUDE_DIR"

write() { # write <name>  (body on stdin)
  local target="$CLAUDE_DIR/$1"
  if [ -f "$target" ]; then
    cp "$target" "$target.bak-$STAMP"
    echo "  backed up $1 -> $1.bak-$STAMP"
  fi
  cat > "$target"
  chmod +x "$target"
  echo "  wrote $target"
}

echo "installing status line into $CLAUDE_DIR"

write statusline.sh <<'STATUSLINE_PART_EOF'
#!/usr/bin/env bash
# Claude Code status line, two rows:
#   row 1: model · effort · dir branch
#   row 2: gauge bars (percentage printed inside the bar) for context,
#          5h / weekly plan windows, and per-model
#          weekly windows (Fable, ...)
# Receives the statusline JSON on stdin (see "statusLine" in settings.json).
set -uo pipefail
export LC_ALL=C

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

CACHE="$HOME/.claude/usage-cache.json"
CACHE_MAX_AGE=${CLAUDE_USAGE_MAX_AGE:-900}   # hide cached windows older than this
BAR_CELLS=${CLAUDE_STATUSLINE_BAR_CELLS:-8}

RESET=$'\033[0m'
LIGHT=$'\033[38;5;252m'   # row-1 text, kept legible rather than dim
GREY=$'\033[38;5;245m'    # reset countdowns
# Separator between fields on both rows. ∗ (U+2217 asterisk operator) is drawn
# on the maths axis, so it sits vertically centred where a plain * rides high,
# and it is narrow-width everywhere — unlike ★, which is East Asian
# "ambiguous" and can eat two columns.
RULE_CHAR=${CLAUDE_STATUSLINE_RULE-∗}          # empty = plain gap
RULE_COLOR=${CLAUDE_STATUSLINE_RULE_COLOR-38;5;220}   # gold
if [ -n "$RULE_CHAR" ]; then
  RULE=" "$'\033['"${RULE_COLOR}m${RULE_CHAR}${RESET} "
else
  RULE='   '
fi
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'

# kick off a background refresh of the per-model windows when the cache has aged
# out; detached, so it never blocks this script
# GNU and BSD/macOS disagree on stat and date; keep both working
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
iso_epoch()  { date -d "$1" +%s 2>/dev/null \
               || date -j -f '%Y-%m-%dT%H:%M:%S' "${1%%.*}" +%s 2>/dev/null; }
cache_age()  { echo $(( $(date +%s) - $(file_mtime "$CACHE") )); }
if [ ! -f "$CACHE" ] || [ "$(cache_age)" -ge "${CLAUDE_USAGE_TTL:-180}" ]; then
  if command -v setsid >/dev/null 2>&1; then
    ( setsid bash "$HOME/.claude/usage-refresh.sh" >/dev/null 2>&1 & ) >/dev/null 2>&1
  else
    ( bash "$HOME/.claude/usage-refresh.sh" >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
fi

# green while there's room, red once the window is nearly spent
pct_color() {
  if   [ "$1" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 70 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# compact "45m" / "3h" / "2d" until a unix timestamp
until_reset() {
  local ts=$1 diff
  case $ts in ''|null) return;; esac
  diff=$(( ts - $(date +%s) ))
  [ "$diff" -le 0 ] && return
  if   [ "$diff" -ge 86400 ]; then printf '%dd' $(( diff / 86400 ))
  elif [ "$diff" -ge 3600 ];  then printf '%dh' $(( diff / 3600 ))
  else printf '%dm' $(( diff / 60 )); fi
}

# Each metric owns a hue: the bar fill is that colour, digits on the fill are
# black, digits past it are the same hue brightened against the grey trough.
# Severity is no longer carried by hue — it shows up as a ! marker instead.
TROUGH_BG='48;5;238'
metric_hue() {   # -> "<bg> <bright fg>"
  case $1 in
    CONTEXT) printf '48;5;38 38;5;87';;    # cyan
    5H)      printf '48;5;170 38;5;213';;  # magenta
    WK)      printf '48;5;71 38;5;114';;   # green
    SPEND)   printf '48;5;203 38;5;210';;  # coral
    CACHE)   printf '48;5;97 38;5;183';;   # violet
    *)       printf '48;5;178 38;5;221';;  # gold — model-scoped windows
  esac
}

# A BAR_CELLS-wide gauge with the percentage printed inside it. Every cell is a
# painted background — no block glyphs, which render at inconsistent heights in
# some fonts.
bar() {
  local raw=$1 bg=$2 fg=$3 pct=$1 n=$BAR_CELLS text len pad full out="" i idx ch
  [ "$pct" -gt 100 ] && pct=100
  text=$(printf '%d%%' "$raw"); len=${#text}
  pad=$(( (n - len) / 2 )); [ "$pad" -lt 0 ] && pad=0
  full=$(( (pct * n + 50) / 100 ))
  [ "$full" -eq 0 ] && [ "$pct" -gt 0 ] && full=1     # never hide a live window
  for (( i = 0; i < n; i++ )); do
    idx=$(( i - pad )); ch=' '
    if [ "$idx" -ge 0 ] && [ "$idx" -lt "$len" ]; then ch=${text:$idx:1}; fi
    if [ "$i" -lt "$full" ]; then
      out+=$'\033[30;'"${bg}m${ch}"
    else
      out+=$'\033['"${fg};${TROUGH_BG}m${ch}"
    fi
  done
  printf '%s%s' "$out" "$RESET"
}

# "CONTEXT ███37%░░"  /  "5H(-1h) ██15%░░░ !"
# mode: fill (default) warns as the bar fills; inverse warns as it empties,
# for gauges like cache hit ratio where high is healthy.
gauge() {
  local label=$1 pct=$2 ts=${3:-} mode=${4:-fill} left hue bg fg mark=""
  label=$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')   # bash 3.2 has no ${x^^}
  hue=$(metric_hue "$label"); bg=${hue%% *}; fg=${hue##* }
  case $ts in
    ''|null) left="";;
    *[!0-9]*) left="${GREY}(${ts})${RESET}";;                  # literal note, e.g. (cold/137k)
    *) left=$(until_reset "$ts"); [ -n "$left" ] && left="${GREY}(-${left})${RESET}";;
  esac
  if [ "$mode" = inverse ]; then
    if   [ "$pct" -lt 25 ]; then mark=" "$'\033[91m'"!${RESET}"
    elif [ "$pct" -lt 50 ]; then mark=" "$'\033[93m'"!${RESET}"
    fi
  else
    if   [ "$pct" -ge 90 ]; then mark=" "$'\033[91m'"!${RESET}"
    elif [ "$pct" -ge 70 ]; then mark=" "$'\033[93m'"!${RESET}"
    fi
  fi
  printf '%s%s%s%s %s%s' $'\033['"${fg}m" "$label" "$RESET" "$left" "$(bar "$pct" "$bg" "$fg")" "$mark"
}

# 137000 -> 137k, 1240000 -> 1.2M
fmt_tokens() {
  local t=$1
  if   [ "$t" -ge 1000000 ]; then printf '%d.%dM' $(( t / 1000000 )) $(( (t % 1000000) / 100000 ))
  elif [ "$t" -ge 1000 ];    then printf '%dk' $(( t / 1000 ))
  else printf '%d' "$t"; fi
}

join() { # join "$@" with a separator
  local sep=$1 out="" p; shift
  for p in "$@"; do
    [ -z "$p" ] && continue
    [ -n "$out" ] && out="${out}${sep}"
    out="${out}${p}"
  done
  printf '%s' "$out"
}

# ---------- row 1: who and where ----------
row1=()
model=$(j '.model.display_name')
case $model in ''|null) ;; *) row1+=("${CYAN}${model}${RESET}");; esac

effort=$(j '.effort.level // empty')
[ -n "$effort" ] && row1+=("${LIGHT}${effort}${RESET}")

cwd=$(j '.workspace.current_dir')
case $cwd in ''|null) ;; *)
  loc=$(basename "$cwd")
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -n "$branch" ] && loc="$loc ${LIGHT}${branch}${RESET}"
  row1+=("$loc");;
esac

# tokens currently in the context window
toks=$(j '.context_window.total_input_tokens // empty')
if [ -n "$toks" ] && [ "$toks" -gt 0 ] 2>/dev/null; then
  row1+=("${LIGHT}$(fmt_tokens "$toks")${RESET}${GREY} tok${RESET}")
fi

# prompt-cache health: hit ratio as the gauge, time until the prefix goes cold
# as the countdown. Only shown where the provider actually reports cache tokens.
if [ "$(j '.prompt_cache.caching_observed')" = "true" ]; then
  hit=$(j '.prompt_cache.hit_ratio | if . == null then empty else (. * 100 | round) end')
  if [ -n "$hit" ]; then
    if [ "$(j '.prompt_cache.warm')" = "true" ]; then
      note=$(j '.prompt_cache.expires_at // empty')
    else
      note="cold"
    fi
    row1+=("$(gauge cache "$hit" "$note" inverse)")
  fi
fi

# ---------- row 2: the gauges ----------
row2=()

ctx=$(j '.context_window.used_percentage | if . == null then empty else round end')
[ -n "$ctx" ] && row2+=("$(gauge context "$ctx")")

# 5h / weekly / gateway spend come live from the statusline payload
for w in five_hour:5h seven_day:wk spend_limit:spend; do
  key=${w%%:*}; label=${w##*:}
  used=$(j ".rate_limits.${key}.used_percentage | if . == null then empty else round end")
  [ -z "$used" ] && continue
  row2+=("$(gauge "$label" "$used" "$(j ".rate_limits.${key}.resets_at // empty")")")
done

# per-model weekly windows (Fable, ...) — not in the payload, so read the cached
# /api/oauth/usage response that usage-refresh.sh maintains
if [ -f "$CACHE" ] && [ "$(cache_age)" -lt "$CACHE_MAX_AGE" ]; then
  while IFS=$'\t' read -r name pct iso; do
    [ -z "$name" ] && continue
    ts=$(iso_epoch "$iso")
    row2+=("$(gauge "$name" "$pct" "${ts:-}")")
  done < <(jq -r '(.limits // [])[]
                  | select(.kind == "weekly_scoped" and .scope.model.display_name != null)
                  | [.scope.model.display_name, (.percent // 0 | round), (.resets_at // "")]
                  | @tsv' "$CACHE" 2>/dev/null)
fi

# ---------- emit ----------
line1=$(join "${RULE}" "${row1[@]-}")
line2=$(join "${RULE}" "${row2[@]-}")
if [ -n "$line1" ] && [ -n "$line2" ]; then
  printf '%s\n%s' "$line1" "$line2"
else
  printf '%s%s' "$line1" "$line2"
fi
STATUSLINE_PART_EOF

write usage-refresh.sh <<'STATUSLINE_PART_EOF'
#!/usr/bin/env bash
# Refreshes ~/.claude/usage-cache.json from the Claude usage endpoint.
# Run detached by statusline.sh; never blocks the status line itself.
# Uses the OAuth token Claude Code already stores locally; read-only GET.
set -uo pipefail
export LC_ALL=C

CREDS="$HOME/.claude/.credentials.json"
CACHE="$HOME/.claude/usage-cache.json"
LOCK="$HOME/.claude/usage-cache.lock"
TTL=${CLAUDE_USAGE_TTL:-180}   # seconds

[ -r "$CREDS" ] || exit 0

# one refresher at a time across sessions; flock where it exists (Linux),
# an atomic mkdir elsewhere (macOS ships no flock)
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK" || exit 0
  flock -n 9 || exit 0
else
  mkdir "${LOCK}.d" 2>/dev/null || exit 0
  trap 'rmdir "${LOCK}.d" 2>/dev/null' EXIT
fi

# still fresh? nothing to do
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $( stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0 ) ))
  [ "$age" -lt "$TTL" ] && exit 0
fi

tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS" 2>/dev/null)
[ -n "$tok" ] || exit 0
[ "$(( exp / 1000 ))" -gt "$(date +%s)" ] || exit 0   # expired; Claude Code will refresh it

tmp=$(mktemp "${CACHE}.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT

code=$(curl -sS -m 10 -o "$tmp" -w '%{http_code}' \
  https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $tok" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json" 2>/dev/null)

[ "$code" = "200" ] || exit 0
jq -e . "$tmp" >/dev/null 2>&1 || exit 0
chmod 600 "$tmp"
mv -f "$tmp" "$CACHE"
trap - EXIT
STATUSLINE_PART_EOF

# --- settings.json ------------------------------------------------------
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "$SETTINGS is not valid JSON; leaving it alone. Add this yourself:" >&2
  echo '  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh", "padding": 0, "refreshInterval": 30 }' >&2
  exit 1
fi
cp "$SETTINGS" "$SETTINGS.bak-$STAMP"
tmp=$(mktemp)
jq '.statusLine = {"type":"command","command":"bash ~/.claude/statusline.sh","padding":0,"refreshInterval":30}' \
   "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
echo "  patched $SETTINGS (backup: settings.json.bak-$STAMP)"

# --- smoke test ---------------------------------------------------------
now=$(date +%s)
echo
echo "preview:"
printf '{"model":{"display_name":"Opus 5"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":24,"total_input_tokens":241000},"prompt_cache":{"caching_observed":true,"warm":true,"hit_ratio":0.94,"expires_at":%s},"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":%s},"seven_day":{"used_percentage":74,"resets_at":%s}}}' \
  "$PWD" "$(( now + 2400 ))" "$(( now + 3600 ))" "$(( now + 430000 ))" \
  | bash "$CLAUDE_DIR/statusline.sh"
echo
echo
echo "done - Claude Code picks this up within ~30s, no restart needed."
echo "The per-model gauge needs a claude.ai subscription login; it is skipped"
echo "silently on API-key, Bedrock, Vertex or gateway auth."
