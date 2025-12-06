## Public interface to Guildy
## Minimal Discord client (REST + Gateway)

import
  std/[strformat, uri, json, options, times, os, strutils, asyncdispatch, random],
  curly, ws, jsony

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
    mentions*: seq[string]
    mention_roles*: seq[string]
    reactions*: seq[DiscordReaction]
    pinned*: bool
    mention_everyone*: bool
    tts*: bool
    timestamp*: string
    edited_timestamp*: Option[string]
    flags*: int
    components*: seq[string]

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
    ws*: ws.WebSocket
    running*: bool
    lastHeartbeat*: float
    sessionId*: string
    sequence*: int

const
  DefaultUserAgent = "Guildy Client"
  DefaultCurlTimeout: float32 = 60 * 3
  # Intents: VOICE_STATES(128) + GUILD_MESSAGES(512) + GUILD_MESSAGE_REACTIONS(1024)
  #          + DIRECT_MESSAGES(4096) + DIRECT_MESSAGE_REACTIONS(8192)
  DefaultIntents = 13952
  DefaultCacheDir = "/tmp/guildy_cache/"

proc newGuildyClient*(
  token: string,
  curlPoolSize: int = 16,
  userAgent: string = DefaultUserAgent,
  apiBase: string = "https://discord.com/api/v9",
  intents: int = DefaultIntents,
  curlTimeoutSec: float32 = DefaultCurlTimeout
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
    running: true,
    lastHeartbeat: 0.0,
    sessionId: "",
    sequence: 0,
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
  var headers: curly.HttpHeaders
  headers["Authorization"] = &"Bot {c.token}"
  headers["User-Agent"] = c.userAgent
  headers["Content-Type"] = "application/json"

  let curl = c.curlPool.borrow()
  let resp = curl.makeRequest(verb, $uri, headers, body, c.curlTimeoutSec)
  c.curlPool.recycle(curl)

  if resp.code != 200 and resp.code != 204:
    raise newException(GuildyError, &"discord error: {resp.code} {resp.body}")
  result = resp.body

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
  if text.len > 1900:
    text = text[0..1900]
  let body = %*{ "content": text }
  let resp = c.disCall("POST", c.channelMessagesUri(channelID, 1), toJson(body))
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
          { "name": "Final Fantasy XIV", "type": 0 } 
        ],
        "afk": false
      }
    }
  }
  await ws.send(toJson(payload))

proc handleEvent(
  c: GuildyClient,
  ws: ws.WebSocket,
  event: JsonNode,
  onRaw: OnRawEvent,
  onMessage: OnMessageEvent,
  onReaction: OnReactionEvent
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
        "activities": [ { "name": "Final Fantasy XIV", "type": 0 } ],
        "afk": false
      }
    }
    await ws.send(toJson(presenceUpdate))
  elif t == "RESUMED":
    discard
  elif t == "MESSAGE_CREATE" or t == "MESSAGE_UPDATE":
    if onMessage != nil:
      let msg = fromJson(event["d"].pretty, DiscordMessage)
      onMessage(c, msg)
  elif t == "VOICE_STATE_UPDATE" or t == "VOICE_SERVER_UPDATE":
    discard
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
  onReaction: OnReactionEvent
) {.async.} =
  while ws.readyState == ReadyState.Open and c.running:
    let packet = await ws.receiveStrPacket()
    let event = parseJson(packet)
    await c.handleEvent(ws, event, onRaw, onMessage, onReaction)

proc connectGateway(c: GuildyClient, resume = false, onRaw: OnRawEvent, onMessage: OnMessageEvent, onReaction: OnReactionEvent) {.async.} =
  echo "Connecting to Discord Gateway"
  let wsClient = await newWebSocket("wss://gateway.discord.gg/?v=9&encoding=json")
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

  await c.eventLoop(wsClient, onRaw, onMessage, onReaction)
  # ensure close when loop exits
  try: wsClient.close() except: discard

proc startGateway*(
  c: GuildyClient,
  onRaw: OnRawEvent = nil,
  onMessage: OnMessageEvent = nil,
  onReaction: OnReactionEvent = nil
) =
  ## Blocking loop that maintains a gateway connection and auto-reconnects.
  while c.running:
    try:
      waitFor c.connectGateway(resume = c.sessionId.len > 0, onRaw, onMessage, onReaction)
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

