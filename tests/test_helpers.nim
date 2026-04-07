import
  std/[unittest, random]

include guildy

let testClient = GuildyClient(
  apiBase: parseUri("https://discord.com/api/v10"),
  appId: "app123"
)

suite "Intent flags":
  test "each intent is a distinct power of two":
    let intents = [
      IntentGuilds, IntentGuildMembers, IntentGuildModeration,
      IntentGuildEmojisAndStickers, IntentGuildIntegrations, IntentGuildWebhooks,
      IntentGuildInvites, IntentGuildVoiceStates, IntentGuildPresences,
      IntentGuildMessages, IntentGuildMessageReactions, IntentGuildMessageTyping,
      IntentDirectMessages, IntentDirectMessageReactions, IntentDirectMessageTyping,
      IntentMessageContent,
    ]
    for i in 0 ..< intents.len:
      check (intents[i] and (intents[i] - 1)) == 0
      for j in i + 1 ..< intents.len:
        check (intents[i] and intents[j]) == 0

  test "DefaultIntents equals expected combination":
    let expected =
      IntentGuildVoiceStates or IntentGuildMessages or
      IntentGuildMessageReactions or IntentDirectMessages or
      IntentDirectMessageReactions or IntentMessageContent
    check DefaultIntents == expected

  test "combining intents with or produces expected bitmask":
    check (IntentGuilds or IntentGuildMessages) == ((1 shl 0) or (1 shl 9))

suite "URI construction":
  test "guildChannelsUri returns expected path":
    check $guildChannelsUri(testClient, "123") ==
      "https://discord.com/api/v10/guilds/123/channels"

  test "channelMessagesUri with limit only":
    check $channelMessagesUri(testClient, "456", 50) ==
      "https://discord.com/api/v10/channels/456/messages?limit=50"

  test "channelMessagesUri with limit and before":
    check $channelMessagesUri(testClient, "456", 50, "before_id") ==
      "https://discord.com/api/v10/channels/456/messages?limit=50&before=before_id"

  test "channelMessagesUri raises GuildyError when limit <= 0":
    expect GuildyError:
      discard channelMessagesUri(testClient, "456", 0)

  test "applicationCommandsUri global returns expected path":
    check $applicationCommandsUri(testClient, "") ==
      "https://discord.com/api/v10/applications/app123/commands"

  test "applicationCommandsUri with guildId returns expected path":
    check $applicationCommandsUri(testClient, "guild789") ==
      "https://discord.com/api/v10/applications/app123/guilds/guild789/commands"

  test "interactionCallbackUri constructs correct path":
    check $interactionCallbackUri(testClient, "int1", "tok1") ==
      "https://discord.com/api/v10/interactions/int1/tok1/callback"

suite "Heartbeat jitter":
  test "interval stays within expected bounds over 1000 iterations":
    const
      IntervalMs = 41250.0
      Jitter = 0.1
      MinInterval = IntervalMs.int
      MaxInterval = (IntervalMs + IntervalMs * Jitter).int
    randomize(42)
    for _ in 1 .. 1000:
      let actualInterval = (IntervalMs + rand(IntervalMs * Jitter)).int
      check actualInterval >= MinInterval
      check actualInterval <= MaxInterval
