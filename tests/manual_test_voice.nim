import
  std/[unittest, os, strutils, tables, locks, json, asyncdispatch],
  guildy,
  guildy/voice

proc loadDotEnv(path: string): Table[string, string] =
  result = initTable[string, string]()
  if path == "" or not fileExists(path): return
  for rawLine in readFile(path).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0..<eq].strip()
    var value = line[eq+1..^1].strip()
    if value.len >= 2 and ((value.startsWith('"') and value.endsWith('"')) or (value.startsWith('\'') and value.endsWith('\''))):
      value = value[1..^2]
    result[key] = value

const
  MonolabGuildId = "1180587895921328158"

var token: string
var stateLock: Lock
var voiceReady: bool

proc ensureEnv() =
  if getEnv("TOKEN", "") != "": return
  let kv = loadDotEnv(".env")
  for k, v in kv.pairs:
    if getEnv(k, "") == "":
      putEnv(k, v)
  token = getEnv("TOKEN", "")

suite "guildy voice":
  ensureEnv()

  test "list voice channels":
    let client = newGuildyClient(token)
    let channels = client.getGuildChannels(MonolabGuildId)
    echo "Channels in Monolab:"
    for ch in channels:
      # Channel type 2 = voice, 13 = stage.
      let kind = case ch.channel_type
        of 0: "text"
        of 2: "voice"
        of 4: "category"
        of 13: "stage"
        else: "type=" & $ch.channel_type
      echo "  ", kind, " | ", ch.id, " | ", ch.name

  test "manual voice join":
    if token == "":
      echo "No token, skipping."
      skip()

    initLock(stateLock)
    voiceReady = false

    let restClient = newGuildyClient(token)

    # Find the first voice channel in Monolab.
    let channels = restClient.getGuildChannels(MonolabGuildId)
    var voiceChannelId = ""
    for ch in channels:
      if ch.channel_type == 2:
        voiceChannelId = ch.id
        echo "Found voice channel: ", ch.name, " (", ch.id, ")"
        break

    if voiceChannelId == "":
      echo "No voice channel found in Monolab. Creating one."
      let newCh = restClient.createVoiceChannel(MonolabGuildId, "Racha Voice Test")
      voiceChannelId = newCh.id
      echo "Created voice channel: ", newCh.name, " (", newCh.id, ")"

    # Gateway thread joins voice and waits for voice ready callback.
    var gwThread: Thread[(string, string, string)]
    proc gwProc(args: (string, string, string)) {.thread, gcsafe.} =
      let (tok, guildId, channelId) = args
      var lc = newGuildyClient(tok)

      lc.onVoiceReady = proc(state: VoiceState) {.gcsafe.} =
        echo "Voice ready!"
        echo "  sessionId: ", state.sessionId
        echo "  token: ", state.token
        echo "  endpoint: ", state.endpoint
        acquire(stateLock)
        voiceReady = true
        release(stateLock)

      proc onMsg(c: GuildyClient, msg: DiscordMessage) {.gcsafe.} = discard

      # Join voice once READY event fires.
      proc onRawWithJoin(c: GuildyClient, e: JsonNode) {.gcsafe.} =
        let t = if e.hasKey("t"): e["t"].getStr else: ""
        if t == "READY":
          echo "Gateway ready, joining voice channel..."
          waitFor c.joinVoiceChannel(guildId, channelId)

      lc.startGateway(onRaw = onRawWithJoin, onMessage = onMsg)

    createThread[(string, string, string)](gwThread, gwProc, (token, MonolabGuildId, voiceChannelId))

    echo "Waiting up to 30 seconds for voice ready..."
    var waitedMs = 0
    let timeoutMs = 30 * 1000
    while true:
      acquire(stateLock)
      let got = voiceReady
      release(stateLock)
      if got: break
      if waitedMs >= timeoutMs: break
      sleep(200)
      waitedMs += 200

    acquire(stateLock)
    let gotVoice = voiceReady
    release(stateLock)

    if gotVoice:
      echo "Voice state received! Bot is in the voice channel."
      echo "Check Discord to confirm the bot appears in the voice channel."
      echo "Waiting 60 seconds so you can see it..."
      sleep(60000)
    else:
      echo "Did not receive voice ready callback in time."

    check gotVoice
