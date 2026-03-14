#!/bin/bash
mkdir -p "$HOME/.cache/claude-statusline"
token=""
creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
if [ -n "$creds" ]; then
  token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
fi
if [ -z "$token" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
fi
[ -z "$token" ] && exit 0
tmp="$HOME/.cache/claude-statusline/usage.json.tmp.$$"
curl -sf --max-time 5 \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "https://api.anthropic.com/api/oauth/usage" \
  -o "$tmp" && mv "$tmp" "$HOME/.cache/claude-statusline/usage.json" || rm -f "$tmp"
