// Shared vocabulary of the painter: the `Decoration` shape the engine takes and the colours we use.
// Pure data, no logic. `mdprompt.ts` re-exports everything here, so callers keep importing from there.

import type { TokenKind } from "./highlight"

export type Decoration = {
  start: number
  end: number
  color?: string
  backgroundColor?: string
  dimColor?: boolean
  bold?: boolean
  italic?: boolean
  underline?: boolean
  strikethrough?: boolean
}

/** What a run says about its characters; `start`/`end` are added when it is emitted. */
export type Style = Omit<Decoration, "start" | "end">

// Dracula colours as Neovim paints Markdown with `Mofiqul/dracula.nvim` and `render-markdown.nvim`.
// Everything that is only a marker (`#`, `|`, `**`, `---`) is `dimColor` instead.
export const PALETTE = {
  codeBg: "#44475a",
  codeFg: "#f8f8f2",
  fence: "#6272a4",
  lang: "#8be9fd",
  inlineBg: "#44475a",
  inlineFg: "#f1fa8c",
  /** h1 to h6 */
  heading: ["#f8f8f2", "#ff79c6", "#8be9fd", "#50fa7b", "#bd93f9", "#ffb86c"],
  link: "#ffb86c",
  /** list bullets and ordered-list numbers */
  bullet: "#8be9fd",
  /** `[ ]`: still to do */
  taskTodo: "#8be9fd",
  /** `[x]`: done */
  taskDone: "#8be9fd",
  /** inline HTML / XML tags, `<thinking>` and friends */
  tag: "#8be9fd",
  /** `&amp;` `&#39;` */
  entity: "#ffb86c",
  token: {
    keyword: "#ff79c6",
    string: "#f1fa8c",
    comment: "#6272a4",
    number: "#bd93f9",
    type: "#a4ffff",
    literal: "#bd93f9",
    add: "#b3f6c0",
    del: "#ffc0b9",
    meta: "#8be9fd",
  } satisfies Record<TokenKind, string>,
} as const

/** A draft this long is left unpainted: the box stays responsive and nobody writes this in a prompt box. */
export const MAX_CHARS = 60_000
