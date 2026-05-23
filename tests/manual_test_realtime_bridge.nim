## Manual bridge between a Discord voice channel and the OpenAI Realtime API.
##
## Pipes audio from Discord users through gpt-realtime-2 (or the model in
## $OPENAI_REALTIME_MODEL) and pipes the model's spoken response back into the
## voice channel.
##
## Requirements:
##   - TOKEN env var (or .env file) with a Discord bot token
##   - OPENAI_API_KEY env var
##   - Bot present in the Monolab guild with Connect + Speak permissions
##
## Run:
##   nix develop -c nim r tests/manual_test_realtime_bridge.nim
##
## Audio path:
##   Discord (48kHz stereo Opus) -> decode -> 24kHz mono PCM16 -> OpenAI
##   OpenAI (24kHz mono PCM16)   -> resample -> 48kHz stereo Opus -> Discord

import
  std/[asyncdispatch, base64, json, locks, options, os, strutils, times],
  guildy,
  guildy/[voice, voiceio, opus, audio],
  openai_leap

when not defined(guildyVoice):
  static:
    error "this test must be built with -d:guildyVoice"

# -------------------------------------------------------------------------- #
# Config

const
  MonolabGuildId = "1180587895921328158"
  DefaultModel = "gpt-realtime-2"
  FrameSamplesStereo = OpusFrameSize * OpusChannels # 1920 samples per 20ms
  FrameSamplesMono24 = OpusFrameSize div 2          # 480 samples per 20ms @ 24kHz
  FrameMs = 20

# -------------------------------------------------------------------------- #
# Shared state — value-typed globals plus a Lock guarding the refs.

var
  stateLock: Lock
  vcShared {.guard: stateLock.}: VoiceConnection
  vioShared {.guard: stateLock.}: VoiceIo
  running: bool
  gatewayReady: bool

var
  inboundQueue: Channel[seq[int16]]  # 48k stereo PCM in from Discord
  outboundQueue: Channel[seq[int16]] # 48k stereo PCM out to Discord

proc loadDotEnv(path: string) =
  if path == "" or not fileExists(path):
    return
  for rawLine in readFile(path).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let eq = line.find('=')
    if eq <= 0:
      continue
    let key = line[0 ..< eq].strip()
    var value = line[eq + 1 .. ^1].strip()
    if value.len >= 2 and ((value.startsWith('"') and value.endsWith('"')) or
        (value.startsWith('\'') and value.endsWith('\''))):
      value = value[1 .. ^2]
    if getEnv(key, "") == "":
      putEnv(key, value)

proc logPhase(phase, msg: string) =
  let ts = now().format("HH:mm:ss'.'fff")
  echo "[", ts, "] ", phase, ": ", msg

proc setVc(vc: VoiceConnection) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock stateLock:
      vcShared = vc

