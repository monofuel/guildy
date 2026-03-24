import
  std/[unittest, os, strutils, tables, locks, json, asyncdispatch, times, options],
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
    if value.len >= 2 and ((value.startsWith('"') and value.endsWith('"')) or
        (value.startsWith('\'') and value.endsWith('\''))):
      value = value[1..^2]
    result[key] = value

const
  MonolabGuildId = "1180587895921328158"

var token: string
var stateLock: Lock
var reachedMilestones: set[VoiceMilestone]
var gatewayReady: bool
var shouldStop: bool

proc logPhase(phase, msg: string) =
  let ts = now().format("HH:mm:ss'.'fff")
  echo "[", ts, "] ", phase, ": ", msg

proc ensureEnv() =
  if getEnv("TOKEN", "") != "": return
  let kv = loadDotEnv(".env")
  for k, v in kv.pairs:
    if getEnv(k, "") == "":
      putEnv(k, v)
  token = getEnv("TOKEN", "")

proc hasMilestone(m: VoiceMilestone): bool =
  acquire(stateLock)
  result = m in reachedMilestones
  release(stateLock)

proc waitForMilestone(m: VoiceMilestone, timeoutMs: int): bool =
  var waitedMs = 0
  while waitedMs < timeoutMs:
    if hasMilestone(m): return true
    sleep(200)
    waitedMs += 200
  return false

proc logMilestoneSummary() =
  logPhase("SUMMARY", "Milestone report:")
  for m in VoiceMilestone:
    let status = if hasMilestone(m): "+" else: "-"
    echo "  ", status, " ", $m

suite "guildy voice":
  ensureEnv()

  test "list voice channels":
    if token == "":
      echo "No token, skipping."
      skip()
    let client = newGuildyClient(token)
    let channels = client.getGuildChannels(MonolabGuildId)
    echo "Channels in Monolab:"
    for ch in channels:
      let kind = case ch.channel_type
        of 0: "text"
        of 2: "voice"
        of 4: "category"
        of 13: "stage"
        else: "type=" & $ch.channel_type
      echo "  ", kind, " | ", ch.id, " | ", ch.name

  test "voice DAVE handshake":
    if token == "":
      echo "No token, skipping."
      skip()

    initLock(stateLock)
    reachedMilestones = {}
    gatewayReady = false
    shouldStop = false

    let restClient = newGuildyClient(token)

    # Find the first voice channel in Monolab.
    let channels = restClient.getGuildChannels(MonolabGuildId)
    var voiceChannelId = ""
    for ch in channels:
      if ch.channel_type == 2:
        voiceChannelId = ch.id
        logPhase("SETUP", "Found voice channel: " & ch.name.get("?") & " (" & ch.id & ")")
        break

    if voiceChannelId == "":
      logPhase("SETUP", "No voice channel found, creating one")
      let newCh = restClient.createVoiceChannel(MonolabGuildId, "Racha Voice Test")
      voiceChannelId = newCh.id
      logPhase("SETUP", "Created: " & newCh.name.get("?") & " (" & newCh.id & ")")

    # Gateway thread
    var gwThread: Thread[(string, string, string)]
    proc gwProc(args: (string, string, string)) {.thread, gcsafe.} =
      let (tok, guildId, channelId) = args
      var lc = newGuildyClient(tok)

      lc.onVoiceMilestone = proc(vc: VoiceConnection,
          milestone: VoiceMilestone) {.gcsafe.} =
        logPhase("MILESTONE", $milestone)
        acquire(stateLock)
        reachedMilestones.incl(milestone)
        release(stateLock)

      lc.onVoiceReady = proc(state: VoiceState) {.gcsafe.} =
        logPhase("VOICE", "Voice state ready: endpoint=" & state.endpoint)

      proc onMsg(c: GuildyClient, msg: DiscordMessage) {.gcsafe.} = discard

      proc onRaw(c: GuildyClient, e: JsonNode) {.gcsafe.} =
        let t = if e.hasKey("t"): e["t"].getStr else: ""
        if t == "READY":
          logPhase("GATEWAY", "READY received, joining voice channel...")
          acquire(stateLock)
          gatewayReady = true
          release(stateLock)
          waitFor c.joinVoiceChannel(guildId, channelId)
        # Check if main thread wants us to stop
        acquire(stateLock)
        let stop = shouldStop
        release(stateLock)
        if stop:
          waitFor c.leaveVoiceChannel(guildId)
          c.stop()

      lc.startGateway(onRaw = onRaw, onMessage = onMsg)

    logPhase("GATEWAY", "Starting gateway thread...")
    createThread[(string, string, string)](gwThread, gwProc,
        (token, MonolabGuildId, voiceChannelId))

    # Wait for gateway ready
    logPhase("WAIT", "Waiting for gateway READY (up to 30s)...")
    var waitedMs = 0
    while waitedMs < 30000:
      acquire(stateLock)
      let ready = gatewayReady
      release(stateLock)
      if ready: break
      sleep(200)
      waitedMs += 200

    check gatewayReady or waitedMs < 30000
    if gatewayReady:
      logPhase("GATEWAY", "Gateway ready")

      # Wait for voice ready (means we got past 4017)
      logPhase("WAIT", "Waiting for vmReady (up to 60s)...")
      let gotReady = waitForMilestone(vmReady, 60000)

      if gotReady:
        logPhase("VOICE", "Voice Ready received - no 4017 close!")

        # Wait for DAVE handshake completion
        when defined(guildyVoice):
          logPhase("WAIT", "Waiting for vmDaveComplete (up to 60s)...")
          let gotDave = waitForMilestone(vmDaveComplete, 60000)
          if gotDave:
            logPhase("DAVE", "DAVE handshake complete!")
          else:
            logPhase("DAVE", "DAVE handshake did not complete in time")

        logPhase("VOICE", "Staying connected for 30s (check Discord)...")
        sleep(30000)
      else:
        logPhase("FAIL", "vmReady not reached - likely 4017 close or connection failure")

    logMilestoneSummary()

    # Signal thread to stop, then wait for it
    logPhase("CLEANUP", "Signaling gateway thread to stop...")
    acquire(stateLock)
    shouldStop = true
    release(stateLock)

    # Give the thread time to process the stop signal via onRaw
    sleep(5000)

    joinThread(gwThread)
    logPhase("CLEANUP", "Done")

    check hasMilestone(vmHelloReceived)
    check hasMilestone(vmIdentifySent)
    check hasMilestone(vmReady)
    when defined(guildyVoice):
      check hasMilestone(vmDaveComplete)
