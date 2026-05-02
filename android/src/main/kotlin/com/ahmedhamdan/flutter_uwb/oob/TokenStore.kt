package com.ahmedhamdan.flutter_uwb.oob
object TokenStore {
    private val peer = HashMap<String, ByteArray>()
    @Synchronized fun putPeer(id: String, v: ByteArray) { peer[id]=v }
    @Synchronized fun getPeer(id: String): ByteArray? = peer[id]
    @Synchronized fun clear() { peer.clear() }
}
