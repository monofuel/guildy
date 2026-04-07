import
  std/unittest,
  ../src/guildy

suite "onPresenceUpdate callback":
  test "onPresenceUpdate is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onPresenceUpdate == nil

  test "onPresenceUpdate can be assigned":
    let c = newGuildyClient("fake-token")
    c.onPresenceUpdate = proc(client: GuildyClient, guildId: string, userId: string, status: string) {.gcsafe.} =
      discard
    check c.onPresenceUpdate != nil
