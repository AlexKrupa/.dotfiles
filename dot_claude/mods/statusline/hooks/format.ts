import type { AgentInfo, SessionRateLimit } from 'claude-code'

// Line 2 segment order. Reorder or drop keys.
const SEGMENT_ORDER = ['model', 'ctx', 'cache', 'usage'] as const

const CTX_RED_AT = 50
const CTX_YELLOW_AT = 25
const UTIL_RED_AT = 80
const UTIL_YELLOW_AT = 50
const CACHE_GREEN_AT_SECONDS = 600
const CACHE_YELLOW_AT_SECONDS = 120
const CACHE_TTL_DEFAULT_SECONDS = 3600
// Show a window's reset time when its utilization % is at least this.
const USAGE_RESET_AT = 50
const USAGE_MIN_COLUMNS = 80

const CACHE_ICON = '⏱'
const CACHE_EXPIRED = '∅'

// Dracula palette as truecolor, no bold: the status line over-brightens bold.
const C_PATH = '\x1b[38;2;139;233;253m'
const C_GIT = '\x1b[38;2;189;147;249m'
const C_RED = '\x1b[31m'
const C_YELLOW = '\x1b[33m'
const C_GREEN = '\x1b[32m'
const C_DIM = '\x1b[2m'
const C_RESET = '\x1b[0m'

const SEP = `${C_DIM}·${C_RESET}`
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

export type Facts = {
  nowMs: number
  cwd: string
  home?: string
  git?: { branch: string; isDirty: boolean }
  title?: string
  sessionId: string
  model?: string
  effort?: string | number
  contextPercent?: number
  contextWindow: number
  fiveHour?: SessionRateLimit
  sevenDay?: SessionRateLimit
  cacheStampMs?: number
  cacheTtlSeconds?: number
  columns?: number
}

const paint = (color: string, value: string) => `${color}${value}${C_RESET}`

function pctColor(percent: number | undefined): string {
  if (percent === undefined) return C_DIM
  if (percent >= CTX_RED_AT) return C_RED
  if (percent >= CTX_YELLOW_AT) return C_YELLOW
  return C_GREEN
}

function utilColor(percent: number): string {
  if (percent >= UTIL_RED_AT) return C_RED
  if (percent >= UTIL_YELLOW_AT) return C_YELLOW
  return C_GREEN
}

function cacheColor(seconds: number): string {
  if (seconds >= CACHE_GREEN_AT_SECONDS) return C_GREEN
  if (seconds >= CACHE_YELLOW_AT_SECONDS) return C_YELLOW
  return C_RED
}

// 1000000 -> 1M, 48000 -> 48k
function formatTokens(count: number | undefined): string {
  if (count === undefined) return '?'
  if (count >= 1_000_000) return `${Math.floor((count + 500_000) / 1_000_000)}M`
  return `${Math.floor((count + 500) / 1000)}k`
}

