import
  std/[unittest, options],
  jsony,
  guildy

suite "mentions deserialization":
  const
    AuthorJson = """{"id":"a1","username":"bot","avatar":"","discriminator":"0000","public_flags":0,"flags":0,"bot":false}"""

  test "populated mentions":
    let json = """{"id":"1","type":0,"content":"hi","channel_id":"c1","author":""" & AuthorJson & ""","attachments":[],"mentions":[{"id":"u1","username":"alice","avatar":"img","discriminator":"1234","public_flags":0,"flags":0,"bot":false}],"mention_roles":[],"reactions":[],"pinned":false,"mention_everyone":false,"tts":false,"timestamp":"2024-01-01","flags":0,"components":[]}"""
    let msg = json.fromJson(DiscordMessage)
    check msg.mentions.len == 1
    check msg.mentions[0].id == "u1"
    check msg.mentions[0].username == "alice"

  test "mentions with missing optional fields":
    let json = """{"id":"1","type":0,"content":"hi","channel_id":"c1","author":""" & AuthorJson & ""","attachments":[],"mentions":[{"id":"u2","username":"bob","avatar":"","discriminator":"0001","public_flags":0,"flags":0,"bot":false}],"mention_roles":[],"reactions":[],"pinned":false,"mention_everyone":false,"tts":false,"timestamp":"2024-01-01","flags":0,"components":[]}"""
    let msg = json.fromJson(DiscordMessage)
    check msg.mentions.len == 1
    check msg.mentions[0].global_name.isNone
    check msg.mentions[0].banner.isNone

  test "empty mentions":
    let json = """{"id":"1","type":0,"content":"hi","channel_id":"c1","author":""" & AuthorJson & ""","attachments":[],"mentions":[],"mention_roles":[],"reactions":[],"pinned":false,"mention_everyone":false,"tts":false,"timestamp":"2024-01-01","flags":0,"components":[]}"""
    let msg = json.fromJson(DiscordMessage)
    check msg.mentions.len == 0
