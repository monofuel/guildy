## Voice types, opcodes, and WebSocket connection for Discord voice.

import
  std/[json, asyncdispatch, times, random, strutils, net, nativesockets],
  ws

from std/posix import Timeval, Time, Suseconds, setsockopt, SOL_SOCKET, SO_RCVTIMEO

template voiceLog(args: varargs[untyped]) =
  when defined(guildyVoiceDebug):
    echo args

when defined(guildyVoice):
  import std/tables
  import guildy/dave

# -------------------------------
# Voice Gateway Opcodes

const
  VoiceIdentifyOp* = 0
  VoiceSelectProtocolOp* = 1
  VoiceReadyOp* = 2
  VoiceHeartbeatOp* = 3
  VoiceSessionDescriptionOp* = 4
  VoiceSpeakingOp* = 5
  VoiceHeartbeatAckOp* = 6
  VoiceResumeOp* = 7
  VoiceHelloOp* = 8
  VoiceResumedOp* = 9
  VoiceClientDisconnectOp* = 13

  # DAVE (E2EE) opcodes
  DavePrepareTransitionOp* = 21
  DaveExecuteTransitionOp* = 22
  DaveReadyForTransitionOp* = 23
  DavePrepareEpochOp* = 24
  # Binary opcodes (sent/received as binary WS frames)
  DaveMlsExternalSenderOp* = 25
  DaveMlsKeyPackageOp* = 26
  DaveMlsProposalsOp* = 27
  DaveMlsCommitWelcomeOp* = 28
  DaveMlsPrepareCommitTransitionOp* = 29
  DaveMlsWelcomeOp* = 30
  DaveMlsInvalidCommitWelcomeOp* = 31

# -------------------------------
# Types

type
  VoiceMilestone* = enum
    vmHelloReceived
    vmIdentifySent
    vmReady
    vmUdpDiscovered
    vmSelectProtocolSent
    vmDaveSessionCreated
    vmDaveKeyPackageSent
    vmDaveTransitionReady
    vmDaveComplete
    vmSessionDescription
    vmDisconnected

  OnVoiceMilestoneEvent* = proc(vc: VoiceConnection, milestone: VoiceMilestone) {.gcsafe.}

  VoiceState* = ref object
    ## Tracks voice connection state for a single guild.
    guildId*: string
    channelId*: string
    sessionId*: string
    token*: string
    endpoint*: string
    userId*: string

  VoiceConnection* = ref object
    ## An active voice WebSocket connection for a single guild.
    state*: VoiceState
    ws*: WebSocket
    ssrc*: uint32
    ip*: string
    port*: uint16
    modes*: seq[string]
    secretKey*: seq[uint8]
    running*: bool
    lastHeartbeat*: float
    lastSeqAck*: int  # last sequence number received from server (for v8 heartbeat)
    ready*: bool
    onMilestone*: OnVoiceMilestoneEvent
    udpSocket*: Socket
    externalIp*: string
    externalPort*: uint16
    when defined(guildyVoice):
      daveSession*: DAVESessionHandle
      daveTransitions*: Table[int, uint16]
      recognizedUserIds*: seq[string]
      latestPreparedTransitionVersion*: uint16
      daveProtocolVersion*: uint16
      daveHasExternalSender*: bool
      daveKeyPackageSent*: bool

  OnVoiceStateEvent* = proc(state: VoiceState) {.gcsafe.}
  OnVoiceConnectedEvent* = proc(vc: VoiceConnection) {.gcsafe.}

proc fireMilestone*(vc: VoiceConnection, milestone: VoiceMilestone) =
  if vc.onMilestone != nil:
    vc.onMilestone(vc, milestone)

# -------------------------------
# DAVE helpers (gated behind guildyVoice)