// claude-opus-5-5[1m] -> "Opus 5.5", claude-haiku-4-5-20251001 -> "Haiku 4.5"
function formatModel(id: string): string {
  const bare = id.replace(/^claude-/, '').replace(/\[.*$/, '').replace(/-\d{8}$/, '')
  const [name = '', ...version] = bare.split('-')
  const head = name.charAt(0).toUpperCase() + name.slice(1)
  return version.length > 0 ? `${head} ${version.join('.')}` : head
}

// Absent effort, a numeric budget and Haiku get no suffix.
function modelSegment(model: string, effort: string | number | undefined): string {
  const name = formatModel(model)
  if (typeof effort !== 'string' || !/^[a-z]+$/.test(effort) || model.includes('haiku')) return name
  return `${name} ${effort.charAt(0).toUpperCase()}`
}

// First letter of each directory but the last: ~/src/me/project -> ~/s/m/project
function shortenPath(cwd: string, home: string | undefined): string {
  const path = home && (cwd === home || cwd.startsWith(`${home}/`)) ? `~${cwd.slice(home.length)}` : cwd
  const parts = path.split('/')
  if (parts.length <= 1) return path
  const heads = parts
    .slice(0, -1)
    .filter(part => part !== '')
    .map(part => part.match(/^[^\p{L}\p{N}]*[\p{L}\p{N}]/u)?.[0] ?? part)
  return [...heads, parts[parts.length - 1]].join('/')
}

function formatTime(epochMs: number, withWeekday: boolean): string {
  const date = new Date(epochMs)
  const clock = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
  return withWeekday ? `${WEEKDAYS[date.getDay()]} ${clock}` : clock
}

function usageWindow(label: string, limit: SessionRateLimit | undefined, withWeekday: boolean): string {
  if (limit === undefined) return ''
  const percent = Math.round(limit.percentUsed)
  const segment = `${label}:${paint(utilColor(percent), `${percent}%`)}`
  if (percent < USAGE_RESET_AT || limit.resetsAt === undefined) return segment
  const resetsMs = Math.round(Date.parse(limit.resetsAt) / 60_000) * 60_000
  return `${segment} → ${formatTime(resetsMs, withWeekday)}`
}

function cacheSegment(facts: Facts): string {
  if (facts.cacheStampMs === undefined) return ''
  const ttlSeconds = facts.cacheTtlSeconds ?? CACHE_TTL_DEFAULT_SECONDS
  const leftSeconds = Math.max(0, Math.floor((facts.cacheStampMs - facts.nowMs) / 1000) + ttlSeconds)
  const left = leftSeconds >= 60 ? `${Math.floor(leftSeconds / 60)}m` : leftSeconds > 0 ? `${leftSeconds}s` : CACHE_EXPIRED
  return `${CACHE_ICON} ${paint(cacheColor(leftSeconds), left)}`
}

export function statusLine(facts: Facts): string {
  const top = [paint(C_PATH, shortenPath(facts.cwd, facts.home))]
  if (facts.git) top.push(paint(C_GIT, `${facts.git.branch}${facts.git.isDirty ? '*' : ''}`))
  if (facts.title) top.push(facts.title)
  if (facts.sessionId) top.push(paint(C_DIM, facts.sessionId))

  const percent = facts.contextPercent === undefined ? undefined : Math.floor(facts.contextPercent)
  const usage = [usageWindow('5h', facts.fiveHour, false), usageWindow('7d', facts.sevenDay, true)]
    .filter(segment => segment !== '')
    .join(` ${SEP} `)
  const isWide = facts.columns === undefined || facts.columns >= USAGE_MIN_COLUMNS
  const segments: Record<(typeof SEGMENT_ORDER)[number], string> = {
    model: facts.model ? modelSegment(facts.model, facts.effort) : '',
    ctx: `${paint(pctColor(percent), `${percent ?? '?'}%`)} ${formatTokens(facts.contextWindow)}`,
    cache: cacheSegment(facts),
    usage: isWide ? usage : '',
  }
  const bottom = SEGMENT_ORDER.map(key => segments[key]).filter(segment => segment !== '')

  return `${top.join(` ${SEP} `)}\n${bottom.join(` ${SEP} `)}`
}

function statusDot(agent: AgentInfo): string {
  switch (agent.status) {
    case 'running':
      return paint(C_GREEN, '●')
    case 'failed':
      return paint(C_RED, '●')
    case 'pending':
    case 'waiting':
    case 'idle':
    case 'completed':
    case 'killed':
      return paint(C_DIM, '●')
  }
}

// Elapsed since the start: "Xm Ys" or "Ys"
function formatElapsed(startMs: number, nowMs: number): string {
  const seconds = Math.max(0, Math.floor((nowMs - startMs) / 1000))
  const minutes = Math.floor(seconds / 60)
  return minutes > 0 ? `${minutes}m ${seconds % 60}s` : `${seconds}s`
}

// <dot> <description> [<type>] · <model> <effort> · <context> · <elapsed>
export function agentRow(agent: AgentInfo, sessionEffort: string | number | undefined, nowMs: number): string {
  let row = `${statusDot(agent)} ${agent.description || agent.name || ''}`
  if (agent.type) row += ` ${paint(C_DIM, `[${agent.type}]`)}`
  if (agent.model) row += ` ${SEP} ${modelSegment(agent.model, agent.effort ?? sessionEffort)}`
  const window = agent.contextWindowSize
  const percent = window !== undefined && window > 0 ? Math.floor((agent.tokenCount * 100) / window) : undefined
  const context = percent === undefined ? formatTokens(agent.tokenCount) : paint(pctColor(percent), `${percent}%`)
  row += ` ${SEP} ${context}`
  if (agent.startTime) row += ` ${SEP} ${formatElapsed(agent.startTime, nowMs)}`
  return row
}
