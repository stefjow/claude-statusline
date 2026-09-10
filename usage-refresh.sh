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
