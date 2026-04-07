import
  std/unittest,
  ../src/guildy

suite "onTypingStart callback":
  test "onTypingStart is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onTypingStart == nil

  test "onTypingStart can be assigned":
    let c = newGuildyClient("fake-token")
    c.onTypingStart = proc(client: GuildyClient, channelId: string, userId: string, timestamp: int) {.gcsafe.} =
      discard
    check c.onTypingStart != nil
