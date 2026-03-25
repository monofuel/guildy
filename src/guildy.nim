## Public interface to Guildy
## Minimal Discord client (REST + Gateway)

import
  std/[strformat, uri, json, options, times, os, strutils, asyncdispatch, random, tables],
  curly, ws, jsony,
  guildy/voice

# -------------------------------
# Types

type
  AvatarDecorationData* = ref object
    asset*: string
    sku_id*: string
    expires_at*: int

  Author* = ref object
    id*: string
    username*: string
    avatar*: string
    discriminator*: string
    public_flags*: int
    flags*: int
    bot*: bool
    banner*: Option[string]
    accent_color*: Option[string]
    global_name*: Option[string]
    avatar_decoration_data*: Option[AvatarDecorationData]
    banner_color*: Option[string]

  DiscordEmoji* = ref object
    id*: string
    name*: string
    animated*: bool

  DiscordReaction* = ref object
    count*: int
    me*: bool
    emoji*: DiscordEmoji
    user_id*: Option[string]

  DiscordAttachment* = ref object
    id*: string
    filename*: string
    size*: int
    url*: string
    proxyUrl*: string
    height*: Option[int]
    width*: Option[int]
    contentType*: string
    placeholder*: Option[string]
    placeholderVersion*: Option[int]

  DiscordMessage* = ref object
    id*: string
    ttype*: int
    content*: string
    channel_id*: string
    author*: Author
    attachments*: seq[DiscordAttachment]
    mentions*: seq[JsonNode]
    mention_roles*: seq[string]
    reactions*: seq[DiscordReaction]
    pinned*: bool
    mention_everyone*: bool
    tts*: bool
    timestamp*: string
    edited_timestamp*: Option[string]
    flags*: int
    components*: seq[JsonNode]

  DiscordInteraction* = ref object
    id*: string
    token*: string
    command_name*: string
    channel_id*: string
    user_id*: string
    guild_id*: string

  GuildChannel* = ref object
    id*: string
    channel_type*: int # json field `type`
    name*: Option[string]

proc renameHook*(v: var GuildChannel, fieldName: var string) =
  if fieldName == "type":
    fieldName = "channel_type"


# -------------------------------
# Client

type
  GuildyError* = object of CatchableError

  GuildyClient* = ref object
    # REST
    token*: string
    userAgent*: string
    apiBase*: Uri
    curlPool*: CurlPool
    curlTimeoutSec*: float32

    # Gateway
    intents*: int
    activityName*: string
    ws*: ws.WebSocket
    running*: bool
    lastHeartbeat*: float
    sessionId*: string
    sequence*: int

    # Voice
    voiceStates*: Table[string, VoiceState]
    voiceConnections*: Table[string, VoiceConnection]
    onVoiceReady*: OnVoiceStateEvent
    onVoiceConnected*: OnVoiceConnectedEvent
    onVoiceMilestone*: OnVoiceMilestoneEvent

const
  DefaultUserAgent = "Guildy Client"
  DefaultCurlTimeout: float32 = 60 * 3
  DefaultCacheDir = "/tmp/guildy_cache/"
  MaxRateLimitRetries = 3

  # Discord gateway intent bit flags
  IntentGuilds* = 1 shl 0
  IntentGuildMembers* = 1 shl 1
  IntentGuildModeration* = 1 shl 2
  IntentGuildEmojisAndStickers* = 1 shl 3
  IntentGuildIntegrations* = 1 shl 4
  IntentGuildWebhooks* = 1 shl 5
  IntentGuildInvites* = 1 shl 6
  IntentGuildVoiceStates* = 1 shl 7
  IntentGuildPresences* = 1 shl 8
  IntentGuildMessages* = 1 shl 9
  IntentGuildMessageReactions* = 1 shl 10
  IntentGuildMessageTyping* = 1 shl 11
  IntentDirectMessages* = 1 shl 12
  IntentDirectMessageReactions* = 1 shl 13
  IntentDirectMessageTyping* = 1 shl 14
  IntentMessageContent* = 1 shl 15

  DefaultIntents* = IntentGuildVoiceStates or IntentGuildMessages or
    IntentGuildMessageReactions or IntentDirectMessages or
    IntentDirectMessageReactions or IntentMessageContent

