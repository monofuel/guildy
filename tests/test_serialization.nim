import
  std/[unittest, options, strutils, json],
  jsony,
  ../src/guildy

suite "Author":
  test "round-trip":
    let a = Author(
      id: "123",
      username: "testuser",
      avatar: "abc",
      discriminator: "0001",
      public_flags: 0,
      flags: 0,
      bot: false,
      banner: none(string),
      accent_color: some("ff0000"),
      global_name: some("Test User"),
      avatar_decoration_data: none(AvatarDecorationData),
      banner_color: none(string),
    )
    let j = toJson(a)
    let a2 = fromJson(j, Author)
    check a2.id == "123"
    check a2.username == "testuser"
    check a2.global_name == some("Test User")
    check a2.banner.isNone

suite "DiscordEmoji":
  test "round-trip":
    let e = DiscordEmoji(id: "456", name: "wave", animated: true)
    let j = toJson(e)
    let e2 = fromJson(j, DiscordEmoji)
    check e2.id == "456"
    check e2.name == "wave"
    check e2.animated == true

suite "DiscordReaction":
  test "round-trip with user_id some":
    let r = DiscordReaction(
      count: 3,
      me: true,
      emoji: DiscordEmoji(id: "1", name: "thumbsup", animated: false),
      user_id: some("789"),
    )
    let j = toJson(r)
    let r2 = fromJson(j, DiscordReaction)
    check r2.count == 3
    check r2.me == true
    check r2.user_id == some("789")
    check r2.emoji.name == "thumbsup"

  test "round-trip with user_id none":
    let r = DiscordReaction(
      count: 1,
      me: false,
      emoji: DiscordEmoji(id: "2", name: "heart", animated: false),
      user_id: none(string),
    )
    let j = toJson(r)
    let r2 = fromJson(j, DiscordReaction)
    check r2.user_id.isNone

suite "DiscordAttachment":
  test "round-trip":
    let a = DiscordAttachment(
      id: "att1",
      filename: "image.png",
      size: 1024,
      url: "https://example.com/image.png",
      proxyUrl: "https://proxy.example.com/image.png",
      height: some(100),
      width: some(200),
      contentType: "image/png",
      placeholder: none(string),
      placeholderVersion: none(int),
    )
    let j = toJson(a)
    let a2 = fromJson(j, DiscordAttachment)
    check a2.id == "att1"
    check a2.filename == "image.png"
    check a2.height == some(100)
    check a2.placeholder.isNone

suite "DiscordMessage":
  test "round-trip":
    let msg = DiscordMessage(
      id: "msg1",
      `type`: 0,
      content: "hello",
      channel_id: "ch1",
      author: Author(id: "user1", username: "alice"),
      attachments: @[],
      mentions: @[],
      mention_roles: @[],
      reactions: @[],
      pinned: false,
      mention_everyone: false,
      tts: false,
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: none(string),
      flags: 0,
      components: @[],
    )
    let j = toJson(msg)
    let msg2 = fromJson(j, DiscordMessage)
    check msg2.id == "msg1"
    check msg2.content == "hello"
    check msg2.`type` == 0
    check msg2.edited_timestamp.isNone

  test "parse Discord JSON snippet":
    let raw = """{"id":"999","type":0,"content":"test","channel_id":"ch2","author":{"id":"u2","username":"bob","avatar":"","discriminator":"0"},"attachments":[],"mentions":[],"mention_roles":[],"pinned":false,"mention_everyone":false,"tts":false,"timestamp":"2024-01-01T00:00:00.000Z","flags":0,"components":[]}"""
    let msg = fromJson(raw, DiscordMessage)
    check msg.id == "999"
    check msg.content == "test"
    check msg.author.username == "bob"

suite "GuildChannel":
  test "round-trip with name some":
    let ch = GuildChannel(id: "ch1", `type`: 0, name: some("general"))
    let j = toJson(ch)
    let ch2 = fromJson(j, GuildChannel)
    check ch2.id == "ch1"
    check ch2.`type` == 0
    check ch2.name == some("general")

  test "round-trip with name none":
    let ch = GuildChannel(id: "ch2", `type`: 2, name: none(string))
    let j = toJson(ch)
    let ch2 = fromJson(j, GuildChannel)
    check ch2.name.isNone

suite "InteractionUser":
  test "round-trip":
    let u = InteractionUser(id: "usr1")
    let j = toJson(u)
    let u2 = fromJson(j, InteractionUser)
    check u2.id == "usr1"

