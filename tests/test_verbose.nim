import
  std/unittest,
  ../src/guildy

suite "GuildyClient verbose":
  test "newGuildyClient sets verbose to true by default":
    let c = newGuildyClient("fake-token")
    check c.verbose == true

  test "verbose field can be set to false":
    let c = newGuildyClient("fake-token")
    c.verbose = false
    check c.verbose == false
