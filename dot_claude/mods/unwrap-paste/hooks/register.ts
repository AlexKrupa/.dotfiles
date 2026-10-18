import type { Register } from 'claude-code'

// Claude Code wraps a paste as `\n\n<pasted_content id="c919">\n...\n</pasted_content id="c919">\n`.
const PASTE = /\n*<pasted_content id="(\w+)">\n([\s\S]*?)\n<\/pasted_content id="\1">\n*/g
const COMMAND = /^\/([\w:-]+)(?:\s+([\s\S]*))?$/

export const register: Register = on => {
  on('prompt.submit', async ($, e, next) => {
    if (e.command) return next(e)
    const text = e.text.replace(PASTE, '\n$2\n').trim()
    if (text === e.text.trim()) return next(e)

    // The engine finds slash commands before this event, so a rewritten `/name args` is plain text.
    const [, name, args = ''] = COMMAND.exec(text) ?? []
    if (name && (await $.command.list()).some(c => c.name === name)) {
      // The host refuses `$.command.run` inside this hook, and a dropped prompt starts no turn.
      $.clock.after(0, async () => {
        await $.prompt.fill({ text: '' })
        await $.command.run({ command: name, args }).catch(err => $.ui.toast(`/${name} failed: ${err}`))
      })
      return { drop: `runs /${name}` }
    }
    return next({ ...e, text })
  })
}
