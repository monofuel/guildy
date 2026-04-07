import
  std/[unittest, strutils],
  ../src/guildy

proc newTestClient(): GuildyClient =
  GuildyClient(token: "fake-token")

suite "GuildyError":
  test "has code and body fields":
    var e = (ref GuildyError)(msg: "test", code: 403, body: "{}")
    check e.code == 403
    check e.body == "{}"

  test "code and body default to zero/empty":
    var e = (ref GuildyError)(msg: "test")
    check e.code == 0
    check e.body == ""

  test "can be raised and caught with fields":
    try:
      var e = newException(GuildyError, "discord error: 403 Forbidden")
      e.code = 403
      e.body = "{\"message\": \"Missing Permissions\"}"
      raise e
    except GuildyError as caught:
      check caught.code == 403
      check caught.body == "{\"message\": \"Missing Permissions\"}"
      check "403" in caught.msg

suite "postChannelMessage":
  test "raises GuildyError when content exceeds 2000 characters":
    let client = newTestClient()
    let longContent = 'x'.repeat(2001)
    expect GuildyError:
      discard client.postChannelMessage("channel-id", longContent)