when defined(guildyVoice):
  const
    MlsNewGroupExpectedEpoch = "1"
    DaveProtocolInitTransitionId = 0

  proc sendDaveTextOp(vc: VoiceConnection, op: int, d: JsonNode) {.async.} =
    ## Send a DAVE opcode as a JSON text frame.
    let payload = %*{"op": op, "d": d}
    voiceLog "DAVE send text op=", op, " payload=", $payload
    await vc.ws.send($payload)

  proc sendDaveBinaryOp(vc: VoiceConnection, op: int,
      payload: seq[uint8]) {.async.} =
    ## Send a DAVE opcode as a binary WS frame: [1-byte opcode][payload].
    ## Client→server binary frames have no sequence number prefix.
    var frame = newString(1 + payload.len)
    frame[0] = char(op)
    if payload.len > 0:
      copyMem(addr frame[1], unsafeAddr payload[0], payload.len)
    voiceLog "DAVE send binary op=", op, " payload_len=", payload.len
    await vc.ws.send(frame, Binary)

  proc sendMlsKeyPackage(vc: VoiceConnection) {.async.} =
    let keyPkg = getKeyPackage(vc.daveSession)
    if keyPkg.len > 0:
      await vc.sendDaveBinaryOp(DaveMlsKeyPackageOp, keyPkg)
      vc.fireMilestone(vmDaveKeyPackageSent)
    else:
      voiceLog "DAVE: empty key package, cannot send"

  proc sendReadyForTransition(vc: VoiceConnection, transitionId: int) {.async.} =
    if transitionId != DaveProtocolInitTransitionId:
      await vc.sendDaveTextOp(DaveReadyForTransitionOp,
          %*{"transition_id": transitionId})
      vc.fireMilestone(vmDaveTransitionReady)

  proc sendMlsCommitWelcome(vc: VoiceConnection,
      commitWelcome: seq[uint8]) {.async.} =
    await vc.sendDaveBinaryOp(DaveMlsCommitWelcomeOp, commitWelcome)

  proc sendMlsInvalidCommitWelcome(vc: VoiceConnection,
      transitionId: int) {.async.} =
    await vc.sendDaveTextOp(DaveMlsInvalidCommitWelcomeOp,
        %*{"transition_id": transitionId})

  proc getRecognizedUserIdsWithSelf(vc: VoiceConnection): seq[string] =
    result = vc.recognizedUserIds
    if vc.state.userId notin result:
      result.add(vc.state.userId)

  proc prepareDaveProtocolRatchets(vc: VoiceConnection, transitionId: int,
      protocolVersion: uint16) =
    if transitionId == DaveProtocolInitTransitionId:
      discard
    else:
      vc.daveTransitions[transitionId] = protocolVersion
    vc.latestPreparedTransitionVersion = protocolVersion

  proc handleDaveProtocolPrepareEpoch(vc: VoiceConnection, epoch: string,
      protocolVersion: uint16) =
    if epoch == MlsNewGroupExpectedEpoch:
      daveSessionInit(vc.daveSession, protocolVersion,
          parseBiggestUInt(vc.state.guildId), cstring(vc.state.userId))
      voiceLog "DAVE: session init version=", protocolVersion, " groupId=",
          vc.state.guildId

  proc handleDaveProtocolInit(vc: VoiceConnection,
      protocolVersion: uint16) {.async.} =
    if protocolVersion > 0:
      vc.handleDaveProtocolPrepareEpoch(MlsNewGroupExpectedEpoch,
          protocolVersion)
      await vc.sendMlsKeyPackage()
    else:
      vc.prepareDaveProtocolRatchets(DaveProtocolInitTransitionId,
          protocolVersion)
      # Execute immediately for init transition
      vc.daveTransitions.del(DaveProtocolInitTransitionId)

  proc handleDaveProtocolExecuteTransition(vc: VoiceConnection,
      transitionId: int) =
    if transitionId notin vc.daveTransitions:
      voiceLog "DAVE: unknown transition ", transitionId
      return
    let protocolVersion = vc.daveTransitions[transitionId]
    vc.daveTransitions.del(transitionId)
    if protocolVersion == 0:
      daveSessionReset(vc.daveSession)
    voiceLog "DAVE: executed transition ", transitionId, " version=",
        protocolVersion
    vc.fireMilestone(vmDaveComplete)

# -------------------------------
# UDP IP Discovery

