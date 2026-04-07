import
  std/[unittest, json],
  guildy/voice

suite "voice opcodes":
  test "VoiceSpeakingOp is 5":
    check VoiceSpeakingOp == 5

  test "setSpeaking payload for speaking=true":
    let speakingFlag = 1
    let ssrc: uint32 = 12345
    let payload = %*{
      "op": VoiceSpeakingOp,
      "d": {
        "speaking": speakingFlag,
        "delay": 0,
        "ssrc": ssrc
      }
    }
    check payload["op"].getInt == 5
    check payload["d"]["speaking"].getInt == 1
    check payload["d"]["delay"].getInt == 0
    check payload["d"]["ssrc"].getInt == 12345

  test "setSpeaking payload for speaking=false":
    let speakingFlag = 0
    let ssrc: uint32 = 12345
    let payload = %*{
      "op": VoiceSpeakingOp,
      "d": {
        "speaking": speakingFlag,
        "delay": 0,
        "ssrc": ssrc
      }
    }
    check payload["op"].getInt == 5
    check payload["d"]["speaking"].getInt == 0