proc getVc(): VoiceConnection {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock stateLock:
      result = vcShared

proc setVio(vio: VoiceIo) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock stateLock:
      vioShared = vio

proc getVio(): VoiceIo {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock stateLock:
      result = vioShared

# -------------------------------------------------------------------------- #
# Discord gateway thread

var gwThread: Thread[(string, string)]

proc gwProc(args: (string, string)) {.thread, gcsafe.} =
  let (token, guildId) = args
  let lc = newGuildyClient(token)

  lc.onVoiceMilestone = proc(vc: VoiceConnection, milestone: VoiceMilestone)
      {.gcsafe.} =
    logPhase("MILESTONE", $milestone)
    if milestone == vmSessionDescription:
      setVc(vc)

  proc onMsg(c: GuildyClient, msg: DiscordMessage) {.gcsafe.} = discard

  proc onRaw(c: GuildyClient, e: JsonNode) {.gcsafe.} =
    let t = if e.hasKey("t"): e["t"].getStr else: ""
    if t == "READY":
      logPhase("GATEWAY", "READY received, locating voice channel")
      let channels = c.getGuildChannels(guildId)
      var channelId = ""
      for ch in channels:
        if ch.`type` == 2:
          channelId = ch.id
          logPhase("GATEWAY", "joining voice channel " &
              ch.name.get("?") & " (" & ch.id & ")")
          break
      if channelId == "":
        let newCh = c.createVoiceChannel(guildId, "Racha Realtime")
        channelId = newCh.id
        logPhase("GATEWAY", "created voice channel " & newCh.id)
      gatewayReady = true
      waitFor c.joinVoiceChannel(guildId, channelId)
    if not running:
      try:
        waitFor c.leaveVoiceChannel(guildId)
      except CatchableError:
        discard
      c.stop()

  lc.startGateway(onRaw = onRaw, onMessage = onMsg)

# -------------------------------------------------------------------------- #
# UDP recv thread: blocking recvFrom -> decrypt -> opus decode -> queue

var recvThread: Thread[void]

proc recvProc() {.thread, gcsafe.} =
  var authFailures = 0
  var lastAuthLogAt = 0.0
  var framesDecoded = 0
  var lastFrameLogAt = 0.0
  var dumpedFailures = 0
  const MaxDumpedFailures = 5
  while running:
    let vio = getVio()
    if vio == nil:
      sleep(20)
      continue
    let raw = vio.recvRawPacket()
    if raw.len == 0:
      continue
    try:
      let frame = vio.decodePacket(raw)
      if frame != nil and not frame.isSilence and
          frame.pcm.len == FrameSamplesStereo:
        inboundQueue.send(frame.pcm)
        inc framesDecoded
        let nowT = epochTime()
        if nowT - lastFrameLogAt > 2.0:
          logPhase("RECV", "decoded " & $framesDecoded & " frames")
          lastFrameLogAt = nowT
    except CatchableError as e:
      inc authFailures
      if dumpedFailures < MaxDumpedFailures:
        inc dumpedFailures
        logPhase("RECV", "failure #" & $dumpedFailures &
            " (len=" & $raw.len & " b0=0x" &
            (if raw.len > 0: hexDump(raw[0..<min(raw.len, 1)], 1) else: "??") &
            " hdr=" & hexDump(raw, 20) & ") " & e.msg)
      let nowT = epochTime()
      if nowT - lastAuthLogAt > 2.0:
        logPhase("RECV", $authFailures & " decrypt failures so far")
        lastAuthLogAt = nowT
      sleep(2)

# -------------------------------------------------------------------------- #
# Audio send thread: paces outbound queue at 20ms cadence

var sendThread: Thread[void]

proc sendProc() {.thread, gcsafe.} =
  ## Drains outboundQueue at strict 50fps regardless of backlog.
  ## NEVER burst-sends: Discord's listener has a small jitter buffer, and
  ## bursting causes packet drops mid-stream (audio cuts off).
  ## ALWAYS sends a packet every 20ms — silence when the queue is empty —
  ## so the Discord UDP stream and libdave encryptor state stay warm.
  let silentStereoFrame = newSeq[int16](FrameSamplesStereo)
  var
    nextDeadline = epochTime()
    sentReal = 0
    sentSilence = 0
    lastReportAt = epochTime()
    wasSilent = true
  while running:
    let vio = getVio()
    if vio == nil:
      sleep(20)
      nextDeadline = epochTime()
      continue
    let got = outboundQueue.tryRecv()
    let isReal = got.dataAvailable
    let frame = if isReal: got.msg else: silentStereoFrame
    if isReal and wasSilent:
      logPhase("SEND", "transition: silence -> real audio (queue " &
          $outboundQueue.peek() & ")")
      wasSilent = false
    elif not isReal and not wasSilent:
      logPhase("SEND", "transition: real audio -> silence (sentReal=" &
          $sentReal & ")")
      wasSilent = true
    try:
      vio.sendPcm48kStereo(frame)
      if isReal: inc sentReal
      else: inc sentSilence
    except CatchableError as e:
      logPhase("SEND", "error: " & e.msg & " (" & $e.name & ")")
    let nowT = epochTime()
    if nowT - lastReportAt > 2.0:
      logPhase("SEND", "alive: sentReal=" & $sentReal &
          " sentSilence=" & $sentSilence &
          " queue=" & $outboundQueue.peek())
      lastReportAt = nowT
    nextDeadline += FrameMs.float / 1000.0
    let sleepSecs = nextDeadline - epochTime()
    if sleepSecs > 0:
      sleep(int(sleepSecs * 1000.0))

# -------------------------------------------------------------------------- #
# OpenAI Realtime orchestration

proc base64ToPcm16(encoded: string): seq[int16] =
  let raw = base64.decode(encoded)
  if raw.len mod 2 != 0:
    return @[]
  result = newSeq[int16](raw.len div 2)
  for i in 0 ..< result.len:
    let lo = uint16(uint8(raw[i * 2]))
    let hi = uint16(uint8(raw[i * 2 + 1]))
    result[i] = cast[int16]((hi shl 8) or lo)

proc pcm16ToBase64(pcm: openArray[int16]): string =
  var bytes = newString(pcm.len * 2)
  for i in 0 ..< pcm.len:
    let v = cast[uint16](pcm[i])
    bytes[i * 2] = char(uint8(v and 0xFF'u16))
    bytes[i * 2 + 1] = char(uint8((v shr 8) and 0xFF'u16))
  result = base64.encode(bytes)

proc enqueueOutgoing(pcm24kMono: seq[int16]) =
  let pcm48Stereo = openai24kMonoTo48kStereo(pcm24kMono)
  var i = 0
  while i + FrameSamplesStereo <= pcm48Stereo.len:
    outboundQueue.send(pcm48Stereo[i ..< i + FrameSamplesStereo])
    i += FrameSamplesStereo

proc flushOutboundQueue() =
  while true:
    let g = outboundQueue.tryRecv()
    if not g.dataAvailable:
      break

const FrameSecondsMono = 0.020 # 20ms per 24kHz/mono OpenAI frame

var
  lastAppendTime = 0.0
  cachedSilenceB64 = ""

proc silentMonoFrameB64(): string =
  ## Memoized base64 of one 20ms zero-PCM mono24 frame.
  if cachedSilenceB64.len == 0:
    cachedSilenceB64 = pcm16ToBase64(newSeq[int16](FrameSamplesMono24))
  cachedSilenceB64

proc pumpAudioToOpenAi(session: RealtimeSession) =
  ## Keep OpenAI's input buffer in lock-step with wall-clock time.
  ## Pops real audio frames from the queue while available, otherwise sends
  ## true-silence frames. OpenAI's server VAD needs a continuous stream with
  ## real silence between speech bursts to detect speech_stopped.
  let now = epochTime()
  if lastAppendTime == 0.0:
    lastAppendTime = now
    return
  while lastAppendTime + FrameSecondsMono <= now:
    let g = inboundQueue.tryRecv()
    if g.dataAvailable:
      let pcm24 = discord48kStereoTo24kMono(g.msg)
      session.appendAudio(pcm16ToBase64(pcm24))
    else:
      session.appendAudio(silentMonoFrameB64())
    lastAppendTime += FrameSecondsMono

proc waitForVoiceReady(timeoutSec: int = 60): VoiceConnection =
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    let vc = getVc()
    if vc != nil and vc.secretKey.len == 32:
      return vc
    sleep(100)
  raise newException(IOError, "voice connection did not become ready")

proc runBridge(token, model: string) =
  initLock(stateLock)
  running = true
  # Unbounded outbound queue: the assistant response must always play to
  # completion (see [[feedback_llm_voice_cutoff]]). OpenAI ships audio faster
  # than realtime; we buffer the whole thing and drain at strict 50fps so the
  # user hears every word.
  inboundQueue.open(maxItems = 256)
  outboundQueue.open()

  createThread[(string, string)](gwThread, gwProc, (token, MonolabGuildId))
  logPhase("BRIDGE", "waiting for voice handshake")
  let vc = waitForVoiceReady()
  let vio = newVoiceIo(vc)
  setVio(vio)
  logPhase("BRIDGE", "voice ready (mode=" & $vio.mode &
      ", dave_protocol_version=" & $vc.daveProtocolVersion &
      ", encryptor_passthrough=" & $vio.encryptorPassthrough &
      "), spawning audio threads")

  createThread[void](recvThread, recvProc)
  createThread[void](sendThread, sendProc)

  # NB. Discord auto-detects speaking from audio packet flow. We deliberately
  # don't call vc.setSpeaking from this thread: vc.ws is owned by the gateway
  # thread's async dispatcher, and a cross-thread WebSocket send races with
  # the heartbeat loop and drops the voice connection.

  let openai = newOpenAiApi()
  logPhase("OPENAI", "connecting to realtime model " & model)
  let session = openai.connectRealtime(model)
  let created = session.nextEvent()
  if created.isNone or created.get.`type` != "session.created":
    logPhase("OPENAI", "ERROR: no session.created event")
    running = false
    return
  logPhase("OPENAI", "session.created")

  let config = RealtimeSessionConfig()
  config.output_modalities = option(@["audio"])
  config.instructions = option(
      "You are Racha Logomo, a sassy AI assistant in a Discord voice channel. " &
      "Keep responses short. Be witty.")
  config.audio = option(RealtimeAudioConfig(
    input: option(RealtimeAudioInputConfig(
      format: option(%*{"type": "audio/pcm", "rate": 24000}),
      transcription: option(RealtimeTranscriptionConfig(
        model: option("whisper-1"),
      )),
      turn_detection: option(%*{
        "type": "server_vad",
        "threshold": 0.4,
        "silence_duration_ms": 600,
        "prefix_padding_ms": 300,
      }),
    )),
    output: option(RealtimeAudioOutputConfig(
      format: option(%*{"type": "audio/pcm", "rate": 24000}),
      voice: option("alloy"),
    )),
  ))
  session.updateSession(config)
  let updated = session.nextEvent()
  if updated.isSome:
    logPhase("OPENAI", "session.updated")

  logPhase("BRIDGE", "live; press Ctrl+C to stop")
  var
    inAssistantResponse = false
    audioDeltasReceived = 0
    lastAudioDeltaLogAt = 0.0
  while running:
    let evtOpt = session.nextEventWithTimeout(10)
    if evtOpt.isSome:
      let evt = evtOpt.get
      case evt.`type`
      of "input_audio_buffer.speech_started":
        # User interrupted. Stop the in-flight model response, drop anything
        # still queued for Discord, so the bot actually shuts up immediately.
        session.cancelResponse()
        flushOutboundQueue()
        if inAssistantResponse:
          stdout.write "\n"
          inAssistantResponse = false
        logPhase("VAD", "user started speaking")
      of "input_audio_buffer.speech_stopped":
        logPhase("VAD", "user stopped speaking")
      of "response.output_audio.delta":
        if evt.delta.isSome:
          let pcm24 = base64ToPcm16(evt.delta.get)
          if pcm24.len > 0:
            enqueueOutgoing(pcm24)
            inc audioDeltasReceived
            let nowT = epochTime()
            if nowT - lastAudioDeltaLogAt > 1.0:
              logPhase("AUDIO", "received " & $audioDeltasReceived &
                  " audio chunks from OpenAI; outbound queue len ~" &
                  $outboundQueue.peek())
              lastAudioDeltaLogAt = nowT
      of "response.output_audio_transcript.delta":
        if evt.delta.isSome:
          if not inAssistantResponse:
            stdout.write "Racha: "
            inAssistantResponse = true
          stdout.write evt.delta.get
          stdout.flushFile()
      of "response.output_audio_transcript.done":
        if inAssistantResponse:
          stdout.write "\n"
          inAssistantResponse = false
      of "conversation.item.input_audio_transcription.completed":
        if evt.transcript.isSome:
          echo "You: ", evt.transcript.get
      of "error":
        if evt.error.isSome:
          logPhase("OPENAI", "ERROR " & evt.error.get.message)
      of "response.created":
        logPhase("OPENAI", "response.created")
      of "response.done":
        if audioDeltasReceived == 0:
          logPhase("OPENAI",
              "response.done but no audio.delta arrived this turn")
        audioDeltasReceived = 0
      of "response.output_item.added", "response.output_item.done",
         "response.content_part.added", "response.content_part.done",
         "rate_limits.updated", "input_audio_buffer.committed",
         "conversation.item.created", "response.output_audio.done":
        discard
      else:
        logPhase("OPENAI", "evt " & evt.`type`)
    else:
      if not session.connected:
        logPhase("OPENAI", "connection closed")
        break
    pumpAudioToOpenAi(session)

  running = false
  logPhase("BRIDGE", "shutting down")
  joinThread(recvThread)
  joinThread(sendThread)
  joinThread(gwThread)
  vio.destroy()
  session.close()
  openai.close()
  inboundQueue.close()
  outboundQueue.close()
  logPhase("BRIDGE", "done")

proc main() =
  loadDotEnv(".env")
  let token = getEnv("TOKEN", "")
  if token == "":
    quit "TOKEN env var (or .env) is required"
  if getEnv("OPENAI_API_KEY", "") == "":
    quit "OPENAI_API_KEY env var is required"
  let model = getEnv("OPENAI_REALTIME_MODEL", DefaultModel)
  runBridge(token, model)

main()
