import
  std/unittest,
  ../src/guildy

suite "onGuildMemberAdd callback":
  test "onGuildMemberAdd is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onGuildMemberAdd == nil

  test "onGuildMemberAdd can be assigned":
    let c = newGuildyClient("fake-token")
    c.onGuildMemberAdd = proc(client: GuildyClient, guildId: string, member: GuildMember) {.gcsafe.} =
      discard
    check c.onGuildMemberAdd != nil

suite "onGuildMemberRemove callback":
  test "onGuildMemberRemove is nil by default":
    let c = newGuildyClient("fake-token")
    check c.onGuildMemberRemove == nil

  test "onGuildMemberRemove can be assigned":
    let c = newGuildyClient("fake-token")
    c.onGuildMemberRemove = proc(client: GuildyClient, guildId: string, user: Author) {.gcsafe.} =
      discard
    check c.onGuildMemberRemove != nil