proc discoverExternalIp*(serverIp: string, serverPort: uint16,
    ssrc: uint32): (Socket, string, uint16) =
  ## Send UDP IP discovery packet and return (socket, externalIp, externalPort).
  ## The socket is kept open for later use.
  var sock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  # Set 5 second receive timeout
  var tv: Timeval
  tv.tv_sec = posix.Time(5)
  tv.tv_usec = Suseconds(0)
  discard setsockopt(sock.getFd(), SOL_SOCKET, SO_RCVTIMEO,
      addr tv, SockLen(sizeof(tv)))

  # Build 74-byte discovery request
  var packet: array[74, uint8]
  packet[0] = 0x00; packet[1] = 0x01 # type: request
  packet[2] = 0x00; packet[3] = 0x46 # length: 70
  packet[4] = uint8((ssrc shr 24) and 0xFF)
  packet[5] = uint8((ssrc shr 16) and 0xFF)
  packet[6] = uint8((ssrc shr 8) and 0xFF)
  packet[7] = uint8(ssrc and 0xFF)

  sock.sendTo(serverIp, Port(serverPort),
      cast[string](packet[0..73]))

  # Receive response
  var resp = newString(74)
  var recvIp: string
  var recvPort: Port
  discard sock.recvFrom(resp, 74, recvIp, recvPort)

  # Parse: IP is null-terminated string at bytes 8-71
  var ip = ""
  for i in 8..71:
    if resp[i] == '\0': break
    ip.add(resp[i])

  # Port is big-endian uint16 at bytes 72-73
  let port = (uint16(resp[72].ord) shl 8) or uint16(resp[73].ord)
  result = (sock, ip, port)

# -------------------------------
# Voice WebSocket

proc sendVoiceHeartbeat(vc: VoiceConnection) {.async.} =
  ## Send a voice heartbeat (opcode 3) with v8 format including seq_ack.
  let nonce = int64(epochTime() * 1000)
  let payload = %*{
    "op": VoiceHeartbeatOp,
    "d": {
      "t": nonce,
      "seq_ack": vc.lastSeqAck
    }
  }
  await vc.ws.send($payload)

proc voiceHeartbeat(vc: VoiceConnection, intervalMs: float) {.async.} =
  ## Periodic voice heartbeat loop.
  let jitter = 0.1
  while vc.ws.readyState == ReadyState.Open and vc.running:
    let actualInterval = (intervalMs + rand(intervalMs * jitter)).int
    await sleepAsync(actualInterval)
    await vc.sendVoiceHeartbeat()

