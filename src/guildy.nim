## Public interface to Guildy
## Minimal Discord client (REST + Gateway)

import
  std/[strformat, uri, json, options, times, os, strutils, asyncdispatch, random, tables],
  curly, ws, jsony,
  guildy/voice

# -------------------------------
# Types — Discord API objects

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
    `type`*: int
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

  GuildChannel* = ref object
    id*: string
    `type`*: int
    name*: Option[string]

# -------------------------------
# Types — Interaction (inbound from gateway, exposed to consumers)

type
  InteractionUser* = ref object
    ## Discord user object (subset of fields used in interactions).
    id*: string

  InteractionMember* = ref object
    ## Guild member wrapper containing the user object.
    user*: InteractionUser

  InteractionCommandData* = ref object
    ## The data payload of a slash command interaction.
    name*: string

  InteractionEvent* = ref object
    ## Raw INTERACTION_CREATE event payload from Discord.
    id*: string
    token*: string
    channel_id*: string
    guild_id*: string
    data*: InteractionCommandData
    member*: InteractionMember
    user*: InteractionUser

  DiscordInteraction* = ref object
    ## Parsed interaction delivered to consumer callbacks.
    id*: string
    token*: string
    command_name*: string
    channel_id*: string
    user_id*: string
    guild_id*: string

# -------------------------------
# Types — Gateway inbound events (internal, for jsony deserialization)

type
  ReadyApplication = ref object
    id*: string

  ReadyEvent = ref object
    session_id*: string
    application*: ReadyApplication

  HelloEvent = ref object
    heartbeat_interval*: float

  ReactionEvent = ref object
    channel_id*: string
    message_id*: string
    user_id*: string
    emoji*: DiscordEmoji

  VoiceStateUpdateEvent = ref object
    guild_id*: string
    session_id*: string
    user_id*: string

  VoiceServerUpdateEvent = ref object
    guild_id*: string
    token*: string
    endpoint*: string

# -------------------------------
# Types — Outbound REST bodies (internal, for jsony serialization)

type
  MessagePost = ref object
    ## Body for POST /channels/{id}/messages.
    content*: string

  DmChannelPost = ref object
    ## Body for POST /users/@me/channels.
    recipient_id*: string

  CreateChannelPost = ref object
    ## Body for POST /guilds/{id}/channels.
    name*: string
    `type`*: int
    bitrate*: int

  InteractionResponseData = ref object
    ## Inner data for interaction callback response.
    content*: string

  InteractionResponse = ref object
    ## Body for POST /interactions/{id}/{token}/callback.
    `type`*: int
    data*: InteractionResponseData

# -------------------------------
# Types — Slash command registration

type
  SlashCommandOption* = ref object
    ## An option for a slash command (e.g. a required string argument).
    name*: string
    description*: string
    `type`*: int
    required*: bool

  SlashCommand* = ref object
    ## A slash command definition for registration via PUT.
    name*: string
    description*: string
    `type`*: int
    options*: seq[SlashCommandOption]

# -------------------------------
# Types — Outbound gateway payloads (internal)

type
  ResumeData = ref object
    token*: string
    session_id*: string
    seq*: int

  PresenceActivity = ref object
    name*: string
    `type`*: int

  PresenceData = ref object
    since*: Option[int]
    activities*: seq[PresenceActivity]
    status*: string
    afk*: bool

  VoiceStateData = ref object
    guild_id*: string
    channel_id*: Option[string]
    self_mute*: bool
    self_deaf*: bool

proc dumpHook*(s: var string, v: PresenceData) =
  ## Custom serialization so that "since" is written as null (not omitted)
  ## when the value is none. Discord requires "since" to be present.
  s.add "{"
  s.add "\"since\":"
  if v.since.isSome:
    s.dumpHook(v.since.get)
  else:
    s.add "null"
  s.add ",\"activities\":"
  s.dumpHook(v.activities)
  s.add ",\"status\":"
  s.dumpHook(v.status)
  s.add ",\"afk\":"
  s.dumpHook(v.afk)
  s.add "}"

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
    appId*: string

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
  InitialBackoffMs = 1000
  MaxBackoffMs = 60_000
  BackoffMultiplier = 2.0

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
  ## Create a new Guildy Discord client.
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
  ## URI for guild channel operations.
  result = c.apiBase / "/guilds/" / guildID / "/channels"

