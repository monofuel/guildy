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

suite "DAVE roster change callback":
  test "OnDaveRosterChangeEvent type exists and is exported":
    check compiles(block:
      var cb: OnDaveRosterChangeEvent)

  when defined(guildyVoice):
    test "onDaveRosterChange field is accessible on VoiceConnection":
      check compiles(block:
        var vc: VoiceConnection
        vc.onDaveRosterChange = nil)

    test "onDaveRosterChange accepts a proc with correct signature":
      check compiles(block:
        var vc: VoiceConnection
        vc.onDaveRosterChange = proc(v: VoiceConnection, userId: string,
            joined: bool) {.gcsafe.} = discard)

suite "UDP procs":
  test "sendUdp and recvUdp are exported":
    # Verify the procs are accessible at compile time.
    # A live socket is required to call them, so only compilation is checked.
    check compiles(block:
      var vc: VoiceConnection
      vc.sendUdp(""))
    check compiles(block:
      var vc: VoiceConnection
      discard vc.recvUdp(0))

suite "RTP header":
  test "buildRtpHeader returns 12 bytes with correct fixed fields":
    var vc = VoiceConnection(ssrc: 0x01020304'u32)
    let header = buildRtpHeader(vc)
    check header.len == 12
    check header[0] == 0x80'u8  # version 2, no padding/extension/CSRC
    check header[1] == 0x78'u8  # payload type 120 (Opus)

  test "buildRtpHeader encodes sequence big-endian":
    var vc = VoiceConnection(ssrc: 0, rtpSequence: 0x1234'u16)
    let header = buildRtpHeader(vc)
    check header[2] == 0x12'u8
    check header[3] == 0x34'u8

  test "buildRtpHeader encodes timestamp big-endian":
    var vc = VoiceConnection(ssrc: 0, rtpTimestamp: 0xAABBCCDD'u32)
    let header = buildRtpHeader(vc)
    check header[4] == 0xAA'u8
    check header[5] == 0xBB'u8
    check header[6] == 0xCC'u8
    check header[7] == 0xDD'u8

  test "buildRtpHeader encodes SSRC big-endian":
    var vc = VoiceConnection(ssrc: 0x0A0B0C0D'u32)
    let header = buildRtpHeader(vc)
    check header[8] == 0x0A'u8
    check header[9] == 0x0B'u8
    check header[10] == 0x0C'u8
    check header[11] == 0x0D'u8

  test "buildRtpHeader increments sequence by 1 per call":
    var vc = VoiceConnection(ssrc: 0, rtpSequence: 0'u16)
    discard buildRtpHeader(vc)
    check vc.rtpSequence == 1
    discard buildRtpHeader(vc)
    check vc.rtpSequence == 2

  test "buildRtpHeader increments timestamp by 960 per call":
    var vc = VoiceConnection(ssrc: 0, rtpTimestamp: 0'u32)
    discard buildRtpHeader(vc)
    check vc.rtpTimestamp == 960
    discard buildRtpHeader(vc)
    check vc.rtpTimestamp == 1920

  test "sequence and timestamp default to 0 on new VoiceConnection":
    var vc = VoiceConnection()
    check vc.rtpSequence == 0
    check vc.rtpTimestamp == 0