proc handleVoiceTextEvent(vc: VoiceConnection, event: JsonNode) {.async.} =
  ## Dispatch a voice gateway TEXT event by opcode.
  if not event.hasKey("op"):
    return

  # Track sequence numbers for v8 heartbeat seq_ack
  if event.hasKey("seq"):
    vc.lastSeqAck = event["seq"].getInt

  let op = event["op"].getInt
  case op
  of VoiceReadyOp:
    let d = event["d"]
    vc.ssrc = d["ssrc"].getInt.uint32
    vc.ip = d["ip"].getStr
    vc.port = d["port"].getInt.uint16
    var modes: seq[string]
    for m in d["modes"]:
      modes.add(m.getStr)
    vc.modes = modes
    vc.ready = true
    voiceLog "Voice Ready: ssrc=", vc.ssrc, " ip=", vc.ip, " port=", vc.port,
        " modes=", vc.modes
    vc.fireMilestone(vmReady)

    # UDP IP discovery
    let (sock, extIp, extPort) = discoverExternalIp(vc.ip, vc.port, vc.ssrc)
    vc.udpSocket = sock
    vc.externalIp = extIp
    vc.externalPort = extPort
    voiceLog "UDP IP discovered: ", extIp, ":", extPort
    vc.fireMilestone(vmUdpDiscovered)

    # Send Select Protocol (op 1)
    let mode = if vc.modes.len > 0: vc.modes[0] else: "aead_aes256_gcm_rtpsize"
    let selectPayload = %*{
      "op": VoiceSelectProtocolOp,
      "d": {
        "protocol": "udp",
        "data": {
          "address": extIp,
          "port": extPort,
          "mode": mode
        }
      }
    }
    voiceLog "Voice Select Protocol: ", $selectPayload
    await vc.ws.send($selectPayload)
    vc.fireMilestone(vmSelectProtocolSent)
  of VoiceSessionDescriptionOp:
    let d = event["d"]
    var key: seq[uint8]
    for b in d["secret_key"]:
      key.add(b.getInt.uint8)
    vc.secretKey = key
    voiceLog "Voice Session Description received (secret_key length=",
        vc.secretKey.len, ")"
    vc.fireMilestone(vmSessionDescription)
    when defined(guildyVoice):
      if d.hasKey("dave_protocol_version"):
        vc.daveProtocolVersion = d["dave_protocol_version"].getInt.uint16
        voiceLog "DAVE: SessionDescription dave_protocol_version=",
            vc.daveProtocolVersion
  of VoiceHeartbeatAckOp:
    vc.lastHeartbeat = epochTime()
  of VoiceHelloOp:
    discard
  of VoiceResumedOp:
    discard
  of VoiceClientDisconnectOp:
    when defined(guildyVoice):
      let d = event["d"]
      if d.hasKey("user_id"):
        let userId = d["user_id"].getStr
        let idx = vc.recognizedUserIds.find(userId)
        if idx >= 0:
          vc.recognizedUserIds.delete(idx)
          voiceLog "DAVE: recognized user removed: ", userId
  of 11:
    # clients_connect: user IDs of users connected to the media session
    when defined(guildyVoice):
      let d = event["d"]
      if d.hasKey("user_ids"):
        for uid in d["user_ids"]:
          let userId = uid.getStr
          if userId notin vc.recognizedUserIds:
            vc.recognizedUserIds.add(userId)
            voiceLog "DAVE: recognized user added: ", userId
  of 12, 14, 15, 18, 20:
    # Known but unhandled opcodes (flags, etc.)
    discard
  else:
    when defined(guildyVoice):
      case op
      of DavePrepareTransitionOp:
        let d = event["d"]
        let transitionId = d["transition_id"].getInt
        let protoVer = d["protocol_version"].getInt.uint16
        voiceLog "DAVE: PrepareTransition id=", transitionId, " version=", protoVer
        vc.prepareDaveProtocolRatchets(transitionId, protoVer)
        await vc.sendReadyForTransition(transitionId)
      of DaveExecuteTransitionOp:
        let d = event["d"]
        let transitionId = d["transition_id"].getInt
        voiceLog "DAVE: ExecuteTransition id=", transitionId
        vc.handleDaveProtocolExecuteTransition(transitionId)
      of DavePrepareEpochOp:
        let d = event["d"]
        let epoch = d["epoch"].getStr
        let protoVer = d["protocol_version"].getInt.uint16
        voiceLog "DAVE: PrepareEpoch epoch=", epoch, " version=", protoVer
        vc.handleDaveProtocolPrepareEpoch(epoch, protoVer)
        if epoch == MlsNewGroupExpectedEpoch:
          await vc.sendMlsKeyPackage()
      else:
        voiceLog "Voice: unhandled text opcode ", op
    else:
      voiceLog "Voice: unhandled text opcode ", op

