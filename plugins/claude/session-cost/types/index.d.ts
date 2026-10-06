export type Usd = number | null
export type HostId = string | null

declare module 'claude-code' {
  interface PluginState {
    'session-cost': { usd: Usd; hostId: HostId }
  }
}