proc newGuildyClient*(
  token: string,
  curlPoolSize: int = 16,
  userAgent: string = DefaultUserAgent,
  apiBase: string = "https://discord.com/api/v10",
  intents: int = DefaultIntents,
  curlTimeoutSec: float32 = DefaultCurlTimeout,
  activityName: string = "Final Fantasy XIV"
): GuildyClient =
  if token.len == 0:
    raise newException(GuildyError, "Missing Discord bot token")
  randomize()
  result = GuildyClient(
    token: token,
    userAgent: userAgent,
    apiBase: parseUri(apiBase),
    curlPool: newCurlPool(curlPoolSize),
    curlTimeoutSec: curlTimeoutSec,
    intents: intents,
    activityName: activityName,
    running: true,
    lastHeartbeat: 0.0,
    sessionId: "",
    sequence: 0,
    voiceStates: initTable[string, VoiceState](),
    voiceConnections: initTable[string, VoiceConnection](),
  )


# -------------------------------
# REST helpers

proc guildChannelsUri(c: GuildyClient, guildID: string): Uri =
  result = c.apiBase / "/guilds/" / guildID / "/channels"

proc channelMessagesUri(
  c: GuildyClient,
  channelID: string,
  limit: int,
  before: string = ""
): Uri =
  if limit <= 0:
    raise newException(GuildyError, "limit must be > 0")
  result = c.apiBase / "/channels/" / channelID / "/messages"
  var params: seq[(string, string)] = @[("limit", $limit)]
  if before != "":
    params.add(("before", before))
  result = result ? params

proc disCall(c: GuildyClient, verb: string, uri: Uri, body: string = ""): string {.gcsafe.} =
  ## Make an authenticated REST call to the Discord API with rate limit retry.
  var headers: curly.HttpHeaders
  headers["Authorization"] = &"Bot {c.token}"
  headers["User-Agent"] = c.userAgent
  headers["Content-Type"] = "application/json"

  for attempt in 0 ..< MaxRateLimitRetries:
    let curl = c.curlPool.borrow()
    let resp = curl.makeRequest(verb, $uri, headers, body, c.curlTimeoutSec)
    c.curlPool.recycle(curl)

    if resp.code == 200 or resp.code == 204:
      return resp.body

    if resp.code == 429:
      # Rate limited — sleep for the duration Discord tells us
      let retryAfter = resp.headers["Retry-After"]
      let sleepMs = if retryAfter.len > 0:
        (parseFloat(retryAfter) * 1000).int
      else:
        1000 * (attempt + 1)
      echo &"Rate limited on {verb} {uri}, retrying after {sleepMs}ms (attempt {attempt + 1}/{MaxRateLimitRetries})"
      sleep(sleepMs)
      continue

    raise newException(GuildyError, &"discord error: {resp.code} {resp.body}")

  raise newException(GuildyError, &"rate limited after {MaxRateLimitRetries} retries on {verb} {uri}")

proc getGuildChannels*(c: GuildyClient, guildID: string): seq[GuildChannel] =
  let resp = c.disCall("GET", c.guildChannelsUri(guildID))
  result = fromJson(resp, seq[GuildChannel])

proc getChannelMessages*(
  c: GuildyClient,
  channelID: string,
  limit: int = 50,
  before: string = ""
): seq[DiscordMessage] =
  let resp = c.disCall("GET", c.channelMessagesUri(channelID, limit, before))
  try:
    result = fromJson(resp, seq[DiscordMessage])
  except Exception as e:
    echo "Error parsing JSON: ", e.msg
    echo resp
    raise e

