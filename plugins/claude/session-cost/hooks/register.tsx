import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

const usd = atom({ plugin: 'session-cost', key: 'usd' } as const, null)
const hostId = atom({ plugin: 'session-cost', key: 'hostId' } as const, null)

const formatCost = (value: number) => `≈ $${value < 0.01 ? '<0.01' : value.toFixed(2)}`

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const { cost } = await $.session.usage()
    await update($, usd, () => cost?.usd ?? null)

    // The desktop app's own session id (what its session tools take) is only exposed as an env var of the engine process.
    const { stdout } = await $.process.run(['cmd.exe', '/d', '/c', 'echo %CLAUDE_CODE_HOST_SESSION_ID%'])
    const value = stdout.trim()
    await update($, hostId, () => (value && !value.startsWith('%') ? value : null))

    return result
  })

  on('session.measure', async ($, e, next) => {
    if (e.cost) {
      const total = e.cost.usd
      await update($, usd, () => total)
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e)
    }

    const value = await read($, usd)
    const appId = await read($, hostId)
    const transcriptId = await $.session.id()
    const label = [appId ?? `Session ${transcriptId}`, value === null ? null : formatCost(value)].filter(Boolean).join(' · ')
    const { Box, Button, Text } = $.ui.resolve(e)

    const copy = async (text: string, what: string) => {
      const copied = await $.ui.copy({ text, surface: e.surface })

      // Remote surfaces such as the desktop app may have no clipboard path yet; fall back to Windows clip.exe.
      const isCopied = copied.isCopied || (await $.process.run(['clip.exe'], { stdin: text })).exitCode === 0
      $.ui.toast(isCopied ? `${what} copied` : `Could not copy the ${what.toLowerCase()}`)
    }

    return (
      <Box>
        <Text dimColor>{label} </Text>
        {appId === null ? null : <Button key="copy-app-id" label="Copy app ID" onPress={() => copy(appId, 'App session ID')} />}
        <Button key="copy-id" label="Copy transcript ID" onPress={() => copy(transcriptId, 'Transcript ID')} />
      </Box>
    )
  })
}
