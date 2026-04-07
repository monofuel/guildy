import
  std/unittest,
  ../src/guildy

suite "onGuildCreate callback":
  test "onGuildCreate is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onGuildCreate == nil

  test "onGuildCreate can be assigned":
    let c = newGuildyClient("fake-token")
    var called = false
    c.onGuildCreate = proc(client: GuildyClient, guild: DiscordGuild) {.gcsafe.} =
      called = true
    check c.onGuildCreate != nil
