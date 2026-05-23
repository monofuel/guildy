## High-level Discord voice audio I/O: encrypt/encode on send, decrypt/decode
## on recv. Combines voice.nim's RTP scaffolding with opus + libsodium + DAVE.

when defined(guildyVoice):
  import std/[net, tables, locks]
  import guildy/[voice, opus, sodium, dave]

  type
    EncryptionMode* = enum
      EmAes256Gcm
      EmXChaCha20Poly1305

    VoiceIo* = ref object
      ## Audio pump bound to a single VoiceConnection.
      vc*: VoiceConnection
      mode*: EncryptionMode
      encoder*: OpusEncoder
      decoders*: Table[uint32, OpusDecoder]
      sendNonce*: uint32
      daveEncryptor*: DAVEEncryptorHandle
      daveEncryptorIsPassthrough*: bool
      daveDecryptors*: Table[uint32, DAVEDecryptorHandle]

    DecodedFrame* = ref object
      ## A single received and decoded audio frame.
      ssrc*: uint32
      sequence*: uint16
      timestamp*: uint32
      pcm*: seq[int16] # interleaved 48kHz stereo PCM16
      isSilence*: bool # true for Opus DTX silence / DAVE-skipped silence frames

  proc selectEncryptionMode*(vc: VoiceConnection): EncryptionMode =
    ## Match whatever mode voice.nim told Discord to use via select_protocol.
    ## Falls back to a sensible default if the field hasn't been set yet
    ## (e.g. in unit tests that construct a VoiceConnection by hand).
    let m = if vc.selectedMode.len > 0: vc.selectedMode
            elif vc.modes.len > 0: vc.modes[0]
            else: ""
    case m
    of "aead_aes256_gcm_rtpsize":
      if not aesGcmAvailable():
        raise newException(OSError,
            "voice WS selected AES-256-GCM but the CPU lacks AES-NI support")
      EmAes256Gcm
    of "aead_xchacha20_poly1305_rtpsize":
      EmXChaCha20Poly1305
    else:
      raise newException(ValueError,
          "unsupported voice encryption mode: " & m)

  proc daveActive(vc: VoiceConnection): bool =
    vc.daveSession != nil and vc.daveProtocolVersion > 0

  proc encryptorPassthrough*(vio: VoiceIo): bool =
    ## Returns true if the send encryptor is currently in passthrough mode
    ## (i.e. our outbound frames are NOT being DAVE-encrypted). The peer's
    ## decryptor will reject these frames once its own MLS state matures.
    vio.daveEncryptorIsPassthrough

  proc setupSendEncryptor*(vio: VoiceIo) =
    ## (Re)build the DAVE encryptor. Tries to acquire our own key ratchet from
    ## the MLS session; if that fails (DAVE handshake not done yet), falls
    ## back to passthrough mode. Safe to call multiple times — it'll upgrade
    ## from passthrough to keyed once the ratchet becomes available.
    if vio.daveEncryptor == nil:
      vio.daveEncryptor = daveEncryptorCreate()
      daveEncryptorAssignSsrcToCodec(vio.daveEncryptor, vio.vc.ssrc, CodecOpus)
    if not daveActive(vio.vc):
      daveEncryptorSetPassthroughMode(vio.daveEncryptor, true)
      vio.daveEncryptorIsPassthrough = true
      return
    let ratchet = daveSessionGetKeyRatchet(
        vio.vc.daveSession, cstring(vio.vc.state.userId))
    if ratchet == nil:
      daveEncryptorSetPassthroughMode(vio.daveEncryptor, true)
      vio.daveEncryptorIsPassthrough = true
    else:
      daveEncryptorSetPassthroughMode(vio.daveEncryptor, false)
      daveEncryptorSetKeyRatchet(vio.daveEncryptor, ratchet)
      vio.daveEncryptorIsPassthrough = false

  proc newVoiceIo*(vc: VoiceConnection, bitrate: int = 96000): VoiceIo =
    ## Initialize audio codecs and pick an encryption mode.
    ## Must be called after VoiceSessionDescription (secretKey populated).
    if vc.secretKey.len != 32:
      raise newException(ValueError,
          "secretKey not yet received (expected 32 bytes, got " &
          $vc.secretKey.len & ")")
    result = VoiceIo(
      vc: vc,
      mode: selectEncryptionMode(vc),
      encoder: newOpusEncoder(bitrate = bitrate),
      decoders: initTable[uint32, OpusDecoder](),
      sendNonce: 0,
      daveDecryptors: initTable[uint32, DAVEDecryptorHandle](),
    )
    setupSendEncryptor(result)

  proc destroy*(vio: VoiceIo) =
    ## Release codec resources.
    if vio.encoder != nil:
      vio.encoder.destroy()
      vio.encoder = nil
    for _, dec in vio.decoders.mpairs:
      if dec != nil:
        dec.destroy()
    vio.decoders.clear()
    if vio.daveEncryptor != nil:
      daveEncryptorDestroy(vio.daveEncryptor)
      vio.daveEncryptor = nil
    for _, dec in vio.daveDecryptors.mpairs:
      if dec != nil:
        daveDecryptorDestroy(dec)
    vio.daveDecryptors.clear()

  proc ensureDaveDecryptor(vio: VoiceIo, ssrc: uint32): DAVEDecryptorHandle =
    ## Lazily provision a DAVE decryptor for the speaker on this SSRC.
    ## Returns nil if we don't yet know which user owns the SSRC, in which
    ## case the caller should drop the packet and try again later.
    if vio.daveDecryptors.hasKey(ssrc):
      return vio.daveDecryptors[ssrc]
    let dec = daveDecryptorCreate()
    if not daveActive(vio.vc):
      daveDecryptorTransitionToPassthroughMode(dec, true)
      vio.daveDecryptors[ssrc] = dec
      return dec
    var userId = ""
    withLock vio.vc.ssrcLock:
      if vio.vc.ssrcToUserId.hasKey(ssrc):
        userId = vio.vc.ssrcToUserId[ssrc]
    if userId == "":
      daveDecryptorDestroy(dec)
      return nil
    let ratchet = daveSessionGetKeyRatchet(vio.vc.daveSession, cstring(userId))
    if ratchet == nil:
      daveDecryptorDestroy(dec)
      return nil
    daveDecryptorTransitionToKeyRatchet(dec, ratchet)
    vio.daveDecryptors[ssrc] = dec
    result = dec

  proc encodeNonceCounter(counter: uint32, nonceLen: int): seq[uint8] =
    ## Build a libsodium nonce: 4-byte big-endian counter at the front,
    ## zero-padded to nonceLen bytes.
    result = newSeq[uint8](nonceLen)
    result[0] = uint8((counter shr 24) and 0xFF'u32)
    result[1] = uint8((counter shr 16) and 0xFF'u32)
    result[2] = uint8((counter shr 8) and 0xFF'u32)
    result[3] = uint8(counter and 0xFF'u32)

  proc daveWrapOpus(vio: VoiceIo, opusFrame: seq[uint8]): seq[uint8] =
    ## Apply DAVE encryption (or passthrough) to an Opus frame on send.
    if vio.daveEncryptor == nil:
      return opusFrame
    # If we ended up in passthrough mode because DAVE wasn't ready when the
    # encryptor was created, try to upgrade to keyed mode on the fly. Otherwise
    # the peer's DAVE decryptor will reject our frames once its MLS state is
    # established (it has passthrough disabled by default).
    if vio.daveEncryptorIsPassthrough and daveActive(vio.vc):
      let ratchet = daveSessionGetKeyRatchet(
          vio.vc.daveSession, cstring(vio.vc.state.userId))
      if ratchet != nil:
        daveEncryptorSetPassthroughMode(vio.daveEncryptor, false)
        daveEncryptorSetKeyRatchet(vio.daveEncryptor, ratchet)
        vio.daveEncryptorIsPassthrough = false
    let maxOut = daveEncryptorGetMaxCiphertextByteSize(
        vio.daveEncryptor, MediaAudio, csize_t(opusFrame.len))
    var buf = newSeq[uint8](max(int(maxOut), opusFrame.len + 64))
    var written: csize_t = 0
    let rc = daveEncryptorEncrypt(vio.daveEncryptor, MediaAudio, vio.vc.ssrc,
        unsafeAddr opusFrame[0], csize_t(opusFrame.len),
        addr buf[0], csize_t(buf.len), addr written)
    if rc != EncryptSuccess:
      raise newException(OSError, "DAVE encrypt failed: " & $rc)
    buf.setLen(int(written))
    result = buf

  proc daveUnwrapOpus(vio: VoiceIo, ssrc: uint32,
      payload: seq[uint8]): seq[uint8] =
    ## Apply DAVE decryption (or passthrough) to a recovered RTP payload.
    ## Raises KeyError if the DAVE decryptor for this SSRC isn't ready yet.
    let dec = vio.ensureDaveDecryptor(ssrc)
    if dec == nil:
      raise newException(KeyError,
          "DAVE decryptor not ready for SSRC " & $ssrc)
    let maxOut = daveDecryptorGetMaxPlaintextByteSize(
        dec, MediaAudio, csize_t(payload.len))
    var buf = newSeq[uint8](max(int(maxOut), payload.len + 64))
    var written: csize_t = 0
    let rc = daveDecryptorDecrypt(dec, MediaAudio,
        unsafeAddr payload[0], csize_t(payload.len),
        addr buf[0], csize_t(buf.len), addr written)
    if rc != DecryptSuccess:
      raise newException(OSError, "DAVE decrypt failed: " & $rc)
    buf.setLen(int(written))
    result = buf

  proc buildAudioPacket*(vio: VoiceIo, pcm: openArray[int16]): seq[uint8] =
    ## Encode one 20ms PCM frame and wrap it as an encrypted RTP packet.
    ## Pipeline: opus_encode -> DAVE encrypt -> outer AEAD -> append nonce.
    ## Advances the RTP sequence + timestamp on the underlying VoiceConnection
    ## and the local nonce counter.
    if pcm.len != OpusFrameSize * OpusChannels:
      raise newException(ValueError, "expected " &
          $(OpusFrameSize * OpusChannels) & " samples, got " & $pcm.len)
    let header = vio.vc.buildRtpHeader()
    let opusRaw = vio.encoder.encode(pcm)
    let payload = vio.daveWrapOpus(opusRaw)
    inc vio.sendNonce
    let counter = vio.sendNonce
    let aad = @header
    var ciphertext: seq[uint8]
    case vio.mode
    of EmAes256Gcm:
      let nonce = encodeNonceCounter(counter, AesGcmNonceBytes)
      ciphertext = aesGcmEncrypt(vio.vc.secretKey, nonce, aad, payload)
    of EmXChaCha20Poly1305:
      let nonce = encodeNonceCounter(counter, XChaChaNonceBytes)
      ciphertext = xchachaEncrypt(vio.vc.secretKey, nonce, aad, payload)

    result = newSeq[uint8](12 + ciphertext.len + 4)
    for i in 0 ..< 12:
      result[i] = header[i]
    for i in 0 ..< ciphertext.len:
      result[12 + i] = ciphertext[i]
    let p = 12 + ciphertext.len
    result[p] = uint8((counter shr 24) and 0xFF'u32)
    result[p+1] = uint8((counter shr 16) and 0xFF'u32)
    result[p+2] = uint8((counter shr 8) and 0xFF'u32)
    result[p+3] = uint8(counter and 0xFF'u32)

  proc sendPcm48kStereo*(vio: VoiceIo, pcm: openArray[int16]) =
    ## Encode one 20ms frame of 48kHz stereo PCM16 and send as an
    ## encrypted RTP packet.
    let packet = vio.buildAudioPacket(pcm)
    var asStr = newString(packet.len)
    for i in 0 ..< packet.len:
      asStr[i] = char(packet[i])
    vio.vc.sendUdp(asStr)

  proc getDecoder(vio: VoiceIo, ssrc: uint32): OpusDecoder =
    if not vio.decoders.hasKey(ssrc):
      vio.decoders[ssrc] = newOpusDecoder()
    result = vio.decoders[ssrc]

  proc rtpDecryptBoundaries(packet: openArray[uint8]):
      tuple[aadEnd, extDataLen: int] =
    ## Return (aadEnd, extDataLen):
    ##   aadEnd:     where AAD ends and ciphertext begins
    ##   extDataLen: bytes of (decrypted) extension data the plaintext starts
    ##               with — to skip past before reaching the Opus payload
    ##
    ## Discord's "_rtpsize" modes do NOT follow SRTP for X=1 packets: the
    ## extension preamble (profile + length, 4 bytes) is left unencrypted and
    ## is part of AAD, but the extension DATA itself is encrypted along with
    ## the Opus payload. Confirmed against songbird/serenity reference impl.
    if packet.len < 12:
      raise newException(ValueError, "RTP packet too short")
    let cc = int(packet[0] and 0x0F'u8)
    let xBit = (packet[0] and 0x10'u8) != 0'u8
    let fixedHeader = 12 + cc * 4
    if not xBit:
      return (fixedHeader, 0)
    if fixedHeader + 4 > packet.len:
      raise newException(ValueError, "RTP extension preamble truncated")
    let extDataWords = (int(packet[fixedHeader + 2]) shl 8) or
        int(packet[fixedHeader + 3])
    result = (fixedHeader + 4, extDataWords * 4)

  proc aeadDecryptPayload(vio: VoiceIo,
      packet: openArray[uint8]): tuple[plain: seq[uint8], extDataLen: int] =
    ## Strip the appended nonce counter and decrypt the outer AEAD layer.
    ## Returns the decrypted plaintext and the count of leading bytes that
    ## are decrypted extension data (which the caller must skip before
    ## passing the rest to the inner Opus/DAVE layer).
    let (aadEnd, extDataLen) = rtpDecryptBoundaries(packet)
    if packet.len < aadEnd + 4 + 16:
      raise newException(ValueError, "encrypted RTP packet too short")
    let counterStart = packet.len - 4
    let counter =
      (uint32(packet[counterStart]) shl 24) or
      (uint32(packet[counterStart + 1]) shl 16) or
      (uint32(packet[counterStart + 2]) shl 8) or
      uint32(packet[counterStart + 3])
    let aad = @(packet[0 ..< aadEnd])
    let ctSlice = @(packet[aadEnd ..< counterStart])
    var plain: seq[uint8]
    case vio.mode
    of EmAes256Gcm:
      let nonce = encodeNonceCounter(counter, AesGcmNonceBytes)
      plain = aesGcmDecrypt(vio.vc.secretKey, nonce, aad, ctSlice)
    of EmXChaCha20Poly1305:
      let nonce = encodeNonceCounter(counter, XChaChaNonceBytes)
      plain = xchachaDecrypt(vio.vc.secretKey, nonce, aad, ctSlice)
    result = (plain, extDataLen)

  proc decodePacket*(vio: VoiceIo, packet: openArray[uint8]): DecodedFrame =
    ## Decode an inbound encrypted RTP packet to a DecodedFrame.
    ## Returns nil if the payload type does not match Opus (120) or the DAVE
    ## decryptor for this SSRC isn't ready yet.
    if packet.len < 12:
      return nil
    let payloadType = int(packet[1] and 0x7F'u8)
    if payloadType != 0x78:
      return nil
    let sequence = (uint16(packet[2]) shl 8) or uint16(packet[3])
    let timestamp =
      (uint32(packet[4]) shl 24) or
      (uint32(packet[5]) shl 16) or
      (uint32(packet[6]) shl 8) or
      uint32(packet[7])
    let ssrc =
      (uint32(packet[8]) shl 24) or
      (uint32(packet[9]) shl 16) or
      (uint32(packet[10]) shl 8) or
      uint32(packet[11])
    let (outerPlain, extDataLen) = vio.aeadDecryptPayload(packet)
    if extDataLen > outerPlain.len:
      raise newException(ValueError,
          "extension data length exceeds decrypted plaintext")
    let opusEncrypted = if extDataLen == 0: outerPlain
        else: outerPlain[extDataLen ..< outerPlain.len]
    var opusFrame: seq[uint8]
    try:
      opusFrame = vio.daveUnwrapOpus(ssrc, opusEncrypted)
    except KeyError:
      return nil
    # Opus DTX silence frames are <= 3 bytes. libdave passes them through
    # unmodified ("Decrypt skipping silence of size: 3"). Track so the bridge
    # can drop them instead of forwarding comfort noise to OpenAI.
    let isSilence = opusFrame.len <= 3
    let dec = vio.getDecoder(ssrc)
    let pcm = dec.decode(opusFrame)
    result = DecodedFrame(
      ssrc: ssrc,
      sequence: sequence,
      timestamp: timestamp,
      pcm: pcm,
      isSilence: isSilence,
    )

  proc hexDump*(bytes: openArray[uint8], maxLen: int = 32): string =
    ## Format the first maxLen bytes of a packet as hex (for debug logging).
    result = ""
    let n = min(maxLen, bytes.len)
    const hex = "0123456789abcdef"
    for i in 0 ..< n:
      let b = int(bytes[i])
      result.add hex[(b shr 4) and 0xF]
      result.add hex[b and 0xF]
      if i mod 4 == 3 and i < n - 1:
        result.add ' '
    if bytes.len > n:
      result.add " ..."

  proc recvDecodedFrame*(vio: VoiceIo, bufferSize: int = 4096): DecodedFrame =
    ## Block on the voice UDP socket, decrypt and decode one packet.
    ## Returns nil if the packet is not an Opus media frame (e.g. RTCP) or
    ## if the per-speaker DAVE decryptor isn't ready yet.
    let packetStr = vio.vc.recvUdp(bufferSize)
    if packetStr.len == 0:
      return nil
    var bytes = newSeq[uint8](packetStr.len)
    var idx = 0
    for c in packetStr:
      bytes[idx] = uint8(ord(c))
      inc idx
    result = vio.decodePacket(bytes)

  proc recvRawPacket*(vio: VoiceIo, bufferSize: int = 4096): seq[uint8] =
    ## Receive one UDP packet without decryption — for diagnostic dumping.
    let packetStr = vio.vc.recvUdp(bufferSize)
    result = newSeq[uint8](packetStr.len)
    for i in 0 ..< packetStr.len:
      result[i] = uint8(ord(packetStr[i]))
