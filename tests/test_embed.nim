import
  std/[unittest, strutils],
  jsony,
  ../src/guildy

suite "DiscordEmbed":
  test "serializes title and description":
    let embed = DiscordEmbed(title: "Hello", description: "World", color: 0xFF0000)
    let json = toJson(embed)
    check "Hello" in json
    check "World" in json
    check "16711680" in json

  test "serializes fields":
    let field = DiscordEmbedField(name: "Field Name", value: "Field Value", inline: true)
    let embed = DiscordEmbed(title: "t", fields: @[field])
    let json = toJson(embed)
    check "Field Name" in json
    check "Field Value" in json
    check "true" in json

  test "empty fields serialize as empty array":
    let embed = DiscordEmbed(title: "t")
    let json = toJson(embed)
    check "[]" in json

suite "postChannelMessageEmbed":
  test "raises GuildyError when content exceeds 2000 characters":
    let client = GuildyClient(token: "fake-token")
    let longContent = 'x'.repeat(2001)
    expect GuildyError:
      discard client.postChannelMessageEmbed("channel-id", longContent, @[])
