// Paints Markdown style runs (`decorations`) over the prompt box draft. The text and the cursor
// pass through unchanged. prompt.fill is the whole draft only in `replace` mode, so only then are
// offsets into `e.text` offsets into the box.

import type { Register } from "claude-code"
import { decorateMarkdown } from "./lib/mdprompt"

// A hook that throws is skipped with a notice on every keystroke, so a painting bug costs only the colours.
function paint(text: string) {
  try {
    return decorateMarkdown(text)
  } catch {
    return []
  }
}

export const register: Register = (on) => {
  on("prompt.edit", async ($, e, next) => {
    const box = await next(e)
    return { ...box, decorations: [...(box.decorations ?? []), ...paint(box.text)] }
  })

  on("prompt.fill", ($, e, next) => {
    if (e.mode !== "replace") return next(e)
    return next({ ...e, decorations: [...(e.decorations ?? []), ...paint(e.text)] })
  })
}
