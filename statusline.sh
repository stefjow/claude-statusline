#!/usr/bin/env bash
# Claude Code status line, two rows:
#   row 1: model · effort · dir branch · session id
#   row 2: gauge bars (percentage printed inside the bar) for context,
#          5h / weekly plan windows, per-model weekly windows (Fable, ...)
#          and prompt-cache health
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

# compact "45m" / "3h20m" / "1d4h" until a unix timestamp. Two units, because
# a bare "1d" leaves up to 24 hours open; the smaller unit is dropped when zero.
until_reset() {
  local ts=$1 diff rest
  case $ts in ''|null) return;; esac
  diff=$(( ts - $(date +%s) ))
  [ "$diff" -le 0 ] && return
  if [ "$diff" -ge 86400 ]; then
    rest=$(( diff % 86400 / 3600 ))
    if [ "$rest" -gt 0 ]; then printf '%dd%dh' $(( diff / 86400 )) "$rest"
    else printf '%dd' $(( diff / 86400 )); fi
  elif [ "$diff" -ge 3600 ]; then
    rest=$(( diff % 3600 / 60 ))
    if [ "$rest" -gt 0 ]; then printf '%dh%dm' $(( diff / 3600 )) "$rest"
    else printf '%dh' $(( diff / 3600 )); fi
  else
    printf '%dm' $(( diff / 60 ))
  fi
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
case $model in ''|null) ;; *) row1+=("${GREY}MODEL:${RESET}${CYAN}${model}${RESET}");; esac

effort=$(j '.effort.level // empty')
[ -n "$effort" ] && row1+=("${GREY}EFFORT:${RESET}${LIGHT}${effort}${RESET}")

cwd=$(j '.workspace.current_dir')
case $cwd in ''|null) ;; *)
  row1+=("${GREY}DIR:${RESET}$(basename "$cwd")")
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -n "$branch" ] && row1+=("${GREY}BRANCH:${RESET}${LIGHT}${branch}${RESET}");;
esac

# session id, for --resume and for finding the transcript again
sid=$(j '.session_id // empty')
case $sid in ''|null) ;; *) row1+=("${GREY}SESSION:${RESET}${CYAN}${sid}${RESET}");; esac

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
    row2+=("$(gauge cache "$hit" "$note" inverse)")
  fi
fi

# ---------- emit ----------
line1=$(join "${RULE}" "${row1[@]-}")
line2=$(join "${RULE}" "${row2[@]-}")
if [ -n "$line1" ] && [ -n "$line2" ]; then
  printf '%s\n%s' "$line1" "$line2"
else
  printf '%s%s' "$line1" "$line2"
fi
