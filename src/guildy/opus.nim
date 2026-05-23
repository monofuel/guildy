## Minimal libopus FFI for Discord voice (48kHz stereo, 20ms frames).
## Gated behind -d:guildyVoice so the rest of guildy doesn't pull in libopus.

when defined(guildyVoice):
  const opusLib = "libopus.so.0"

  # Constants from opus.h / opus_defines.h.
  const
    OpusOk* = 0
    OpusApplicationVoip* = 2048
    OpusApplicationAudio* = 2049
    OpusApplicationLowdelay* = 2051

    OpusSetBitrateRequest* = 4002
    OpusSetInbandFecRequest* = 4012
    OpusSetPacketLossPercRequest* = 4014
    OpusSetDtxRequest* = 4016
    OpusResetStateRequest* = 4028

    # Discord voice: 48kHz stereo, 20ms frames.
    OpusSampleRate* = 48000
    OpusChannels* = 2
    OpusFrameSize* = 960   # samples per channel for 20ms at 48kHz
    OpusMaxPacketBytes* = 4000

  # ---------------------------------------------------------------------------
  # Raw bindings
  # ---------------------------------------------------------------------------

  type
    OpusEncoderPtr* = pointer
    OpusDecoderPtr* = pointer

  proc opusEncoderCreate(fs: int32, channels: cint, application: cint,
      error: ptr cint): OpusEncoderPtr {.dynlib: opusLib, cdecl,
      importc: "opus_encoder_create".}

  proc opusEncoderDestroy(st: OpusEncoderPtr) {.dynlib: opusLib, cdecl,
      importc: "opus_encoder_destroy".}

  proc opusEncode(st: OpusEncoderPtr, pcm: ptr int16, frameSize: cint,
      data: ptr uint8, maxDataBytes: int32): cint {.dynlib: opusLib, cdecl,
      importc: "opus_encode".}

  proc opusEncoderCtlSet(st: OpusEncoderPtr, request: cint,
      value: cint): cint {.dynlib: opusLib, cdecl, varargs,
      importc: "opus_encoder_ctl".}

  proc opusDecoderCreate(fs: int32, channels: cint,
      error: ptr cint): OpusDecoderPtr {.dynlib: opusLib, cdecl,
      importc: "opus_decoder_create".}

  proc opusDecoderDestroy(st: OpusDecoderPtr) {.dynlib: opusLib, cdecl,
      importc: "opus_decoder_destroy".}

  proc opusDecode(st: OpusDecoderPtr, data: ptr uint8, len: int32,
      pcm: ptr int16, frameSize: cint,
      decodeFec: cint): cint {.dynlib: opusLib, cdecl,
      importc: "opus_decode".}

  proc opusStrError(error: cint): cstring {.dynlib: opusLib, cdecl,
      importc: "opus_strerror".}

  # ---------------------------------------------------------------------------
  # Higher-level wrappers
  # ---------------------------------------------------------------------------

  type
    OpusEncoder* = ref object
      handle*: OpusEncoderPtr
      channels*: int
      sampleRate*: int

    OpusDecoder* = ref object
      handle*: OpusDecoderPtr
      channels*: int
      sampleRate*: int

  proc newOpusEncoder*(sampleRate: int = OpusSampleRate,
      channels: int = OpusChannels,
      application: cint = OpusApplicationAudio.cint,
      bitrate: int = 96000): OpusEncoder =
    ## Create an Opus encoder configured for Discord voice by default.
    var err: cint = 0
    let h = opusEncoderCreate(int32(sampleRate), cint(channels), application,
        addr err)
    if err != 0 or h == nil:
      raise newException(OSError,
          "opus_encoder_create failed: " & $opusStrError(err))
    let rc = opusEncoderCtlSet(h, cint(OpusSetBitrateRequest), cint(bitrate))
    if rc != 0:
      opusEncoderDestroy(h)
      raise newException(OSError,
          "opus_encoder_ctl(SET_BITRATE) failed: " & $opusStrError(rc))
    result = OpusEncoder(handle: h, channels: channels, sampleRate: sampleRate)

  proc destroy*(enc: OpusEncoder) =
    ## Free the underlying encoder.
    if enc.handle != nil:
      opusEncoderDestroy(enc.handle)
      enc.handle = nil

  proc encode*(enc: OpusEncoder, pcm: openArray[int16],
      frameSize: int = OpusFrameSize): seq[uint8] =
    ## Encode one frame of interleaved PCM16 to Opus.
    ## `pcm.len` must equal frameSize * channels.
    let expected = frameSize * enc.channels
    if pcm.len != expected:
      raise newException(ValueError, "expected " & $expected &
          " samples, got " & $pcm.len)
    var buf = newSeq[uint8](OpusMaxPacketBytes)
    let n = opusEncode(enc.handle, cast[ptr int16](unsafeAddr pcm[0]),
        cint(frameSize), addr buf[0], int32(buf.len))
    if n < 0:
      raise newException(OSError, "opus_encode failed: " & $opusStrError(n))
    buf.setLen(int(n))
    result = buf

  proc newOpusDecoder*(sampleRate: int = OpusSampleRate,
      channels: int = OpusChannels): OpusDecoder =
    ## Create an Opus decoder configured for Discord voice by default.
    var err: cint = 0
    let h = opusDecoderCreate(int32(sampleRate), cint(channels), addr err)
    if err != 0 or h == nil:
      raise newException(OSError,
          "opus_decoder_create failed: " & $opusStrError(err))
    result = OpusDecoder(handle: h, channels: channels, sampleRate: sampleRate)

  proc destroy*(dec: OpusDecoder) =
    ## Free the underlying decoder.
    if dec.handle != nil:
      opusDecoderDestroy(dec.handle)
      dec.handle = nil

  proc decode*(dec: OpusDecoder, opusFrame: openArray[uint8],
      frameSize: int = OpusFrameSize): seq[int16] =
    ## Decode one Opus frame to interleaved PCM16.
    ## Returns frameSize * channels samples.
    var pcm = newSeq[int16](frameSize * dec.channels)
    let dataPtr = if opusFrame.len > 0:
        cast[ptr uint8](unsafeAddr opusFrame[0])
      else:
        nil
    let n = opusDecode(dec.handle, dataPtr, int32(opusFrame.len),
        addr pcm[0], cint(frameSize), 0)
    if n < 0:
      raise newException(OSError, "opus_decode failed: " & $opusStrError(n))
    pcm.setLen(int(n) * dec.channels)
    result = pcm