suite "InteractionMember":
  test "round-trip":
    let m = InteractionMember(user: InteractionUser(id: "usr2"))
    let j = toJson(m)
    let m2 = fromJson(j, InteractionMember)
    check m2.user.id == "usr2"

suite "InteractionCommandData":
  test "round-trip":
    let d = InteractionCommandData(
      name: "roll",
      options: @[InteractionCommandOption(name: "sides", `type`: 4, value: newJInt(6))],
    )
    let j = toJson(d)
    let d2 = fromJson(j, InteractionCommandData)
    check d2.name == "roll"
    check d2.options.len == 1
    check d2.options[0].name == "sides"

  test "parse Discord JSON snippet":
    let raw = """{"name":"ping","options":[{"name":"message","type":3,"value":"hello world"}]}"""
    let d = fromJson(raw, InteractionCommandData)
    check d.name == "ping"
    check d.options[0].value.getStr == "hello world"

suite "InteractionEvent":
  test "round-trip":
    let ie = InteractionEvent(
      id: "evt1",
      token: "tok1",
      channel_id: "ch1",
      guild_id: "g1",
      data: InteractionCommandData(name: "test", options: @[]),
      member: InteractionMember(user: InteractionUser(id: "u1")),
      user: nil,
    )
    let j = toJson(ie)
    let ie2 = fromJson(j, InteractionEvent)
    check ie2.id == "evt1"
    check ie2.data.name == "test"
    check ie2.member.user.id == "u1"

suite "DiscordInteraction":
  test "round-trip":
    let di = DiscordInteraction(
      id: "int1",
      token: "tok2",
      command_name: "ping",
      channel_id: "ch2",
      user_id: "u2",
      guild_id: "g2",
      options: @[],
    )
    let j = toJson(di)
    let di2 = fromJson(j, DiscordInteraction)
    check di2.id == "int1"
    check di2.command_name == "ping"
    check di2.user_id == "u2"

suite "SlashCommandOption":
  test "round-trip":
    let o = SlashCommandOption(
      name: "amount",
      description: "How many?",
      `type`: 4,
      required: true,
    )
    let j = toJson(o)
    let o2 = fromJson(j, SlashCommandOption)
    check o2.name == "amount"
    check o2.`type` == 4
    check o2.required == true

suite "SlashCommand":
  test "round-trip":
    let cmd = SlashCommand(
      name: "roll",
      description: "Roll dice",
      `type`: 1,
      options: @[SlashCommandOption(
        name: "sides",
        description: "Number of sides",
        `type`: 4,
        required: true,
      )],
    )
    let j = toJson(cmd)
    let cmd2 = fromJson(j, SlashCommand)
    check cmd2.name == "roll"
    check cmd2.options.len == 1
    check cmd2.options[0].name == "sides"

suite "GuildMember":
  test "round-trip with nick some":
    let m = GuildMember(
      user: Author(id: "u1", username: "alice"),
      nick: some("Alice"),
      roles: @["role1", "role2"],
      joined_at: "2024-01-01T00:00:00Z",
    )
    let j = toJson(m)
    let m2 = fromJson(j, GuildMember)
    check m2.user.id == "u1"
    check m2.user.username == "alice"
    check m2.nick == some("Alice")
    check m2.roles == @["role1", "role2"]
    check m2.joined_at == "2024-01-01T00:00:00Z"

  test "round-trip with nick none":
    let m = GuildMember(
      user: Author(id: "u2", username: "bob"),
      nick: none(string),
      roles: @[],
      joined_at: "2024-06-15T12:00:00Z",
    )
    let j = toJson(m)
    let m2 = fromJson(j, GuildMember)
    check m2.nick.isNone
    check m2.roles.len == 0

  test "parse Discord JSON snippet":
    let raw = """{"user":{"id":"123","username":"carol","avatar":"","discriminator":"0"},"nick":null,"roles":["abc"],"joined_at":"2023-03-10T08:00:00.000Z"}"""
    let m = fromJson(raw, GuildMember)
    check m.user.id == "123"
    check m.user.username == "carol"
    check m.nick.isNone
    check m.roles == @["abc"]

suite "PresenceData dumpHook":
  test "since none serializes as null":
    let pd = PresenceData(
      since: none(int),
      activities: @[PresenceActivity(name: "test", `type`: 0)],
      status: "online",
      afk: false,
    )
    let j = toJson(pd)
    check "\"since\":null" in j

  test "since some serializes as number":
    let pd = PresenceData(
      since: some(12345),
      activities: @[],
      status: "idle",
      afk: true,
    )
    let j = toJson(pd)
    check "\"since\":12345" in j