proc postChannelMessage*(c: GuildyClient, channelID: string, content: string): DiscordMessage {.gcsafe.} =
  var text = content
  if text.len > 2000:
    text = text[0 ..< 2000]
  let body = %*{ "content": text }
  let resp = c.disCall("POST", c.apiBase / "/channels/" / channelID / "/messages", toJson(body))
  result = fromJson(resp, DiscordMessage)

proc deleteChannelMessage*(c: GuildyClient, channelID: string, messageID: string) =
  discard c.disCall("DELETE", c.apiBase / "/channels/" / channelID / "/messages/" / messageID)

proc getDiscordAttachment*(c: GuildyClient, attachment: DiscordAttachment, cacheDir: string = DefaultCacheDir): string =
  ## Get the attachment file, caching locally. Returns path to local file.
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let filePath = cacheDir & attachment.id
  result = filePath
  if not fileExists(filePath):
    let curl = c.curlPool.borrow()
    let resp = curl.get(attachment.url)
    c.curlPool.recycle(curl)
    if resp.code != 200:
      raise newException(GuildyError, &"discord error: {resp.code}")
    writeFile(filePath, resp.body)


# -------------------------------
# Gateway (WebSocket)

type
  OnRawEvent* = proc(c: GuildyClient, event: JsonNode) {.gcsafe.}
  OnMessageEvent* = proc(c: GuildyClient, msg: DiscordMessage) {.gcsafe.}
  OnReactionEvent* = proc(c: GuildyClient, channelId: string, messageId: string, emoji: DiscordEmoji, userId: string) {.gcsafe.}
  OnInteractionEvent* = proc(c: GuildyClient, interaction: DiscordInteraction) {.gcsafe.}

proc stop*(c: GuildyClient) =
  c.running = false
  if c.ws != nil:
    try: c.ws.close() except: discard

proc sendHeartbeat(c: GuildyClient, ws: ws.WebSocket) {.async.} =
  let payload = %*{ "op": 1, "d": c.sequence }
  await ws.send(toJson(payload))

proc heartbeat(c: GuildyClient, ws: ws.WebSocket, intervalMs: float, jitter: float) {.async.} =
  while ws.readyState == ReadyState.Open and c.running:
    let actualInterval = (intervalMs + rand(intervalMs * jitter)).int
    await sleepAsync(actualInterval)
    await c.sendHeartbeat(ws)

proc resumeSession(c: GuildyClient, ws: ws.WebSocket) {.async.} =
  let payload = %*{
    "op": 6,
    "d": {
      "token": c.token,
      "session_id": c.sessionId,
      "seq": c.sequence
    }
  }
  await ws.send(toJson(payload))

proc identifySession(c: GuildyClient, ws: ws.WebSocket) {.async.} =
  let payload = %*{
    "op": 2,
    "d": {
      "token": c.token,
      "properties": {"$os": "linux", "$browser": "guildy", "$device": "guildy"},
      "intents": c.intents,
      "presence": {
        "status": "online",
        "since": nil,
        "activities": [
          { "name": c.activityName, "type": 0 }
        ],
        "afk": false
      }
    }
  }
  await ws.send(toJson(payload))

proc joinVoiceChannel*(c: GuildyClient, guildId: string, channelId: string,
                        selfMute: bool = false, selfDeaf: bool = false) {.async.} =
  ## Send gateway opcode 4 to join a voice channel.
  c.voiceStates[guildId] = VoiceState(guildId: guildId, channelId: channelId)
  let payload = %*{
    "op": 4,
    "d": {
      "guild_id": guildId,
      "channel_id": channelId,
      "self_mute": selfMute,
      "self_deaf": selfDeaf
    }
  }
  await c.ws.send(toJson(payload))

proc leaveVoiceChannel*(c: GuildyClient, guildId: string) {.async.} =
  ## Send gateway opcode 4 with null channel_id to leave voice.
  if guildId in c.voiceConnections:
    disconnectVoice(c.voiceConnections[guildId])
    c.voiceConnections.del(guildId)
  c.voiceStates.del(guildId)
  let payload = %*{
    "op": 4,
    "d": {
      "guild_id": guildId,
      "channel_id": nil,
      "self_mute": false,
      "self_deaf": false
    }
  }
  await c.ws.send(toJson(payload))

