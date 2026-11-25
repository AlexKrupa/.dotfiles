import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { View } from '../types'

const MR = 'https://g/a/b/-/merge_requests/410'

const BAND = {
  plugin: 'watchd',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: false,
    maxRows: 20,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 19 },
    view: {},
  },
} as const

function stack(): View {
  return {
    key: 'app-1',
    path: '/r-wt',
    hub: false,
    heading: 'APP-1',
    branch_count: 2,
    artifacts: [{ kind: 'ticket', target: 'https://t/APP-1' }],
    branches: [
      {
        name: 'a/APP-1-x',
        title: 'Extract repo',
        iid: 410,
        status: ['ready to merge'],
        rows: [
          { id: 2, section: 'NeedsYou', kind: 'comment', what: '@bob: "Why?"', result: 'Reply', url: null },
        ],
        artifacts: [
          { kind: 'MR', target: MR },
          { kind: 'pipeline', target: 'https://g/a/b/-/pipelines/7' },
        ],
      },
      { name: 'a/APP-1-y', title: 'a/APP-1-y', iid: null, status: [], rows: [], artifacts: [] },
    ],
  }
}

function line(view: View): string {
  return JSON.stringify({ type: 'view', ...view }) + '\n'
}

/**
 * Each `watchd follow` writes the text of its turn, then ends. A `null` turn exits 1.
 * Returns the count of starts. Also answers the session start, the debug log, and `HOME`.
 */
function follow(on: On, texts: (string | null)[]): { starts: number } {
  const calls = { starts: 0 }
  mock.env(on, { HOME: '/home/u' })
  on('process.spawn', async function* (_, e) {
    expect(e.argv).toEqual(['watchd', 'follow'])
    const text = calls.starts < texts.length ? texts[calls.starts]! : ''
    calls.starts += 1
    if (text === null) {
      return { value: { code: 1, signal: null } }
    }
    if (text !== '') {
      yield { stream: 'stdout' as const, text }
    }
    return { value: { code: 0, signal: null } }
  })
  on('ui.log', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  return calls
}

async function start($: Engine, cwd: string) {
  await $.session.start({ cwd, surface: 'terminal', isInteractive: true })
}

async function texts(ui: { findAll: (query: { type: 'Text' }) => Promise<{ text: string }[]> }) {
  return (await ui.findAll({ type: 'Text' })).map(found => found.text)
}

test('draws_a_stack_view', async ($, on) => {
  const clock = mock.clock(on)
  follow(on, [line(stack())])
  await start($, '/r-wt')
  await clock.settle()

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    const all = (await texts(ui)).join('\n')

    for (const part of ['APP-1 · stack of 2', 'Extract repo · !410 · ready to merge', '● comment', '→ Reply', '↗ MR', MR]) {
      expect(all).toContain(part)
    }
    await ui.unmount()
  }
})

test('aligns_kinds_with_a_gap_of_3', async ($, on) => {
  const clock = mock.clock(on)
  follow(on, [line(stack())])
  await start($, '/r-wt')
  await clock.settle()

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const label = (await texts(ui)).find(text => text.startsWith('↗ MR'))

  // The border and the padding take the first 2 columns, the arrow and its space the next 2.
  expect(label).toBe('↗ ' + 'MR'.padEnd(8 + 3))
  await ui.unmount()
})

test('draws_nothing_with_no_view', async ($, on) => {
  const clock = mock.clock(on)
  follow(on, [])
  await start($, '/elsewhere')
  await clock.settle()

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect(await texts(ui)).toEqual([])
  await ui.unmount()
})

test('yields_to_a_survey', async ($, on) => {
  const clock = mock.clock(on)
  follow(on, [line(stack())])
  await start($, '/r-wt')
  await clock.settle()

  const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props, hasSurvey: true }, surface: 'terminal' })

  expect(await texts(ui)).toEqual([])
  await ui.unmount()
})

test('wraps_a_long_target', async ($, on) => {
  const clock = mock.clock(on)
  const url = 'https://g/' + 'x'.repeat(190)
  const view = stack()
  view.branches = view.branches.map(branch => ({ ...branch, artifacts: [{ kind: 'MR', target: url }] }))
  follow(on, [line(view)])
  await start($, '/r-wt')
  await clock.settle()

  const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props, bodyColumns: 60 }, surface: 'terminal' })
  const target = await ui.find({ type: 'Text', text: url })

  expect(target?.text).toBe(url)
  expect(target?.props.wrap ?? 'wrap').toBe('wrap')
  await ui.unmount()
})

test('starts_follow_again_after_the_end', async ($, on) => {
  const clock = mock.clock(on)
  const calls = follow(on, [line(stack())])
  await start($, '/r-wt')
  await clock.settle()

  await clock.advance(2000)

  expect(calls.starts).toBe(2)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await texts(ui)).join('\n')).toContain('Extract repo')
  await ui.unmount()
})

