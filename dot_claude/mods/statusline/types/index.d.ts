// Both status lines, ANSI-styled; null before the first refresh.
export type StatusText = string | null

declare module 'claude-code' {
  interface PluginState {
    statusline: { text: StatusText }
  }
}
