import
  std/unittest,
  ../src/guildy

suite "onChannelCreate callback":
  test "onChannelCreate is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onChannelCreate == nil

  test "onChannelCreate can be assigned":
    let c = newGuildyClient("fake-token")
    c.onChannelCreate = proc(client: GuildyClient, channel: GuildChannel) {.gcsafe.} =
      discard
    check c.onChannelCreate != nil

suite "onChannelUpdate callback":
  test "onChannelUpdate is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onChannelUpdate == nil

  test "onChannelUpdate can be assigned":
    let c = newGuildyClient("fake-token")
    c.onChannelUpdate = proc(client: GuildyClient, channel: GuildChannel) {.gcsafe.} =
      discard
    check c.onChannelUpdate != nil

suite "onChannelDelete callback":
  test "onChannelDelete is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onChannelDelete == nil

  test "onChannelDelete can be assigned":
    let c = newGuildyClient("fake-token")
    c.onChannelDelete = proc(client: GuildyClient, channel: GuildChannel) {.gcsafe.} =
      discard
    check c.onChannelDelete != nil
