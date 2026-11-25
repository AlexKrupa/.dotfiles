/** A view line of `watchd follow`, as `daemon/src/view.rs` writes it. */
export type View = {
  key: string
  path: string
  hub: boolean
  heading: string | null
  branch_count: number
  artifacts: Artifact[]
  branches: Branch[]
}

export type Branch = {
  name: string | null
  title: string
  iid: number | null
  status: string[]
  rows: ViewRow[]
  artifacts: Artifact[]
}

export type ViewRow = {
  id: number
  section: 'NeedsYou' | 'Agent' | 'Info'
  kind: string
  what: string
  result: string | null
  url: string | null
}

export type Artifact = { kind: string; target: string }

declare module 'claude-code' {
  interface PluginState {
    watchd: { view: Shaped<View | null> }
  }
}