proc createVoiceChannel*(c: GuildyClient, guildId: string, name: string,
                          bitrate: int = 64000): GuildChannel =
  ## Create a voice channel (type=2) in the given guild.
  let body = %*{
    "name": name,
    "type": 2,
    "bitrate": bitrate
  }
  let resp = c.disCall("POST", c.guildChannelsUri(guildId), toJson(body))
  result = fromJson(resp, GuildChannel)

proc connectAndStoreVoice(c: GuildyClient, state: VoiceState) {.async.} =
  ## Connect to the voice gateway and store the connection.
  try:
    let vc = await connectVoiceGateway(state, c.onVoiceMilestone)
    c.voiceConnections[state.guildId] = vc
    if c.onVoiceConnected != nil:
      c.onVoiceConnected(vc)
  except CatchableError as e:
    echo "Voice gateway error: ", e.msg

proc handleEvent(
  c: GuildyClient,
  ws: ws.WebSocket,
  event: JsonNode,
  onRaw: OnRawEvent,
  onMessage: OnMessageEvent,
  onReaction: OnReactionEvent,
  onInteraction: OnInteractionEvent
) {.async.} =
  if event.hasKey("s") and event["s"].kind in {JInt, JFloat}:
    c.sequence = event["s"].getInt

  let t = if event.hasKey("t"): event["t"].getStr else: ""
  if t == "READY":
    c.sessionId = event["d"]["session_id"].getStr
    let presenceUpdate = %*{
      "op": 3,
      "d": {
        "since": nil,
        "status": "online",
        "activities": [ { "name": c.activityName, "type": 0 } ],
        "afk": false
      }
    }
    await ws.send(toJson(presenceUpdate))
  elif t == "RESUMED":
    discard
  elif t == "MESSAGE_CREATE" or t == "MESSAGE_UPDATE":
    if onMessage != nil:
      let msg = fromJson($event["d"], DiscordMessage)
      onMessage(c, msg)
  elif t == "VOICE_STATE_UPDATE":
    let d = event["d"]
    let guildId = d["guild_id"].getStr
    if guildId in c.voiceStates:
      c.voiceStates[guildId].sessionId = d["session_id"].getStr
      if d.hasKey("user_id"):
        c.voiceStates[guildId].userId = d["user_id"].getStr
  elif t == "VOICE_SERVER_UPDATE":
    let d = event["d"]
    let guildId = d["guild_id"].getStr
    echo "VOICE_SERVER_UPDATE: ", $d
    if guildId in c.voiceStates:
      c.voiceStates[guildId].token = d["token"].getStr
      c.voiceStates[guildId].endpoint = d["endpoint"].getStr
      # Both voice events received — state is ready.
      if c.voiceStates[guildId].sessionId.len > 0:
        if c.onVoiceReady != nil:
          c.onVoiceReady(c.voiceStates[guildId])
        # Automatically connect to voice gateway.
        asyncCheck c.connectAndStoreVoice(c.voiceStates[guildId])
  elif t == "MESSAGE_REACTION_ADD":
    if onReaction != nil:
      let d = event["d"]
      var em = DiscordEmoji(id: "", name: "", animated: false)
      if d.hasKey("emoji"):
        if d["emoji"].hasKey("id"): em.id = d["emoji"]["id"].getStr
        if d["emoji"].hasKey("name"): em.name = d["emoji"]["name"].getStr
        if d["emoji"].hasKey("animated"): em.animated = d["emoji"]["animated"].getBool
      let channelId = d["channel_id"].getStr
      let messageId = d["message_id"].getStr
      let userId = d["user_id"].getStr
      onReaction(c, channelId, messageId, em, userId)
  elif t == "INTERACTION_CREATE":
    if onInteraction != nil:
      let d = event["d"]
      var interaction = DiscordInteraction()
      interaction.id = d["id"].getStr
      interaction.token = d["token"].getStr
      interaction.channel_id = d{"channel_id"}.getStr
      interaction.guild_id = d{"guild_id"}.getStr
      if d.hasKey("data") and d["data"].hasKey("name"):
        interaction.command_name = d["data"]["name"].getStr
      # user_id: guild context has member.user.id, DM context has user.id
      if d.hasKey("member") and d["member"].hasKey("user"):
        interaction.user_id = d["member"]["user"]["id"].getStr
      elif d.hasKey("user"):
        interaction.user_id = d["user"]["id"].getStr
      onInteraction(c, interaction)

  if event.hasKey("op"):
    let op = event["op"].getInt
    case op
    of 7:
      ws.close()
      raise newException(WebSocketClosedError, "Discord Reconnect")
    of 1:
      await c.sendHeartbeat(ws)
    of 9:
      await sleepAsync(1000)
      c.sessionId = ""
      await c.identifySession(ws)
    of 11:
      c.lastHeartbeat = epochTime()
    else:
      discard

  if onRaw != nil:
    onRaw(c, event)

