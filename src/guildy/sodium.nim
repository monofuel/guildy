## Minimal libsodium FFI for the two AEAD modes Discord voice uses.
## Gated behind -d:guildyVoice so the rest of guildy doesn't pull in libsodium.

when defined(guildyVoice):
  const sodiumLib = "(libsodium.so|libsodium.so.26|libsodium.so.23)"

  # Key, nonce, and tag sizes for the two cipher suites.
  const
    AesGcmKeyBytes* = 32
    AesGcmNonceBytes* = 12
    AesGcmTagBytes* = 16

    XChaChaKeyBytes* = 32
    XChaChaNonceBytes* = 24
    XChaChaTagBytes* = 16

  # ---------------------------------------------------------------------------
  # Raw bindings
  # ---------------------------------------------------------------------------

  proc sodiumInitRaw(): cint {.dynlib: sodiumLib, cdecl,
      importc: "sodium_init".}

  proc cryptoAeadAes256gcmIsAvailable(): cint {.dynlib: sodiumLib, cdecl,
      importc: "crypto_aead_aes256gcm_is_available".}

  proc cryptoAeadAes256gcmEncrypt(c: ptr uint8, clen: ptr culonglong,
      m: ptr uint8, mlen: culonglong, ad: ptr uint8, adlen: culonglong,
      nsec: pointer, npub: ptr uint8,
      k: ptr uint8): cint {.dynlib: sodiumLib, cdecl,
      importc: "crypto_aead_aes256gcm_encrypt".}

  proc cryptoAeadAes256gcmDecrypt(m: ptr uint8, mlen: ptr culonglong,
      nsec: pointer, c: ptr uint8, clen: culonglong, ad: ptr uint8,
      adlen: culonglong, npub: ptr uint8,
      k: ptr uint8): cint {.dynlib: sodiumLib, cdecl,
      importc: "crypto_aead_aes256gcm_decrypt".}

  proc cryptoAeadXChaCha20Poly1305IetfEncrypt(c: ptr uint8,
      clen: ptr culonglong, m: ptr uint8, mlen: culonglong, ad: ptr uint8,
      adlen: culonglong, nsec: pointer, npub: ptr uint8,
      k: ptr uint8): cint {.dynlib: sodiumLib, cdecl,
      importc: "crypto_aead_xchacha20poly1305_ietf_encrypt".}

  proc cryptoAeadXChaCha20Poly1305IetfDecrypt(m: ptr uint8,
      mlen: ptr culonglong, nsec: pointer, c: ptr uint8, clen: culonglong,
      ad: ptr uint8, adlen: culonglong, npub: ptr uint8,
      k: ptr uint8): cint {.dynlib: sodiumLib, cdecl,
      importc: "crypto_aead_xchacha20poly1305_ietf_decrypt".}

  # ---------------------------------------------------------------------------
  # Initialization
  # ---------------------------------------------------------------------------

  var sodiumInitialized = false

  proc initSodium*() =
    ## Initialize libsodium. Safe to call multiple times.
    if sodiumInitialized:
      return
    let rc = sodiumInitRaw()
    if rc < 0:
      raise newException(OSError, "sodium_init failed: " & $rc)
    sodiumInitialized = true

  proc aesGcmAvailable*(): bool =
    ## Return true if the CPU supports AES-NI (required for AES-GCM).
    initSodium()
    cryptoAeadAes256gcmIsAvailable() == 1

  # ---------------------------------------------------------------------------
  # AES-256-GCM helpers
  # ---------------------------------------------------------------------------

  proc aesGcmEncrypt*(key, nonce, aad, plaintext: openArray[uint8]): seq[uint8] =
    ## Encrypt plaintext with AES-256-GCM using the given key, nonce, and AAD.
    ## Returns ciphertext with the 16-byte auth tag appended.
    if key.len != AesGcmKeyBytes:
      raise newException(ValueError, "AES-GCM key must be 32 bytes, got " & $key.len)
    if nonce.len != AesGcmNonceBytes:
      raise newException(ValueError, "AES-GCM nonce must be 12 bytes, got " & $nonce.len)
    initSodium()
    let outLen = plaintext.len + AesGcmTagBytes
    result = newSeq[uint8](outLen)
    var written: culonglong = 0
    let mPtr = if plaintext.len > 0: cast[ptr uint8](unsafeAddr plaintext[0]) else: nil
    let adPtr = if aad.len > 0: cast[ptr uint8](unsafeAddr aad[0]) else: nil
    let rc = cryptoAeadAes256gcmEncrypt(
      addr result[0], addr written,
      mPtr, culonglong(plaintext.len),
      adPtr, culonglong(aad.len),
      nil,
      cast[ptr uint8](unsafeAddr nonce[0]),
      cast[ptr uint8](unsafeAddr key[0]))
    if rc != 0:
      raise newException(OSError, "AES-256-GCM encrypt failed: " & $rc)
    result.setLen(int(written))

  proc aesGcmDecrypt*(key, nonce, aad, ciphertext: openArray[uint8]): seq[uint8] =
    ## Decrypt AES-256-GCM ciphertext (with appended 16-byte tag).
    ## Raises on auth failure.
    if key.len != AesGcmKeyBytes:
      raise newException(ValueError, "AES-GCM key must be 32 bytes")
    if nonce.len != AesGcmNonceBytes:
      raise newException(ValueError, "AES-GCM nonce must be 12 bytes")
    if ciphertext.len < AesGcmTagBytes:
      raise newException(ValueError, "AES-GCM ciphertext shorter than tag")
    initSodium()
    let outLen = ciphertext.len - AesGcmTagBytes
    result = newSeq[uint8](max(outLen, 1))
    var written: culonglong = 0
    let adPtr = if aad.len > 0: cast[ptr uint8](unsafeAddr aad[0]) else: nil
    let rc = cryptoAeadAes256gcmDecrypt(
      addr result[0], addr written,
      nil,
      cast[ptr uint8](unsafeAddr ciphertext[0]), culonglong(ciphertext.len),
      adPtr, culonglong(aad.len),
      cast[ptr uint8](unsafeAddr nonce[0]),
      cast[ptr uint8](unsafeAddr key[0]))
    if rc != 0:
      raise newException(OSError, "AES-256-GCM decrypt failed (auth)")
    result.setLen(int(written))

  # ---------------------------------------------------------------------------
  # XChaCha20-Poly1305-IETF helpers
  # ---------------------------------------------------------------------------

  proc xchachaEncrypt*(key, nonce, aad, plaintext: openArray[uint8]): seq[uint8] =
    ## Encrypt plaintext with XChaCha20-Poly1305-IETF.
    ## Returns ciphertext with the 16-byte auth tag appended.
    if key.len != XChaChaKeyBytes:
      raise newException(ValueError, "XChaCha20 key must be 32 bytes")
    if nonce.len != XChaChaNonceBytes:
      raise newException(ValueError, "XChaCha20 nonce must be 24 bytes")
    initSodium()
    let outLen = plaintext.len + XChaChaTagBytes
    result = newSeq[uint8](outLen)
    var written: culonglong = 0
    let mPtr = if plaintext.len > 0: cast[ptr uint8](unsafeAddr plaintext[0]) else: nil
    let adPtr = if aad.len > 0: cast[ptr uint8](unsafeAddr aad[0]) else: nil
    let rc = cryptoAeadXChaCha20Poly1305IetfEncrypt(
      addr result[0], addr written,
      mPtr, culonglong(plaintext.len),
      adPtr, culonglong(aad.len),
      nil,
      cast[ptr uint8](unsafeAddr nonce[0]),
      cast[ptr uint8](unsafeAddr key[0]))
    if rc != 0:
      raise newException(OSError, "XChaCha20-Poly1305 encrypt failed: " & $rc)
    result.setLen(int(written))

  proc xchachaDecrypt*(key, nonce, aad, ciphertext: openArray[uint8]): seq[uint8] =
    ## Decrypt XChaCha20-Poly1305-IETF ciphertext (with appended 16-byte tag).
    ## Raises on auth failure.
    if key.len != XChaChaKeyBytes:
      raise newException(ValueError, "XChaCha20 key must be 32 bytes")
    if nonce.len != XChaChaNonceBytes:
      raise newException(ValueError, "XChaCha20 nonce must be 24 bytes")
    if ciphertext.len < XChaChaTagBytes:
      raise newException(ValueError, "XChaCha20 ciphertext shorter than tag")
    initSodium()
    let outLen = ciphertext.len - XChaChaTagBytes
    result = newSeq[uint8](max(outLen, 1))
    var written: culonglong = 0
    let adPtr = if aad.len > 0: cast[ptr uint8](unsafeAddr aad[0]) else: nil
    let rc = cryptoAeadXChaCha20Poly1305IetfDecrypt(
      addr result[0], addr written,
      nil,
      cast[ptr uint8](unsafeAddr ciphertext[0]), culonglong(ciphertext.len),
      adPtr, culonglong(aad.len),
      cast[ptr uint8](unsafeAddr nonce[0]),
      cast[ptr uint8](unsafeAddr key[0]))
    if rc != 0:
      raise newException(OSError, "XChaCha20-Poly1305 decrypt failed (auth)")
    result.setLen(int(written))
