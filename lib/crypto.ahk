; BCrypt-based SHA-256 / HMAC-SHA-256 primitives shared by the signing
; translation engines (Youdao v3 hash, Volcengine V4 chain, ...). Key-chained
; signatures need intermediate HMAC results as raw bytes, which a hex-only
; helper cannot produce.

; SHA-256 of a string (UTF-8) -> 64-char lowercase hex.
CryptoSha256Hex(text) {
    byteLength := StrPut(text, "UTF-8") - 1
    binary := Buffer(byteLength + 1)
    StrPut(text, binary, "UTF-8")
    return CryptoDigestHex(CryptoBcryptHash(binary, byteLength, 0, 0))
}

; HMAC-SHA-256. key: Buffer with raw bytes, or String (hashed as UTF-8).
; Returns a 32-byte Buffer, so chained derivations can feed it straight back
; in as the key of the next round.
CryptoHmacSha256(key, message) {
    keyPtr := 0
    keyLength := 0
    if key is Buffer {
        keyPtr := key.Ptr
        keyLength := key.Size
    } else {
        keyLength := StrPut(key, "UTF-8") - 1
        keyBuffer := Buffer(keyLength + 1)
        StrPut(key, keyBuffer, "UTF-8")
        keyPtr := keyBuffer.Ptr
    }
    msgLength := StrPut(message, "UTF-8") - 1
    msgBuffer := Buffer(msgLength + 1)
    StrPut(message, msgBuffer, "UTF-8")
    return CryptoBcryptHash(msgBuffer, msgLength, keyPtr, keyLength)
}

; HMAC-SHA-256 hex-encoded — the final signature form.
CryptoHmacSha256Hex(key, message) {
    return CryptoDigestHex(CryptoHmacSha256(key, message))
}

CryptoBcryptHash(dataBuffer, dataLength, keyPtr, keyLength) {
    ; BCRYPT_ALG_HANDLE_HMAC_FLAG (0x8) turns the hash into HMAC; the
    ; BCryptCreateHash secret argument then carries the key.
    hmacFlag := keyLength ? 0x8 : 0
    algorithmHandle := 0
    if DllCall("bcrypt\BCryptOpenAlgorithmProvider", "ptr*", &algorithmHandle := 0, "ptr", StrPtr("SHA256"), "ptr", 0, "uint", hmacFlag)
        throw Error("BCryptOpenAlgorithmProvider failed")
    hashHandle := 0
    try {
        objectLength := 0
        hashLength := 0
        if DllCall("bcrypt\BCryptGetProperty", "ptr", algorithmHandle, "ptr", StrPtr("ObjectLength"), "uint*", &objectLength := 0, "uint", 4, "uint*", &writtenLength := 0, "uint", 0)
            throw Error("BCryptGetProperty(ObjectLength) failed")
        if DllCall("bcrypt\BCryptGetProperty", "ptr", algorithmHandle, "ptr", StrPtr("HashDigestLength"), "uint*", &hashLength := 0, "uint", 4, "uint*", &writtenLength := 0, "uint", 0)
            throw Error("BCryptGetProperty(HashDigestLength) failed")
        hashObject := Buffer(objectLength, 0)
        digest := Buffer(hashLength, 0)
        if DllCall("bcrypt\BCryptCreateHash", "ptr", algorithmHandle, "ptr*", &hashHandle := 0, "ptr", hashObject, "uint", objectLength, "ptr", keyPtr, "uint", keyLength, "uint", 0)
            throw Error("BCryptCreateHash failed")
        if DllCall("bcrypt\BCryptHashData", "ptr", hashHandle, "ptr", dataBuffer, "uint", dataLength, "uint", 0)
            throw Error("BCryptHashData failed")
        if DllCall("bcrypt\BCryptFinishHash", "ptr", hashHandle, "ptr", digest, "uint", hashLength, "uint", 0)
            throw Error("BCryptFinishHash failed")
    } finally {
        if hashHandle
            DllCall("bcrypt\BCryptDestroyHash", "ptr", hashHandle)
        DllCall("bcrypt\BCryptCloseAlgorithmProvider", "ptr", algorithmHandle, "uint", 0)
    }
    return digest
}

CryptoDigestHex(digest) {
    hex := ""
    loop digest.Size
        hex .= Format("{:02x}", NumGet(digest, A_Index - 1, "UChar"))
    return hex
}
