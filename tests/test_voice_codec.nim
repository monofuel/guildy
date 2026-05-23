## Runtime sanity tests for the libsodium and libopus FFI bindings.
## Run with: nix develop -c nim r -d:guildyVoice tests/test_voice_codec.nim

import std/unittest

when not defined(guildyVoice):
  static:
    error "this test must be built with -d:guildyVoice"

import guildy/[sodium, opus, audio, voice, voiceio]

suite "sodium AEAD round trips":
  test "AES-256-GCM encrypt then decrypt":
    if not aesGcmAvailable():
      skip()
    else:
      var key: array[AesGcmKeyBytes, uint8]
      var nonce: array[AesGcmNonceBytes, uint8]
      for i in 0 ..< key.len: key[i] = uint8(i)
      for i in 0 ..< nonce.len: nonce[i] = uint8(0xA0 + i)
      let aad = @[uint8(1), 2, 3, 4, 5]
      let plain = @[uint8('h'), uint8('e'), uint8('l'), uint8('l'), uint8('o')]
      let ct = aesGcmEncrypt(key, nonce, aad, plain)
      check ct.len == plain.len + AesGcmTagBytes
      let pt = aesGcmDecrypt(key, nonce, aad, ct)
      check pt == plain

  test "XChaCha20-Poly1305 encrypt then decrypt":
    var key: array[XChaChaKeyBytes, uint8]
    var nonce: array[XChaChaNonceBytes, uint8]
    for i in 0 ..< key.len: key[i] = uint8(0xC0 + i)
    for i in 0 ..< nonce.len: nonce[i] = uint8(0xB0 + i)
    let aad = @[uint8(9), 9, 9]
    let plain = @[uint8('w'), uint8('o'), uint8('r'), uint8('l'), uint8('d')]
    let ct = xchachaEncrypt(key, nonce, aad, plain)
    check ct.len == plain.len + XChaChaTagBytes
    let pt = xchachaDecrypt(key, nonce, aad, ct)
    check pt == plain

  test "XChaCha20 tampered tag fails":
    var key: array[XChaChaKeyBytes, uint8]
    var nonce: array[XChaChaNonceBytes, uint8]
    var ct = xchachaEncrypt(key, nonce, @[], @[uint8(1), 2, 3])
    ct[^1] = ct[^1] xor 0x01
    var raised = false
    try:
      discard xchachaDecrypt(key, nonce, @[], ct)
    except OSError:
      raised = true
    check raised

suite "opus codec round trip":
  test "encode then decode silence at 48kHz stereo":
    let enc = newOpusEncoder()
    defer: enc.destroy()
    let dec = newOpusDecoder()
    defer: dec.destroy()
    var pcm = newSeq[int16](OpusFrameSize * OpusChannels)
    let packet = enc.encode(pcm)
    check packet.len > 0
    let recovered = dec.decode(packet)
    check recovered.len == OpusFrameSize * OpusChannels

suite "audio resampling":
  test "48k stereo down to 24k mono and back keeps the frame size":
    var stereo48 = newSeq[int16](OpusFrameSize * OpusChannels)
    let mono24 = discord48kStereoTo24kMono(stereo48)
    check mono24.len == OpusFrameSize div 2
    let stereo48Back = openai24kMonoTo48kStereo(mono24)
    check stereo48Back.len == stereo48.len

  test "stereoToMono averages left and right":
    let stereo = @[int16(100), int16(-100), int16(1000), int16(-1000)]
    let mono = stereoToMono(stereo)
    check mono == @[int16(0), int16(0)]

proc makeFakeVoiceConnection(mode: string): VoiceConnection =
  result = VoiceConnection(
    secretKey: newSeq[uint8](32),
    ssrc: 0x12345678'u32,
    modes: @[mode],
    rtpSequence: 1,
    rtpTimestamp: 1000,
  )
  for i in 0 ..< 32:
    result.secretKey[i] = uint8(i + 1)

suite "RTP packet end-to-end":
  test "XChaCha20 packet build + decode round trip":
    let vc = makeFakeVoiceConnection("aead_xchacha20_poly1305_rtpsize")
    let vio = newVoiceIo(vc)
    defer: vio.destroy()

    var pcm = newSeq[int16](OpusFrameSize * OpusChannels)
    for i in 0 ..< pcm.len:
      pcm[i] = int16((i * 113) mod 16384)
    let packet = vio.buildAudioPacket(pcm)
    let frame = vio.decodePacket(packet)
    check frame != nil
    check frame.ssrc == 0x12345678'u32
    check frame.pcm.len == OpusFrameSize * OpusChannels

  test "AES-256-GCM packet round trip (if supported)":
    if not aesGcmAvailable():
      skip()
    else:
      let vc = makeFakeVoiceConnection("aead_aes256_gcm_rtpsize")
      let vio = newVoiceIo(vc)
      defer: vio.destroy()
      check vio.mode == EmAes256Gcm

      var pcm = newSeq[int16](OpusFrameSize * OpusChannels)
      for i in 0 ..< pcm.len:
        pcm[i] = int16((i * 71) mod 16384)
      let packet = vio.buildAudioPacket(pcm)
      let frame = vio.decodePacket(packet)
      check frame != nil
      check frame.ssrc == 0x12345678'u32
      check frame.pcm.len == OpusFrameSize * OpusChannels

  test "tampering with ciphertext fails authentication":
    let vc = makeFakeVoiceConnection("aead_xchacha20_poly1305_rtpsize")
    let vio = newVoiceIo(vc)
    defer: vio.destroy()
    var pcm = newSeq[int16](OpusFrameSize * OpusChannels)
    var packet = vio.buildAudioPacket(pcm)
    packet[20] = packet[20] xor 0xFF
    var raised = false
    try:
      discard vio.decodePacket(packet)
    except OSError:
      raised = true
    check raised