proc channelMessagesUri(
  c: GuildyClient,
  channelID: string,
  limit: int,
  before: string = ""
): Uri =
  ## URI for fetching channel messages with query params.
  if limit <= 0:
    raise newException(GuildyError, "limit must be > 0")
  result = c.apiBase / "/channels/" / channelID / "/messages"
  var params: seq[(string, string)] = @[("limit", $limit)]
  if before != "":
    params.add(("before", before))
  result = result ? params

proc applicationCommandsUri(c: GuildyClient, guildId: string = ""): Uri =
  ## URI for bulk-overwriting application commands.
  if guildId.len > 0:
    result = c.apiBase / "/applications" / c.appId / "guilds" / guildId / "commands"
  else:
    result = c.apiBase / "/applications" / c.appId / "commands"

proc interactionCallbackUri(c: GuildyClient, interactionId, token: string): Uri =
  ## URI for responding to an interaction.
  result = c.apiBase / "/interactions" / interactionId / token / "callback"

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
  ## Fetch the list of channels in a guild.
  let resp = c.disCall("GET", c.guildChannelsUri(guildID))
  result = fromJson(resp, seq[GuildChannel])

proc getChannelMessages*(
  c: GuildyClient,
  channelID: string,
  limit: int = 50,
  before: string = ""
): seq[DiscordMessage] =
  ## Fetch recent messages from a channel.
  let resp = c.disCall("GET", c.channelMessagesUri(channelID, limit, before))
  result = fromJson(resp, seq[DiscordMessage])

proc postChannelMessage*(c: GuildyClient, channelID: string, content: string): DiscordMessage {.gcsafe.} =
  ## Post a text message to a channel.
  var text = content
  if text.len > 2000:
    text = text[0 ..< 2000]
  let resp = c.disCall("POST", c.apiBase / "/channels/" / channelID / "/messages",
    toJson(MessagePost(content: text)))
  result = fromJson(resp, DiscordMessage)

proc deleteChannelMessage*(c: GuildyClient, channelID: string, messageID: string) =
  ## Delete a message from a channel.
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
# Slash commands

proc registerCommands*(c: GuildyClient, commands: string, guildId: string = ""): string =
  ## Bulk overwrite slash commands. commands is a jsony JSON string of command definitions.
  ## guildId = "" for global commands (slow propagation), or a guild ID for instant guild commands.
  result = c.disCall("PUT", c.applicationCommandsUri(guildId), commands)

proc respondToInteraction*(c: GuildyClient, interactionId, token: string,
                            responseType: int, content: string = "") =
  ## Respond to a slash command interaction.
  ## responseType 4 = immediate reply, 5 = deferred (ack, edit later).
  let body = InteractionResponse(
    `type`: responseType,
    data: InteractionResponseData(content: content)
  )
  discard c.disCall("POST", c.interactionCallbackUri(interactionId, token), toJson(body))

proc editInteractionResponse*(c: GuildyClient, token: string, content: string) =
  ## Edit the original interaction response (used after deferring with type 5).
  let uri = c.apiBase / "/webhooks" / c.appId / token / "messages" / "@original"
  discard c.disCall("PATCH", uri, toJson(MessagePost(content: content)))


# -------------------------------
# DMs

type
  DmChannelResp = ref object
    id*: string

proc createDMChannel*(c: GuildyClient, recipientId: string): string =
  ## Create a DM channel with the given user and return the channel id.
  let resp = c.disCall("POST", c.apiBase / "/users/@me/channels",
    toJson(DmChannelPost(recipient_id: recipientId)))
  let parsed = fromJson(resp, DmChannelResp)
  result = parsed.id


# -------------------------------
# Gateway (WebSocket)

