import
  std/[unittest, json],
  jsony,
  ../src/guildy

suite "interaction options":
  test "InteractionCommandOption has name, type, and value fields":
    let opt = InteractionCommandOption(
      name: "amount",
      `type`: 4,
      value: newJInt(42)
    )
    check opt.name == "amount"
    check opt.`type` == 4
    check opt.value.getInt == 42

  test "InteractionCommandData deserializes options from JSON":
    let raw = """{"name":"roll","options":[{"name":"sides","type":4,"value":6}]}"""
    let data = fromJson(raw, InteractionCommandData)
    check data.name == "roll"
    check data.options.len == 1
    check data.options[0].name == "sides"
    check data.options[0].`type` == 4
    check data.options[0].value.getInt == 6

  test "InteractionCommandData with no options deserializes cleanly":
    let raw = """{"name":"ping"}"""
    let data = fromJson(raw, InteractionCommandData)
    check data.name == "ping"
    check data.options.len == 0

  test "DiscordInteraction carries options":
    var interaction = DiscordInteraction()
    interaction.options = @[
      InteractionCommandOption(name: "color", `type`: 3, value: newJString("red"))
    ]
    check interaction.options.len == 1
    check interaction.options[0].name == "color"
    check interaction.options[0].value.getStr == "red"

  test "InteractionCommandOption value handles string type":
    let raw = """{"name":"user","type":6,"value":"123456789"}"""
    let opt = fromJson(raw, InteractionCommandOption)
    check opt.name == "user"
    check opt.`type` == 6
    check opt.value.getStr == "123456789"