when defined(guildyVoice):
  proc handleDaveBinaryEvent(vc: VoiceConnection, op: int,
      payload: seq[uint8]) {.async.} =
    ## Dispatch a DAVE binary opcode.
    case op
    of DaveMlsExternalSenderOp:
      voiceLog "DAVE: ExternalSender binary len=", payload.len
      setExternalSender(vc.daveSession, payload)
      vc.daveHasExternalSender = true
      # If we have the protocol version and haven't sent key package yet,
      # init the session and send key package now.
      if vc.daveProtocolVersion > 0 and not vc.daveKeyPackageSent:
        daveSessionInit(vc.daveSession, vc.daveProtocolVersion,
            parseBiggestUInt(vc.state.guildId), cstring(vc.state.userId))
        voiceLog "DAVE: session init version=", vc.daveProtocolVersion,
            " groupId=", vc.state.guildId
        await vc.sendMlsKeyPackage()
        vc.daveKeyPackageSent = true
    of DaveMlsProposalsOp:
      # Binary format: [1-byte operation_type][proposals data]
      # operation_type: 0=append, 1=revoke
      if payload.len < 1:
        voiceLog "DAVE: Proposals too short: ", payload.len
        return
      let opType = payload[0]
      let proposalData = payload[1..^1]
      voiceLog "DAVE: Proposals binary op_type=", opType, " data_len=", proposalData.len
      if opType == 0: # append
        let commitWelcome = processProposals(vc.daveSession, proposalData,
            vc.getRecognizedUserIdsWithSelf())
        if commitWelcome.len > 0:
          await vc.sendMlsCommitWelcome(commitWelcome)
      else:
        voiceLog "DAVE: Proposals revoke not yet implemented"
    of DaveMlsPrepareCommitTransitionOp:
      # Binary format: [2-byte big-endian transition_id][MLS commit data]
      if payload.len < 2:
        voiceLog "DAVE: PrepareCommitTransition too short: ", payload.len
        return
      let transitionId = (int(payload[0]) shl 8) or int(payload[1])
      let commit = payload[2..^1]
      voiceLog "DAVE: PrepareCommitTransition id=", transitionId, " commit_len=",
          commit.len
      let commitResult = processCommit(vc.daveSession, commit)
      if commitResult == nil or daveCommitResultIsFailed(commitResult):
        voiceLog "DAVE: commit failed, flagging invalid and reinitializing"
        if commitResult != nil:
          daveCommitResultDestroy(commitResult)
        await vc.sendMlsInvalidCommitWelcome(transitionId)
        let protoVer = daveSessionGetProtocolVersion(vc.daveSession)
        await vc.handleDaveProtocolInit(protoVer)
      elif daveCommitResultIsIgnored(commitResult):
        voiceLog "DAVE: commit ignored"
        daveCommitResultDestroy(commitResult)
      else:
        voiceLog "DAVE: commit success, preparing ratchets"
        daveCommitResultDestroy(commitResult)
        let protoVer = daveSessionGetProtocolVersion(vc.daveSession)
        vc.prepareDaveProtocolRatchets(transitionId, protoVer)
        await vc.sendReadyForTransition(transitionId)
    of DaveMlsWelcomeOp:
      # Binary format: [2-byte big-endian transition_id][MLS welcome data]
      if payload.len < 2:
        voiceLog "DAVE: Welcome too short: ", payload.len
        return
      let transitionId = (int(payload[0]) shl 8) or int(payload[1])
      let welcome = payload[2..^1]
      voiceLog "DAVE: Welcome id=", transitionId, " welcome_len=", welcome.len
      let welcomeResult = processWelcome(vc.daveSession, welcome,
          vc.getRecognizedUserIdsWithSelf())
      if welcomeResult == nil:
        voiceLog "DAVE: welcome failed, flagging invalid and resending key package"
        await vc.sendMlsInvalidCommitWelcome(transitionId)
        await vc.sendMlsKeyPackage()
      else:
        voiceLog "DAVE: welcome success, preparing ratchets"
        daveWelcomeResultDestroy(welcomeResult)
        let protoVer = daveSessionGetProtocolVersion(vc.daveSession)
        vc.prepareDaveProtocolRatchets(transitionId, protoVer)
        await vc.sendReadyForTransition(transitionId)
    else:
      voiceLog "DAVE: unhandled binary opcode ", op

proc voiceEventLoop(vc: VoiceConnection) {.async.} =
  ## Main receive loop for the voice WebSocket.
  while vc.ws.readyState == ReadyState.Open and vc.running:
    let (opcode, data) = await vc.ws.receivePacket()
    case opcode
    of Text:
      voiceLog "Voice WS text: ", data[0..min(data.len-1, 500)]
      let event = parseJson(data)
      await vc.handleVoiceTextEvent(event)
    of Binary:
      # Binary DAVE frame format (server→client):
      #   [2-byte big-endian sequence number][1-byte opcode][payload]
      if data.len < 3:
        voiceLog "Voice WS binary too short: len=", data.len
      else:
        let seqNum = (int(data[0].ord) shl 8) or int(data[1].ord)
        let binaryOp = int(data[2].ord)
        # Track sequence number for heartbeat seq_ack
        vc.lastSeqAck = seqNum
        voiceLog "Voice WS binary: seq=", seqNum, " op=", binaryOp,
            " payload_len=", data.len - 3
        when defined(guildyVoice):
          var payload = newSeq[uint8](data.len - 3)
          if payload.len > 0:
            copyMem(addr payload[0], unsafeAddr data[3], payload.len)
          await vc.handleDaveBinaryEvent(binaryOp, payload)
        else:
          voiceLog "Voice: binary DAVE opcode ", binaryOp, " ignored (guildyVoice not defined)"
    of Close:
      var closeCode: int = 0
      var closeReason = ""
      if data.len >= 2:
        closeCode = (data[0].ord shl 8) or data[1].ord
        if data.len > 2:
          closeReason = data[2..^1]
      voiceLog "Voice WS close frame: code=", closeCode, " reason=", closeReason
      vc.ws.readyState = Closed
      return
    of Ping:
      await vc.ws.send(data, Pong)
    of Pong, Cont:
      discard

