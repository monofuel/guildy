import
  std/[unittest, os, strutils, tables, times, locks, json],
  ../src/guildy

# manual dm test
# this test is manually ran by an monofuel
# it will send a message to monofuel, expect a response from monofuel, and then send a response back

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

var token: string
var stateLock: Lock
var receivedFromMonofuel: bool

const MonofuelUserId = "215660018010161152"

proc gatewayThreadProc() {.thread, gcsafe.} =
  let tok = getEnv("TOKEN", "")
  if tok.len == 0:
    return
  var localClient = newGuildyClient(tok)
  proc onMsg(c: GuildyClient, msg: DiscordMessage) {.gcsafe.} =
    if msg.author.id == MonofuelUserId:
      acquire(stateLock)
      receivedFromMonofuel = true
      release(stateLock)
      c.stop()
  proc onRaw(c: GuildyClient, event: JsonNode) {.gcsafe.} = discard
  localClient.startGateway(onRaw = onRaw, onMessage = onMsg)

proc ensureEnv() =
  var tok = getEnv("TOKEN", "")
  if tok == "":
    let kv = loadDotEnv(".env")
    for k, v in kv.pairs:
      if getEnv(k, "") == "":
        putEnv(k, v)
    tok = getEnv("TOKEN", "")
  token = tok

suite "guildy":
  ensureEnv()
  
  test "manual dm websocket":
    if token != "":
      initLock(stateLock)
      receivedFromMonofuel = false

      let restClient = newGuildyClient(token)

      # Create the DM channel first (REST)
      let dmChannelId = restClient.createDMChannel(MonofuelUserId)
      check dmChannelId.len > 0

      # Start gateway in a background thread
      var gwThread: Thread[void]
      createThread(gwThread, gatewayThreadProc)

      # Send initial DM
      let startMsg = restClient.postChannelMessage(dmChannelId, "[guildy manual test] ping at " & $now())
      check startMsg.id.len > 0
      echo "Sent DM. Reply to me within 2 minutes to proceed..."

      # Wait for reply from Monofuel
      var waitedMs = 0
      let timeoutMs = 2 * 60 * 1000
      while true:
        acquire(stateLock)
        let got = receivedFromMonofuel
        release(stateLock)
        if got: break
        if waitedMs >= timeoutMs: break
        sleep(200)
        waitedMs += 200

      acquire(stateLock)
      let gotReply = receivedFromMonofuel
      release(stateLock)

      if gotReply:
        let resp = restClient.postChannelMessage(dmChannelId, "ack")
        check resp.id.len > 0
      else:
        echo "Did not receive a reply in time."

      joinThread(gwThread)

