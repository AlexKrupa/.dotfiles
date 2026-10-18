import { expect, test } from 'claude-code/testing'

const wrap = (text: string) => `\n\n<pasted_content id="c919">\n${text}\n</pasted_content id="c919">\n`

test('removes the tags around a paste', async ($, on) => {
  let seen = ''
  on('prompt.submit', (_, e) => ((seen = e.text), { text: e.text }))
  await $.prompt.submit({ text: wrap('Fix the bug.\nThen run the tests.') })
  expect(seen).toBe('Fix the bug.\nThen run the tests.')
})

test('keeps typed text around a paste', async ($, on) => {
  let seen = ''
  on('prompt.submit', (_, e) => ((seen = e.text), { text: e.text }))
  await $.prompt.submit({ text: `Do this:${wrap('Fix the bug.')}` })
  expect(seen).toBe('Do this:\nFix the bug.')
})

test('leaves a prompt with no paste alone', async ($, on) => {
  let seen = ''
  on('prompt.submit', (_, e) => ((seen = e.text), { text: e.text }))
  await $.prompt.submit({ text: 'plain text' })
  expect(seen).toBe('plain text')
})