type
  OnRawEvent* = proc(c: GuildyClient, event: JsonNode) {.gcsafe.}
  OnMessageEvent* = proc(c: GuildyClient, msg: DiscordMessage) {.gcsafe.}
  OnReactionEvent* = proc(c: GuildyClient, channelId: string, messageId: string, emoji: DiscordEmoji, userId: string) {.gcsafe.}
  OnInteractionEvent* = proc(c: GuildyClient, interaction: DiscordInteraction) {.gcsafe.}

proc stop*(c: GuildyClient) =
  ## Stop the gateway connection.
  c.running = false
  if c.ws != nil:
    try: c.ws.close() except: discard

proc sendGatewayOp(ws: ws.WebSocket, op: int, d: string) {.async.} =
  ## Send a gateway opcode with a pre-serialized JSON payload for d.
  await ws.send("{\"op\":" & $op & ",\"d\":" & d & "}")

proc sendHeartbeat(c: GuildyClient, ws: ws.WebSocket) {.async.} =
  ## Send a heartbeat (opcode 1) with the current sequence number.
  await ws.sendGatewayOp(1, $c.sequence)

proc heartbeat(c: GuildyClient, ws: ws.WebSocket, intervalMs: float, jitter: float) {.async.} =
  ## Background heartbeat loop with jitter.
  while ws.readyState == ReadyState.Open and c.running:
    let actualInterval = (intervalMs + rand(intervalMs * jitter)).int
    await sleepAsync(actualInterval)
    await c.sendHeartbeat(ws)

proc resumeSession(c: GuildyClient, ws: ws.WebSocket) {.async.} =
  ## Resume a previous gateway session after reconnect.
  let data = ResumeData(
    token: c.token,
    session_id: c.sessionId,
    seq: c.sequence
  )
  await ws.sendGatewayOp(6, toJson(data))

proc sendPresenceUpdate(c: GuildyClient, ws: ws.WebSocket) {.async.} =
  ## Send a presence update (opcode 3).
  let data = PresenceData(
    since: none(int),
    status: "online",
    activities: @[PresenceActivity(name: c.activityName, `type`: 0)],
    afk: false
  )
  await ws.sendGatewayOp(3, toJson(data))

proc identifySession(c: GuildyClient, ws: ws.WebSocket) {.async.} =
  ## Send identify payload (opcode 2).
  # Uses %* for the properties sub-object because Discord requires $-prefixed keys
  # ($os, $browser, $device) which cannot be Nim field names.
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
  let data = VoiceStateData(
    guild_id: guildId,
    channel_id: some(channelId),
    self_mute: selfMute,
    self_deaf: selfDeaf
  )
  await c.ws.sendGatewayOp(4, toJson(data))

proc leaveVoiceChannel*(c: GuildyClient, guildId: string) {.async.} =
  ## Send gateway opcode 4 with null channel_id to leave voice.
  if guildId in c.voiceConnections:
    disconnectVoice(c.voiceConnections[guildId])
    c.voiceConnections.del(guildId)
  c.voiceStates.del(guildId)
  let data = VoiceStateData(
    guild_id: guildId,
    channel_id: none(string),
    self_mute: false,
    self_deaf: false
  )
  await c.ws.sendGatewayOp(4, toJson(data))

