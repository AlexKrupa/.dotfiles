import { expect, test } from 'claude-code/testing'
import type { AgentInfo } from 'claude-code'

import { agentRow, statusLine, type Facts } from '../hooks/format'

const plain = (styled: string) => styled.replace(/\x1b\[[0-9;]*m/g, '')

const facts: Facts = {
  nowMs: Date.parse('2026-11-28T12:00:00Z'),
  cwd: '/Users/me/src/.hidden/project',
  home: '/Users/me',
  git: { branch: 'main', isDirty: true },
  title: 'Status line migration',
  sessionId: 'abc-123',
  model: 'claude-opus-5-5[1m]',
  effort: 'medium',
  contextPercent: 31.7,
  contextWindow: 1_000_000,
  fiveHour: { kind: 'five_hour', percentUsed: 12.4 },
  sevenDay: { kind: 'seven_day', percentUsed: 40 },
  cacheStampMs: Date.parse('2026-11-28T11:50:00Z'),
  cacheTtlSeconds: 3600,
}

test('status line draws the path, git, title, model, context, cache and usage', async () => {
  expect(plain(statusLine(facts))).toBe(
    '~/s/.h/project · main* · Status line migration · abc-123\n' +
      'Opus 5.5 M · 31% 1M · ⏱ 50m · 5h:12% · 7d:40%',
  )
})

test('status line drops usage below 80 columns and the effort for Haiku', async () => {
  const line = statusLine({ ...facts, columns: 79, model: 'claude-haiku-4-5-20251001', cacheStampMs: undefined })
  expect(plain(line).split('\n')[1]).toBe('Haiku 4.5 · 31% 1M')
})

test('agent row draws the description, type, model, effort, context and elapsed time', async () => {
  const agent = {
    description: 'Explore the code',
    type: 'Explore',
    status: 'running',
    model: 'claude-sonnet-5-5',
    tokenCount: 50_000,
    contextWindowSize: 200_000,
    startTime: facts.nowMs - 75_000,
  } as AgentInfo
  expect(plain(agentRow(agent, 'high', facts.nowMs))).toBe('● Explore the code [Explore] · Sonnet 5.5 H · 25% · 1m 15s')
})
