## Nim FFI bindings for libdave (Discord Audio/Video E2EE) C API.
## Gated behind -d:guildyVoice compile flag.

when defined(guildyVoice):
  const daveLib = "libdave.so"

  # Opaque handle types
  type
    DAVESessionHandle* = pointer
    DAVECommitResultHandle* = pointer
    DAVEWelcomeResultHandle* = pointer
    DAVEKeyRatchetHandle* = pointer
    DAVEEncryptorHandle* = pointer
    DAVEDecryptorHandle* = pointer

  type
    DAVECodec* {.size: sizeof(cint).} = enum
      CodecUnknown = 0
      CodecOpus = 1
      CodecVP8 = 2
      CodecVP9 = 3
      CodecH264 = 4
      CodecH265 = 5
      CodecAV1 = 6

    DAVEMediaType* {.size: sizeof(cint).} = enum
      MediaAudio = 0
      MediaVideo = 1

    DAVEEncryptorResultCode* {.size: sizeof(cint).} = enum
      EncryptSuccess = 0
      EncryptionFailure = 1
      EncryptMissingKeyRatchet = 2
      EncryptMissingCryptor = 3
      EncryptTooManyAttempts = 4

    DAVEDecryptorResultCode* {.size: sizeof(cint).} = enum
      DecryptSuccess = 0
      DecryptionFailure = 1
      DecryptMissingKeyRatchet = 2
      DecryptInvalidNonce = 3
      DecryptMissingCryptor = 4

  type
    DAVEMLSFailureCallback* = proc(source: cstring, reason: cstring,
        userData: pointer) {.cdecl.}

  # ---------------------------------------------------------------------------
  # Version
  # ---------------------------------------------------------------------------

  proc daveMaxSupportedProtocolVersion*(): uint16 {.dynlib: daveLib, cdecl,
      importc.}

  # ---------------------------------------------------------------------------
  # Memory
  # ---------------------------------------------------------------------------

  proc daveFree*(p: pointer) {.dynlib: daveLib, cdecl, importc.}

  # ---------------------------------------------------------------------------
  # Session
  # ---------------------------------------------------------------------------

  proc daveSessionCreate*(context: pointer, authSessionId: cstring,
      callback: DAVEMLSFailureCallback,
      userData: pointer): DAVESessionHandle {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionDestroy*(session: DAVESessionHandle) {.dynlib: daveLib, cdecl,
      importc.}

  proc daveSessionInit*(session: DAVESessionHandle, version: uint16,
      groupId: uint64, selfUserId: cstring) {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionReset*(session: DAVESessionHandle) {.dynlib: daveLib, cdecl,
      importc.}

  proc daveSessionSetProtocolVersion*(session: DAVESessionHandle,
      version: uint16) {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionGetProtocolVersion*(
      session: DAVESessionHandle): uint16 {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionGetLastEpochAuthenticator*(session: DAVESessionHandle,
      authenticator: ptr ptr uint8,
      length: ptr csize_t) {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionSetExternalSender*(session: DAVESessionHandle,
      externalSender: ptr uint8,
      length: csize_t) {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionProcessProposals*(session: DAVESessionHandle,
      proposals: ptr uint8, length: csize_t, recognizedUserIds: ptr cstring,
      recognizedUserIdsLength: csize_t, commitWelcomeBytes: ptr ptr uint8,
      commitWelcomeBytesLength: ptr csize_t) {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionProcessCommit*(session: DAVESessionHandle, commit: ptr uint8,
      length: csize_t): DAVECommitResultHandle {.dynlib: daveLib, cdecl,
      importc.}

  proc daveSessionProcessWelcome*(session: DAVESessionHandle,
      welcome: ptr uint8, length: csize_t, recognizedUserIds: ptr cstring,
      recognizedUserIdsLength: csize_t): DAVEWelcomeResultHandle {.
      dynlib: daveLib, cdecl, importc.}

  proc daveSessionGetMarshalledKeyPackage*(session: DAVESessionHandle,
      keyPackage: ptr ptr uint8,
      length: ptr csize_t) {.dynlib: daveLib, cdecl, importc.}

  proc daveSessionGetKeyRatchet*(session: DAVESessionHandle,
      userId: cstring): DAVEKeyRatchetHandle {.dynlib: daveLib, cdecl, importc.}

  # ---------------------------------------------------------------------------
  # Key Ratchet
  # ---------------------------------------------------------------------------

  proc daveKeyRatchetDestroy*(keyRatchet: DAVEKeyRatchetHandle) {.
      dynlib: daveLib, cdecl, importc.}

  # ---------------------------------------------------------------------------
  # Commit Result
  # ---------------------------------------------------------------------------

  proc daveCommitResultIsFailed*(
      h: DAVECommitResultHandle): bool {.dynlib: daveLib, cdecl, importc.}

  proc daveCommitResultIsIgnored*(
      h: DAVECommitResultHandle): bool {.dynlib: daveLib, cdecl, importc.}

  proc daveCommitResultGetRosterMemberIds*(h: DAVECommitResultHandle,
      rosterIds: ptr ptr uint64,
      rosterIdsLength: ptr csize_t) {.dynlib: daveLib, cdecl, importc.}

  proc daveCommitResultDestroy*(h: DAVECommitResultHandle) {.dynlib: daveLib,
      cdecl, importc.}

  # ---------------------------------------------------------------------------
  # Welcome Result
  # ---------------------------------------------------------------------------

  proc daveWelcomeResultGetRosterMemberIds*(h: DAVEWelcomeResultHandle,
      rosterIds: ptr ptr uint64,
      rosterIdsLength: ptr csize_t) {.dynlib: daveLib, cdecl, importc.}

  proc daveWelcomeResultDestroy*(h: DAVEWelcomeResultHandle) {.dynlib: daveLib,
      cdecl, importc.}

  # ---------------------------------------------------------------------------
  # Encryptor
  # ---------------------------------------------------------------------------

  proc daveEncryptorCreate*(): DAVEEncryptorHandle {.dynlib: daveLib, cdecl,
      importc.}

  proc daveEncryptorDestroy*(encryptor: DAVEEncryptorHandle) {.dynlib: daveLib,
      cdecl, importc.}

  proc daveEncryptorSetKeyRatchet*(encryptor: DAVEEncryptorHandle,
      keyRatchet: DAVEKeyRatchetHandle) {.dynlib: daveLib, cdecl, importc.}

  proc daveEncryptorSetPassthroughMode*(encryptor: DAVEEncryptorHandle,
      passthroughMode: bool) {.dynlib: daveLib, cdecl, importc.}

  proc daveEncryptorAssignSsrcToCodec*(encryptor: DAVEEncryptorHandle,
      ssrc: uint32, codecType: DAVECodec) {.dynlib: daveLib, cdecl, importc.}

  proc daveEncryptorGetProtocolVersion*(
      encryptor: DAVEEncryptorHandle): uint16 {.dynlib: daveLib, cdecl,
      importc.}

  proc daveEncryptorGetMaxCiphertextByteSize*(encryptor: DAVEEncryptorHandle,
      mediaType: DAVEMediaType,
      frameSize: csize_t): csize_t {.dynlib: daveLib, cdecl, importc.}

  proc daveEncryptorEncrypt*(encryptor: DAVEEncryptorHandle,
      mediaType: DAVEMediaType, ssrc: uint32, frame: ptr uint8,
      frameLength: csize_t, encryptedFrame: ptr uint8,
      encryptedFrameCapacity: csize_t,
      bytesWritten: ptr csize_t): DAVEEncryptorResultCode {.dynlib: daveLib,
      cdecl, importc.}

  # ---------------------------------------------------------------------------
  # Decryptor
  # ---------------------------------------------------------------------------

  proc daveDecryptorCreate*(): DAVEDecryptorHandle {.dynlib: daveLib, cdecl,
      importc.}

  proc daveDecryptorDestroy*(decryptor: DAVEDecryptorHandle) {.dynlib: daveLib,
      cdecl, importc.}

  proc daveDecryptorTransitionToKeyRatchet*(decryptor: DAVEDecryptorHandle,
      keyRatchet: DAVEKeyRatchetHandle) {.dynlib: daveLib, cdecl, importc.}

  proc daveDecryptorTransitionToPassthroughMode*(
      decryptor: DAVEDecryptorHandle,
      passthroughMode: bool) {.dynlib: daveLib, cdecl, importc.}

  proc daveDecryptorDecrypt*(decryptor: DAVEDecryptorHandle,
      mediaType: DAVEMediaType, encryptedFrame: ptr uint8,
      encryptedFrameLength: csize_t, frame: ptr uint8, frameCapacity: csize_t,
      bytesWritten: ptr csize_t): DAVEDecryptorResultCode {.dynlib: daveLib,
      cdecl, importc.}

  proc daveDecryptorGetMaxPlaintextByteSize*(decryptor: DAVEDecryptorHandle,
      mediaType: DAVEMediaType,
      encryptedFrameSize: csize_t): csize_t {.dynlib: daveLib, cdecl, importc.}

  # ---------------------------------------------------------------------------
  # Nim-friendly wrappers
  # ---------------------------------------------------------------------------

  proc getKeyPackage*(session: DAVESessionHandle): seq[uint8] =
    ## Get the marshalled MLS key package as a seq[uint8].
    var dataPtr: ptr uint8
    var dataLen: csize_t
    daveSessionGetMarshalledKeyPackage(session, addr dataPtr, addr dataLen)
    if dataPtr != nil and dataLen > 0:
      result = newSeq[uint8](dataLen)
      copyMem(addr result[0], dataPtr, dataLen)
      daveFree(dataPtr)

  proc setExternalSender*(session: DAVESessionHandle, data: seq[uint8]) =
    ## Set the external sender package from a seq[uint8].
    if data.len > 0:
      daveSessionSetExternalSender(session, unsafeAddr data[0], csize_t(data.len))

  proc processProposals*(session: DAVESessionHandle, proposals: seq[uint8],
      recognizedUserIds: seq[string]): seq[uint8] =
    ## Process MLS proposals, returns commit+welcome bytes (empty if none).
    var cIds = newSeq[cstring](recognizedUserIds.len)
    for i, id in recognizedUserIds:
      cIds[i] = cstring(id)
    var outPtr: ptr uint8
    var outLen: csize_t
    let idsPtr = if cIds.len > 0: addr cIds[0] else: nil
    daveSessionProcessProposals(session, unsafeAddr proposals[0],
        csize_t(proposals.len), idsPtr, csize_t(cIds.len), addr outPtr,
        addr outLen)
    if outPtr != nil and outLen > 0:
      result = newSeq[uint8](outLen)
      copyMem(addr result[0], outPtr, outLen)
      daveFree(outPtr)

  proc processCommit*(session: DAVESessionHandle,
      commit: seq[uint8]): DAVECommitResultHandle =
    ## Process an MLS commit message. Caller must destroy result.
    daveSessionProcessCommit(session, unsafeAddr commit[0],
        csize_t(commit.len))

  proc processWelcome*(session: DAVESessionHandle, welcome: seq[uint8],
      recognizedUserIds: seq[string]): DAVEWelcomeResultHandle =
    ## Process an MLS welcome message. Caller must destroy result.
    var cIds = newSeq[cstring](recognizedUserIds.len)
    for i, id in recognizedUserIds:
      cIds[i] = cstring(id)
    let idsPtr = if cIds.len > 0: addr cIds[0] else: nil
    daveSessionProcessWelcome(session, unsafeAddr welcome[0],
        csize_t(welcome.len), idsPtr, csize_t(cIds.len))

  proc mlsFailureCallback(source: cstring, reason: cstring,
      userData: pointer) {.cdecl.} =
    when defined(guildyVoiceDebug):
      echo "DAVE MLS failure: source=", $source, " reason=", $reason

  proc createDaveSession*(authSessionId: string): DAVESessionHandle =
    ## Create a new DAVE session with default failure callback.
    daveSessionCreate(nil, cstring(authSessionId), mlsFailureCallback, nil)
