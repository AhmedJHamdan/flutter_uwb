package com.ahmedhamdan.flutter_uwb.oob

/**
 * In-memory cache of per-peer OOB exchange results.
 *
 * Holds the peer's UWB token bytes plus the 16-byte session key derived
 * from the [OobHandshake] ECDH so the strategy can feed both into
 * `RangingParameters` (Provisioned STS) once `startRanging` runs.
 */
object TokenStore {
    private val peerTokens = HashMap<String, ByteArray>()
    private val sessionKeys = HashMap<String, ByteArray>()

    @Synchronized
    fun putPeer(id: String, token: ByteArray, sessionKey: ByteArray? = null) {
        peerTokens[id] = token
        if (sessionKey != null) sessionKeys[id] = sessionKey
    }

    @Synchronized fun getPeer(id: String): ByteArray? = peerTokens[id]

    @Synchronized fun getSessionKey(id: String): ByteArray? = sessionKeys[id]

    @Synchronized fun clear() {
        peerTokens.clear()
        sessionKeys.clear()
    }
}
