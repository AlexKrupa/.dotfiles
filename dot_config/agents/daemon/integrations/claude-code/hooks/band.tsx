import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Artifact, Branch, View, ViewRow } from '../types'

const shownView = atom({ plugin: 'watchd', key: 'view' } as const, null, { shape: 'view-1' })

const RESTART_MS = 2000
const LABEL_GAP = 3
/** The border and the padding on both sides of the band. */
const FRAME_COLUMNS = 4
/** A bullet and its space. */
const BULLET_COLUMNS = 2

/**
 * The view of the folder: the view with the longest path that contains it. At the same path,
 * the hub view wins.
 */
function pick(views: Map<string, View>, folder: string): View | null {
  const containing = [...views.values()].filter(
    view => folder === view.path || folder.startsWith(view.path + '/'),
  )
  containing.sort((a, b) => b.path.length - a.path.length || Number(b.hub) - Number(a.hub))
  return containing[0] ?? null
}

function isEmpty(view: View): boolean {
  return (
    view.artifacts.length === 0 &&
    view.branches.every(branch => branch.rows.length === 0 && branch.artifacts.length === 0)
  )
}

function headingOf(view: View): string | null {
  if (view.hub) {
    return null
  }
  if (view.branch_count > 1) {
    return view.heading === null ? `Stack of ${view.branch_count}` : `${view.heading} · stack of ${view.branch_count}`
  }
  return view.heading
}

/** The views of `watchd follow` by key, the folder of the session, and `HOME`. */
const views = new Map<string, View>()
let folder = ''
let home = ''
let following = false

/** A file under `HOME` as `~/...`: shorter, and herdr-pluck opens it. */
function shown(target: string): string {
  return home !== '' && target.startsWith(home + '/') ? '~' + target.slice(home.length) : target
}

function show($: EngineInterface) {
  const view = pick(views, folder)
  return update($, shownView, () => view)
}

/** The first lines of a new stream have all views: the views of the stream before go. */
async function take($: EngineInterface, text: string, isFirst: boolean) {
  if (isFirst) {
    views.clear()
  }
  for (const line of text.split('\n')) {
    if (line.trim() === '') {
      continue
    }
    const value = JSON.parse(line)
    if (value.type !== 'view') {
      continue
    }
    if (value.removed === true) {
      views.delete(value.key)
    } else {
      const { type: _, ...view } = value
      views.set(view.key, view as View)
    }
  }
  await show($)
}

/**
 * Runs `watchd follow` for the life of the module, and again after each end. After an end, the
 * band keeps the last view until the first new line. After a failure, it draws nothing.
 */
async function follow($: EngineInterface) {
  for (;;) {
    let pending = ''
    let isFirst = true
    try {
      const follower = $.process.spawn({ argv: ['watchd', 'follow'] })
      for await (const { stream, text } of follower) {
        if (stream === 'stderr') {
          $.ui.log(`watchd follow: ${text}`, { to: 'debug' })
          continue
        }
        const end = (pending + text).lastIndexOf('\n')
        const complete = (pending + text).slice(0, end + 1)
        pending = (pending + text).slice(end + 1)
        if (complete !== '') {
          await take($, complete, isFirst)
          isFirst = false
        }
      }
      const { code } = await follower.result
      if (code !== 0) {
        throw new Error(`exit ${code}`)
      }
      $.ui.log('watchd follow ended, starting it again', { to: 'debug' })
    } catch (error) {
      $.ui.log(`watchd follow failed: ${String(error)}`, { to: 'debug' })
      views.clear()
      await show($)
    }
    await $.clock.sleep(RESTART_MS)
  }
}

/** The kind of a file under `~/.ai/<repo>/<folder>/` by folder. A read records only a handoff. */
const WRITTEN_KINDS: Record<string, string> = {
  specs: 'spec',
  plans: 'plan',
  reviews: 'review',
  handoffs: 'handoff',
  prs: 'MR draft',
  tickets: 'ticket draft',
}

function artifactKind(home: string, path: string, tool: 'Write' | 'Read'): string | null {
  const prefix = `${home}/.ai/`
  if (!path.startsWith(prefix)) {
    return null
  }
  const [repo, folder, ...file] = path.slice(prefix.length).split('/')
  const kind = WRITTEN_KINDS[folder ?? '']
  if (!repo || kind === undefined || file.join('/') === '') {
    return null
  }
  return tool === 'Write' || kind === 'handoff' ? kind : null
}