test('picks_the_view_of_the_session_folder', async ($, on) => {
  const clock = mock.clock(on)
  const hub: View = { ...stack(), key: 'app', path: '/r', hub: true, heading: null }
  hub.branches = [{ ...stack().branches[0]!, title: 'Hub MR' }]
  const worktree: View = { ...stack(), key: 'app-wt', path: '/r-wt' }
  const root: View = { ...stack(), key: 'app-root', path: '/r' }
  root.branches = [{ ...stack().branches[0]!, title: 'Root MR' }]
  follow(on, [line(hub) + line(worktree) + line(root), line(hub) + line(worktree) + line(root)])

  await start($, '/r-wt/src')
  await clock.settle()
  const inWorktree = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await texts(inWorktree)).join('\n')).toContain('Extract repo')
  await inWorktree.unmount()

  await start($, '/r')
  await clock.advance(2000)
  const inRoot = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await texts(inRoot)).join('\n')).toContain('Hub MR')
  await inRoot.unmount()
})

const HOME = '/home/u'

/** The argument vectors of `$.process.run`; `fails` makes each call reject. */
function runs(on: On, fails = false): (readonly string[])[] {
  const calls: (readonly string[])[] = []
  mock.env(on, { HOME })
  on('process.run', (_, e) => {
    calls.push(e.argv)
    if (fails) {
      throw new Error('watchd: no such file')
    }
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('tool.call', () => ({ result: {} }))
  on('ui.log', () => ({ value: undefined }))
  return calls
}

test('records_a_written_spec', async ($, on) => {
  const calls = runs(on)

  await $.tool.call({ tool: 'Write', file_path: `${HOME}/.ai/app/specs/a.md`, content: '# A' })

  expect(calls).toEqual([['watchd', 'artifact', 'spec', `${HOME}/.ai/app/specs/a.md`]])
})

test('records_a_read_handoff_only', async ($, on) => {
  const calls = runs(on)

  await $.tool.call({ tool: 'Read', file_path: `${HOME}/.ai/app/specs/a.md` })
  await $.tool.call({ tool: 'Read', file_path: `${HOME}/.ai/app/handoffs/h.md` })

  expect(calls).toEqual([['watchd', 'artifact', 'handoff', `${HOME}/.ai/app/handoffs/h.md`]])
})

test('ignores_a_write_outside_the_ai_folders', async ($, on) => {
  const calls = runs(on)

  await $.tool.call({ tool: 'Write', file_path: `${HOME}/.ai/app/notes/a.md`, content: 'x' })
  await $.tool.call({ tool: 'Write', file_path: '/tmp/a.md', content: 'x' })

  expect(calls).toEqual([])
})

test('a_failed_call_does_not_block_the_tool', async ($, on) => {
  const calls = runs(on, true)

  const result = await $.tool.call({ tool: 'Write', file_path: `${HOME}/.ai/app/prs/p.md`, content: '# P' })

  expect(calls).toEqual([['watchd', 'artifact', 'MR draft', `${HOME}/.ai/app/prs/p.md`]])
  expect(result.deny).toBeUndefined()
  expect(result.isError ?? false).toBe(false)
})

test('forgets_the_views_of_an_ended_stream_at_the_first_new_line', async ($, on) => {
  const clock = mock.clock(on)
  follow(on, [line(stack()), '{"type": "sidebar"}\n'])
  await start($, '/r-wt')
  await clock.settle()

  await clock.advance(2000)

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await texts(ui)).toEqual([])
  await ui.unmount()
})

test('draws_nothing_when_follow_fails', async ($, on) => {
  const clock = mock.clock(on)
  follow(on, [line(stack()), null])
  await start($, '/r-wt')
  await clock.settle()

  await clock.advance(2000)

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await texts(ui)).toEqual([])
  await ui.unmount()
})

test('shows_a_file_under_home_with_a_tilde', async ($, on) => {
  const clock = mock.clock(on)
  const view = stack()
  view.artifacts = [{ kind: 'spec', target: '/home/u/.ai/app/specs/a.md' }]
  follow(on, [line(view)])
  await start($, '/r-wt')
  await clock.settle()

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect(await texts(ui)).toContain('~/.ai/app/specs/a.md')
  await ui.unmount()
})

test('puts_a_target_that_does_not_fit_under_its_label', async ($, on) => {
  const clock = mock.clock(on)
  const view = stack()
  view.branches = view.branches.map(branch => ({
    ...branch,
    artifacts: [{ kind: 'MR', target: 'https://g/' + 'x'.repeat(40) }],
  }))
  follow(on, [line(view)])
  await start($, '/r-wt')
  await clock.settle()

  const wide = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const beside = await wide.find({ key: 'artifact-0-0' })
  await wide.unmount()
  const narrow = await $.ui.mount({ ...BAND, props: { ...BAND.props, bodyColumns: 60 }, surface: 'terminal' })
  const under = await narrow.find({ key: 'artifact-0-0' })
  await narrow.unmount()

  expect(beside?.props.flexDirection).toBe('row')
  expect(under?.props.flexDirection).toBe('column')
})
