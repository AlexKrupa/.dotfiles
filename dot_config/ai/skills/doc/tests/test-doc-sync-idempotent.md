# Pressure test: `/doc-sync` must be idempotent

Purpose: verify `skills/doc-sync/SKILL.md`'s dedupe rule prevents duplicate entries when run twice in one session.

## Setup

Seed an active doc with one decision and an obvious-to-record commit:

```bash
tmp=$(mktemp -d)
mkdir -p "$tmp/docs"
cat > "$tmp/docs/cache-layer.md" <<'EOF'
---
title: Cache layer
status: active
created: 2026-05-22
updated: 2026-05-23
---

## Context

Adding read-through cache for the user-prefs service.

## Decisions

- Chose Redis over Memcached because we already run Redis for sessions (2026-05-22)

## Open questions

- Cache key namespace shared with sessions?

## TODO

- [-] Wire Redis client
- [ ] Add invalidation on write
EOF
```

Stage one commit that finishes "Wire Redis client" and adds a real decision (TTL = 5 min for prefs, chosen over 60s after measuring hit rate).

## Run

Dispatch via Agent tool. Two turns:

**Turn 1:**

> I just wired the Redis client and picked a 5-minute TTL after seeing the hit rate plateau. Run `/doc-sync`.

**Turn 2 (same session, immediately after):**

> Just to be safe, run `/doc-sync` again.

## Expected behavior

After turn 1:

- `[-] Wire Redis client` becomes `[x]`.
- `## Decisions` gains one entry containing "5-minute TTL" (or "5 min", etc).
- `updated:` becomes today's date.

After turn 2:

- File **byte-identical** to the post-turn-1 state, OR the agent reports "no changes - already in sync".
- No new decision appended even if phrasing is slightly different from the existing one.
- `updated:` not bumped (no actual change).

## Failure modes

- Second run appends "Chose 5 min TTL because..." next to the first - duplicate.
- Second run bumps `updated:` despite no semantic change.
- Agent re-marks already-`[x]` items, producing diff noise.

If any happens, tighten the dedupe rule in `skills/doc-sync/SKILL.md` (e.g. lower substring threshold, normalize whitespace/punctuation) and re-run.