/** A failed call goes to the debug log: the tool call does not wait for watchd. */
async function record($: EngineInterface, tool: 'Write' | 'Read', path: string) {
  const home = await $.env.get('HOME')
  const kind = home === undefined ? null : artifactKind(home, path, tool)
  if (kind === null) {
    return
  }
  try {
    const run = await $.process.run(['watchd', 'artifact', kind, path])
    if (run.exitCode !== 0) {
      $.ui.log(`watchd artifact ${kind} ${path}: ${run.stderr}`, { to: 'debug' })
    }
  } catch (error) {
    $.ui.log(`watchd artifact ${kind} ${path}: ${String(error)}`, { to: 'debug' })
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    folder = e.cwd
    home = (await $.env.get('HOME')) ?? ''
    await show($)
    if (!following) {
      following = true
      // The loop ends only when the module unloads, and its last wait then rejects.
      follow($).catch(() => undefined)
    }
    return started
  })

  on('tool.call', { tool: 'Write' }, async ($, e, next) => {
    const result = await next(e)
    if (result.deny === undefined && result.isError !== true) {
      await record($, 'Write', e.file_path)
    }
    return result
  })

  on('tool.call', { tool: 'Read' }, async ($, e, next) => {
    const result = await next(e)
    if (result.deny === undefined && result.isError !== true) {
      await record($, 'Read', e.file_path)
    }
    return result
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const view = await read($, shownView)
    if (e.props.hasSurvey || view === null || isEmpty(view)) {
      return next(e)
    }
    const { Box, Text } = $.ui.resolve(e)
    const kinds = [
      ...view.artifacts,
      ...view.branches.flatMap(branch => [...branch.rows, ...branch.artifacts]),
    ].map(item => item.kind.length)
    const labelColumns = Math.max(...kinds) + LABEL_GAP
    const heading = headingOf(view)

    // A target that does not fit beside its label goes under it, so that it wraps less.
    const line = (key: string, bullet: JSX.Element, kind: string, body: JSX.Element, isBeside = true) => (
      <Box key={key} flexDirection={isBeside ? 'row' : 'column'}>
        <Text>
          {bullet} <Text dimColor>{kind.padEnd(labelColumns)}</Text>
        </Text>
        <Box flexShrink={1}>{body}</Box>
      </Box>
    )
    const artifactLine = (key: string, artifact: Artifact) => {
      const target = shown(artifact.target)
      const isBeside = BULLET_COLUMNS + labelColumns + target.length <= e.props.bodyColumns - FRAME_COLUMNS
      return line(
        key,
        <Text dimColor>↗</Text>,
        artifact.kind,
        <Text dimColor wrap="wrap">
          {target}
        </Text>,
        isBeside,
      )
    }
    const rowLine = (key: string, row: ViewRow) =>
      line(
        key,
        row.section === 'NeedsYou' ? <Text color="error">●</Text> : <Text color="subtle">·</Text>,
        row.kind,
        <Text wrap="wrap">
          {row.what}
          {row.result === null ? '' : <Text color="warning"> → {row.result}</Text>}
        </Text>,
      )
    const branchBlock = (branch: Branch, index: number) => {
      const meta = [...(branch.iid === null ? [] : [`!${branch.iid}`]), ...branch.status]
      return (
        <Box key={`branch-${index}`} flexDirection="column">
          <Text wrap="wrap">
            <Text bold>{branch.title}</Text>
            <Text dimColor>{meta.map(part => ` · ${part}`).join('')}</Text>
          </Text>
          {branch.rows.map(row => rowLine(`row-${row.id}`, row))}
          {branch.artifacts.map((artifact, at) => artifactLine(`artifact-${index}-${at}`, artifact))}
        </Box>
      )
    }

    return (
      <Box flexDirection="column" borderStyle="round" borderDimColor paddingX={1}>
        {heading === null ? null : <Text bold>{heading}</Text>}
        {view.artifacts.map((artifact, at) => artifactLine(`common-${at}`, artifact))}
        {view.branches.map(branchBlock)}
      </Box>
    )
  })
}