proc connectVoiceGateway*(state: VoiceState,
    onMilestone: OnVoiceMilestoneEvent = nil): Future[VoiceConnection] {.async.} =
  ## Connect to the Discord voice WebSocket and perform the identify handshake.
  let url = "wss://" & state.endpoint & "/?v=8"
  voiceLog "Connecting to Voice Gateway: ", url

  let wsClient = await newWebSocket(url)
  var vc = VoiceConnection(
    state: state,
    ws: wsClient,
    running: true,
    lastHeartbeat: 0.0,
    lastSeqAck: -1,
    ready: false,
    onMilestone: onMilestone,
  )

  when defined(guildyVoice):
    vc.daveSession = createDaveSession("")
    vc.daveTransitions = initTable[int, uint16]()
    vc.recognizedUserIds = @[]
    vc.latestPreparedTransitionVersion = 0
    voiceLog "DAVE: session created, max protocol version=",
        daveMaxSupportedProtocolVersion()
    vc.fireMilestone(vmDaveSessionCreated)

  # Receive Hello (opcode 8) with heartbeat_interval.
  let helloPacket = await wsClient.receiveStrPacket()
  let helloData = parseJson(helloPacket)
  let heartbeatIntervalMs = helloData["d"]["heartbeat_interval"].getFloat
  voiceLog "Voice Hello received; heartbeat_interval=", heartbeatIntervalMs
  vc.fireMilestone(vmHelloReceived)

  # Start voice heartbeat loop.
  asyncCheck vc.voiceHeartbeat(heartbeatIntervalMs)

  # Send Identify (opcode 0).
  when defined(guildyVoice):
    let maxVer = daveMaxSupportedProtocolVersion()
    let identifyPayload = %*{
      "op": VoiceIdentifyOp,
      "d": {
        "server_id": state.guildId,
        "user_id": state.userId,
        "session_id": state.sessionId,
        "token": state.token,
        "max_dave_protocol_version": maxVer
      }
    }
  else:
    let identifyPayload = %*{
      "op": VoiceIdentifyOp,
      "d": {
        "server_id": state.guildId,
        "user_id": state.userId,
        "session_id": state.sessionId,
        "token": state.token
      }
    }
  voiceLog "Voice Identify payload: ", $identifyPayload
  await wsClient.send($identifyPayload)
  voiceLog "Voice Identify sent"
  vc.fireMilestone(vmIdentifySent)

  # Enter event loop (blocks until disconnect).
  try:
    await vc.voiceEventLoop()
  except WebSocketClosedError:
    voiceLog "Voice WS closed (WebSocketClosedError)"
  except CatchableError as e:
    voiceLog "Voice WS error: ", e.msg, " (", e.name, ")"

  # Cleanup on exit.
  when defined(guildyVoice):
    if vc.daveSession != nil:
      daveSessionDestroy(vc.daveSession)
      vc.daveSession = nil
  try: wsClient.close() except: discard
  vc.fireMilestone(vmDisconnected)
  result = vc

proc disconnectVoice*(vc: VoiceConnection) =
  ## Close the voice WebSocket connection.
  vc.running = false
  when defined(guildyVoice):
    if vc.daveSession != nil:
      daveSessionDestroy(vc.daveSession)
      vc.daveSession = nil
  if vc.udpSocket != nil:
    try: vc.udpSocket.close() except: discard
  if vc.ws != nil:
    try: vc.ws.close() except: discard
