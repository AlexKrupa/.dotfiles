import { atom, read, update } from 'claude-code'
import type { AgentInfo, EngineInterface, Register, SessionRateLimit } from 'claude-code'

import type { StatusText } from '../types'
import { agentRow, statusLine, type Facts } from './format'

const text = atom({ plugin: 'statusline', key: 'text' } as const, null as StatusText)

const REFRESH_MS = 5000
const TRANSCRIPT_CHUNK_BYTES = 4 * 1024 * 1024

type Transcript = {
  path: string
  offsetBytes: number
  title?: string
  aiTitle?: string
  cacheStampMs?: number
  cacheTtlSeconds?: number
}

type Usage = {
  cache_read_input_tokens?: number
  cache_creation_input_tokens?: number
  cache_creation?: { ephemeral_1h_input_tokens?: number; ephemeral_5m_input_tokens?: number }
}

// What the hooks learn between refreshes. A reload starts it over.
const seen: {
  model?: string
  effort?: string | number
  transcript?: Transcript
  reportedTitle?: string | null
  columns?: number
} = { reportedTitle: null }

// Reads only the bytes appended since the last call: a transcript grows to many MB.
async function readTranscript($: EngineInterface, state: Transcript): Promise<void> {
  const { size } = await $.fs.stat(state.path)
  if (size < state.offsetBytes) state.offsetBytes = 0
  while (state.offsetBytes < size) {
    const length = Math.min(size - state.offsetBytes, TRANSCRIPT_CHUNK_BYTES)
    const chunk = await $.fs.read(state.path, { offset: state.offsetBytes, length })
    const end = chunk.lastIndexOf('\n')
    if (end < 0) return
    const complete = chunk.slice(0, end + 1)
    state.offsetBytes += new TextEncoder().encode(complete).length
    for (const line of complete.split('\n')) readLine(state, line)
  }
}

function readLine(state: Transcript, line: string): void {
  if (line.includes('"type":"custom-title"')) {
    state.title = JSON.parse(line).customTitle || undefined
  } else if (line.includes('"type":"ai-title"')) {
    state.aiTitle = JSON.parse(line).aiTitle || undefined
  } else if (line.includes('"type":"assistant"')) {
    const entry = JSON.parse(line)
    const usage: Usage | undefined = entry.message?.usage
    if (usage === undefined) return
    if ((usage.cache_read_input_tokens ?? 0) > 0 || (usage.cache_creation_input_tokens ?? 0) > 0) {
      state.cacheStampMs = Date.parse(entry.timestamp)
    }
    if ((usage.cache_creation?.ephemeral_1h_input_tokens ?? 0) > 0) state.cacheTtlSeconds = 3600
    else if ((usage.cache_creation?.ephemeral_5m_input_tokens ?? 0) > 0) state.cacheTtlSeconds = 300
  }
}

async function readGit($: EngineInterface, cwd: string): Promise<Facts['git']> {
  const status = await $.process.run(
    ['git', '-C', cwd, '--no-optional-locks', 'status', '--porcelain=v2', '--branch', '--untracked-files=no'],
    { timeoutMs: 2000 },
  )
  if (status.exitCode !== 0) return undefined
  const lines = status.stdout.split('\n')
  const head = lines.find(l => l.startsWith('# branch.head '))?.slice(14)
  const oid = lines.find(l => l.startsWith('# branch.oid '))?.slice(13)
  const branch = head === '(detached)' ? oid?.slice(0, 7) : head
  if (!branch) return undefined
  return { branch, isDirty: lines.some(l => l !== '' && !l.startsWith('#')) }
}

// Shows the session title on herdr's sidebar agent row.
async function reportHerdrTitle($: EngineInterface, title: string | undefined): Promise<void> {
  if (title === seen.reportedTitle) return
  seen.reportedTitle = title
  const pane = await $.env.get('HERDR_PANE_ID')
  if ((await $.env.get('HERDR_ENV')) !== '1' || !pane) return
  // `/clear` drops a generated title, and the old one must not stay on the row.
  const token = title ? ['--token', `session=${title}`] : ['--clear-token', 'session']
  await $.process.run(
    ['herdr', 'pane', 'report-metadata', pane, '--source', 'herdr:claude', '--agent', 'claude', ...token],
    { timeoutMs: 2000 },
  )
}

async function refresh($: EngineInterface): Promise<void> {
  const [cwd, id, info, usage, home] = await Promise.all([
    $.session.cwd(),
    $.session.id(),
    $.session.info(),
    $.session.usage(),
    $.env.get('HOME'),
  ])
  if (seen.transcript?.path !== info.transcriptPath) {
    seen.transcript = { path: info.transcriptPath, offsetBytes: 0 }
  }
  const transcript = seen.transcript
  const [git] = await Promise.all([readGit($, cwd), readTranscript($, transcript).catch(() => {})])
  const title = transcript.title ?? transcript.aiTitle
  await reportHerdrTitle($, title).catch(() => {})
  seen.model ??= await $.session.model()
  seen.effort ??= (await $.settings.read({ key: 'effortLevel' })) as string | undefined

  const limit = (kind: string): SessionRateLimit | undefined =>
    usage.rateLimits.find(l => l.kind === kind)
  const facts: Facts = {
    nowMs: Date.now(),
    cwd,
    home,
    git,
    title,
    sessionId: id,
    model: seen.model,
    effort: seen.effort,
    contextPercent: usage.context.percent,
    contextWindow: usage.context.window,
    fiveHour: limit('five_hour'),
    sevenDay: limit('seven_day'),
    cacheStampMs: transcript.cacheStampMs,
    cacheTtlSeconds: transcript.cacheTtlSeconds,
    columns: seen.columns,
  }
  await update($, text, () => statusLine(facts))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    void refresh($).catch(() => {})
    $.clock.every(REFRESH_MS, () => void refresh($).catch(() => {}))
    return result
  })

  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined) {
      const isChanged = seen.model !== e.model || seen.effort !== e.effort
      seen.model = e.model
      seen.effort = e.effort
      if (isChanged) void refresh($).catch(() => {})
    }
    return yield* next(e)
  })

  on('session.measure', async ($, e, next) => {
    void refresh($).catch(() => {})
    return next(e)
  })

  on('ui.render', { component: 'StatusLine' }, async ($, e, next) => {
    seen.columns = e.viewport?.columns
    const line = await read($, text)
    if (line === null) return next(e)
    return next({ ...e, props: { ...e.props, text: line } })
  })

  on('ui.render', { component: 'AgentRow' }, ($, e, next) => {
    const agent: AgentInfo = e.props
    const body = agentRow(agent, seen.effort, Date.now())
    return next({ ...e, props: { ...e.props, body } })
  })
}
