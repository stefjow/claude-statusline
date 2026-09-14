#!/usr/bin/env bash
# Regenerates install.sh from statusline.sh and usage-refresh.sh in this repo,
# so the installer never drifts from the scripts beside it.
#   bash build-installer.sh
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$here" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1])
sl = (d / 'statusline.sh').read_text().rstrip('\n')
ur = (d / 'usage-refresh.sh').read_text().rstrip('\n')
for name, body in (('statusline.sh', sl), ('usage-refresh.sh', ur)):
    if '\nSTATUSLINE_PART_EOF\n' in body:
        sys.exit(f'{name} contains the heredoc delimiter; pick another')

tpl = r'''#!/usr/bin/env bash
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
@@STATUSLINE@@
STATUSLINE_PART_EOF

write usage-refresh.sh <<'STATUSLINE_PART_EOF'
@@REFRESH@@
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
printf '{"session_id":"1f0e9c7a-4b2d-4f19-9c3e-6a58d0b7e412","model":{"display_name":"Opus 5"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":24},"prompt_cache":{"caching_observed":true,"warm":true,"hit_ratio":0.94,"expires_at":%s},"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":%s},"seven_day":{"used_percentage":74,"resets_at":%s}}}' \
  "$PWD" "$(( now + 2400 ))" "$(( now + 3600 ))" "$(( now + 430000 ))" \
  | bash "$CLAUDE_DIR/statusline.sh"
echo
echo
echo "done - Claude Code picks this up within ~30s, no restart needed."
echo "The per-model gauge needs a claude.ai subscription login; it is skipped"
echo "silently on API-key, Bedrock, Vertex or gateway auth."
'''
out = tpl.replace('@@STATUSLINE@@', sl).replace('@@REFRESH@@', ur)
(d / 'install.sh').write_text(out)
print(f'wrote install.sh ({len(out.splitlines())} lines)')
PY
chmod +x "$here/install.sh"
bash -n "$here/install.sh" && echo "install.sh syntax ok"
