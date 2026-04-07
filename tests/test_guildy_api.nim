import
  std/[unittest, os, strutils, osproc, tables, times],
  ../src/guildy

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

proc ensureEnv() =
  if getEnv("TOKEN", "") != "": return
  let kv = loadDotEnv(".env")
  for k, v in kv.pairs:
    if getEnv(k, "") == "":
      putEnv(k, v)
  
  token = getEnv("TOKEN", "")

const
  TestChannel = "1404137573567434783"
  MonofuelUserId = "215660018010161152"
  MonolabGuildId = "1180587895921328158"


suite "guildy":
  ensureEnv()
  
  test "channel: post":
    let client = newGuildyClient(token)
    let msg = client.postChannelMessage(TestChannel, "[guildy test] hello at " & $now())
    check msg.id.len > 0

  test "channel: post and delete":
    let client = newGuildyClient(token)
    let msg = client.postChannelMessage(TestChannel, "[guildy test] hello at " & $now())
    check msg.id.len > 0
    client.deleteChannelMessage(TestChannel, msg.id)

  test "channel: list messages":
    let client = newGuildyClient(token)
    let msgs = client.getChannelMessages(TestChannel, 5)
    check msgs.len >= 0

  test "dm: send message":
    let client = newGuildyClient(token)
    let dmChannel = client.createDMChannel(MonofuelUserId)
    check dmChannel.len > 0
    let dm = client.postChannelMessage(dmChannel, "[guildy test dm] hello at " & $now())
    check dm.id.len > 0

  test "guild: get guild info":
    let client = newGuildyClient(token)
    let guild = client.getGuild(MonolabGuildId)
    check guild.id == MonolabGuildId
    check guild.name.len > 0
    check guild.owner_id.len > 0