proc eventLoop(
  c: GuildyClient,
  ws: ws.WebSocket,
  onRaw: OnRawEvent,
  onMessage: OnMessageEvent,
  onReaction: OnReactionEvent,
  onInteraction: OnInteractionEvent
) {.async.} =
  while ws.readyState == ReadyState.Open and c.running:
    let packet = await ws.receiveStrPacket()
    let event = parseJson(packet)
    await c.handleEvent(ws, event, onRaw, onMessage, onReaction, onInteraction)

proc connectGateway(c: GuildyClient, resume = false, onRaw: OnRawEvent, onMessage: OnMessageEvent, onReaction: OnReactionEvent, onInteraction: OnInteractionEvent) {.async.} =
  echo "Connecting to Discord Gateway"
  let wsClient = await newWebSocket("wss://gateway.discord.gg/?v=10&encoding=json")
  c.ws = wsClient
  echo "Gateway connected"
  # Receive Hello, start heartbeat
  let helloPacket = await wsClient.receiveStrPacket()
  let helloData = parseJson(helloPacket)["d"]
  echo "Hello received; heartbeat_interval=", helloData["heartbeat_interval"].getFloat
  let heartbeatIntervalMs = helloData["heartbeat_interval"].getFloat
  let jitter = 0.1
  asyncCheck c.heartbeat(wsClient, heartbeatIntervalMs, jitter)

  if resume and c.sessionId.len > 0:
    await c.resumeSession(wsClient)
  else:
    await c.identifySession(wsClient)

  await c.eventLoop(wsClient, onRaw, onMessage, onReaction, onInteraction)
  # ensure close when loop exits
  try: wsClient.close() except: discard

proc startGateway*(
  c: GuildyClient,
  onRaw: OnRawEvent = nil,
  onMessage: OnMessageEvent = nil,
  onReaction: OnReactionEvent = nil,
  onInteraction: OnInteractionEvent = nil
) =
  ## Blocking loop that maintains a gateway connection and auto-reconnects.
  while c.running:
    try:
      waitFor c.connectGateway(resume = c.sessionId.len > 0, onRaw, onMessage, onReaction, onInteraction)
    except WebSocketClosedError:
      echo "WebSocket closed; will reconnect"
      if c.running:
        sleep(1000)
        # on reconnect attempts, force identify if too long without heartbeat
        if c.lastHeartbeat != 0 and (epochTime() - c.lastHeartbeat) > 120:
          c.sessionId = ""
    except CatchableError as e:
      echo "Gateway error: ", e.msg
      if c.running:
        sleep(3000)

# -------------------------------
# DMs

type
  DmChannelResp = ref object
    id*: string

proc createDMChannel*(c: GuildyClient, recipientId: string): string =
  ## Create a DM channel with the given user and return the channel id.
  let body = %*{ "recipient_id": recipientId }
  let resp = c.disCall("POST", c.apiBase / "/users/@me/channels", toJson(body))
  let parsed = fromJson(resp, DmChannelResp)
  result = parsed.id