proc createVoiceChannel*(c: GuildyClient, guildId: string, name: string,
                          bitrate: int = 64000): GuildChannel =
  ## Create a voice channel (type=2) in the given guild.
  let body = CreateChannelPost(name: name, `type`: 2, bitrate: bitrate)
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
  ## Dispatch a gateway event to the appropriate handler.
  if event.hasKey("s") and event["s"].kind in {JInt, JFloat}:
    c.sequence = event["s"].getInt

  let t = if event.hasKey("t"): event["t"].getStr else: ""
  if t == "READY":
    let ready = fromJson($event["d"], ReadyEvent)
    c.sessionId = ready.session_id
    if ready.application != nil:
      c.appId = ready.application.id
    await c.sendPresenceUpdate(ws)
  elif t == "RESUMED":
    discard
  elif t == "MESSAGE_CREATE" or t == "MESSAGE_UPDATE":
    if onMessage != nil:
      let msg = fromJson($event["d"], DiscordMessage)
      onMessage(c, msg)
  elif t == "VOICE_STATE_UPDATE":
    let vs = fromJson($event["d"], VoiceStateUpdateEvent)
    if vs.guild_id in c.voiceStates:
      c.voiceStates[vs.guild_id].sessionId = vs.session_id
      if vs.user_id.len > 0:
        c.voiceStates[vs.guild_id].userId = vs.user_id
  elif t == "VOICE_SERVER_UPDATE":
    let vs = fromJson($event["d"], VoiceServerUpdateEvent)
    echo "VOICE_SERVER_UPDATE: ", $event["d"]
    if vs.guild_id in c.voiceStates:
      c.voiceStates[vs.guild_id].token = vs.token
      c.voiceStates[vs.guild_id].endpoint = vs.endpoint
      # Both voice events received — state is ready.
      if c.voiceStates[vs.guild_id].sessionId.len > 0:
        if c.onVoiceReady != nil:
          c.onVoiceReady(c.voiceStates[vs.guild_id])
        # Automatically connect to voice gateway.
        asyncCheck c.connectAndStoreVoice(c.voiceStates[vs.guild_id])
  elif t == "MESSAGE_REACTION_ADD":
    if onReaction != nil:
      let re = fromJson($event["d"], ReactionEvent)
      onReaction(c, re.channel_id, re.message_id, re.emoji, re.user_id)
  elif t == "INTERACTION_CREATE":
    if onInteraction != nil:
      let ie = fromJson($event["d"], InteractionEvent)
      var interaction = DiscordInteraction()
      interaction.id = ie.id
      interaction.token = ie.token
      interaction.channel_id = ie.channel_id
      interaction.guild_id = ie.guild_id
      if ie.data != nil:
        interaction.command_name = ie.data.name
      if ie.member != nil and ie.member.user != nil:
        interaction.user_id = ie.member.user.id
      elif ie.user != nil:
        interaction.user_id = ie.user.id
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
  ## Main event receive loop.
  while ws.readyState == ReadyState.Open and c.running:
    let packet = await ws.receiveStrPacket()
    let event = parseJson(packet)
    await c.handleEvent(ws, event, onRaw, onMessage, onReaction, onInteraction)

proc connectGateway(c: GuildyClient, resume = false, onRaw: OnRawEvent, onMessage: OnMessageEvent, onReaction: OnReactionEvent, onInteraction: OnInteractionEvent) {.async.} =
  ## Establish a gateway connection, authenticate, and run the event loop.
  echo "Connecting to Discord Gateway"
  let wsClient = await newWebSocket("wss://gateway.discord.gg/?v=10&encoding=json")
  c.ws = wsClient
  echo "Gateway connected"
  # Receive Hello, start heartbeat
  let helloPacket = await wsClient.receiveStrPacket()
  let hello = fromJson($parseJson(helloPacket)["d"], HelloEvent)
  echo "Hello received; heartbeat_interval=", hello.heartbeat_interval
  let jitter = 0.1
  asyncCheck c.heartbeat(wsClient, hello.heartbeat_interval, jitter)

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
  var backoffMs = InitialBackoffMs
  while c.running:
    try:
      waitFor c.connectGateway(resume = c.sessionId.len > 0, onRaw, onMessage, onReaction, onInteraction)
      backoffMs = InitialBackoffMs
    except WebSocketClosedError:
      echo "WebSocket closed; will reconnect"
      if c.running:
        let jitter = rand(backoffMs div 4)
        sleep(backoffMs + jitter)
        backoffMs = min(int(backoffMs.float * BackoffMultiplier), MaxBackoffMs)
        # on reconnect attempts, force identify if too long without heartbeat
        if c.lastHeartbeat != 0 and (epochTime() - c.lastHeartbeat) > 120:
          c.sessionId = ""
    except CatchableError as e:
      echo "Gateway error: ", e.msg
      if c.running:
        let jitter = rand(backoffMs div 4)
        sleep(backoffMs + jitter)
        backoffMs = min(int(backoffMs.float * BackoffMultiplier), MaxBackoffMs)
