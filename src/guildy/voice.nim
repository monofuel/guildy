## Voice types and state for Discord voice connections.

type
  VoiceState* = ref object
    ## Tracks voice connection state for a single guild.
    guildId*: string
    channelId*: string
    sessionId*: string
    token*: string
    endpoint*: string
    userId*: string

  OnVoiceStateEvent* = proc(state: VoiceState) {.gcsafe.}
