package com.whim.app.core

import android.content.Context
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mobile.Mobile
import java.io.File

/**
 * Thread-safe Kotlin bridge to the embedded Go core library (whimcore.aar).
 */
object WhimCoreBridge {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    @Volatile
    private var initialized = false

    fun ensureInit(context: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            val dataDir = File(context.applicationContext.filesDir, "whim_data").apply { mkdirs() }
            val deviceName = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
            Mobile.init(dataDir.absolutePath, deviceName)
            initialized = true
        }
    }

    suspend fun saveBlob(bytes: ByteArray, mime: String): SavedBlob = withContext(Dispatchers.IO) {
        val raw = Mobile.saveBlob(bytes, mime)
        json.decodeFromString(raw)
    }

    suspend fun createNote(content: String, attachments: List<WhimAttachment> = emptyList()): WhimNote =
        withContext(Dispatchers.IO) {
            val attJson = if (attachments.isEmpty()) "[]" else json.encodeToString(attachments)
            val raw = Mobile.createNote(content, attJson)
            json.decodeFromString(raw)
        }

    suspend fun updateNote(
        id: String,
        content: String? = null,
        pinned: Boolean? = null,
        archived: Boolean? = null,
        deleted: Boolean? = null
    ): WhimNote = withContext(Dispatchers.IO) {
        val patch = buildJsonObject {
            put("id", id)
            content?.let { put("content", it) }
            pinned?.let { put("pinned", it) }
            archived?.let { put("archived", it) }
            deleted?.let { put("deleted", it) }
        }
        val raw = Mobile.updateNote(patch.toString())
        json.decodeFromString(raw)
    }

    suspend fun listNotes(filter: WhimListFilter = WhimListFilter()): List<WhimNote> =
        withContext(Dispatchers.IO) {
            val raw = Mobile.listNotes(json.encodeToString(filter))
            json.decodeFromString(raw)
        }

    suspend fun listTodayNotes(): List<WhimNote> = withContext(Dispatchers.IO) {
        val raw = Mobile.listTodayNotes()
        json.decodeFromString(raw)
    }

    fun countTodayNotesBlocking(): Int = Mobile.countTodayNotes().toInt()

    suspend fun listTagTree(): List<WhimTagNode> = withContext(Dispatchers.IO) {
        val raw = Mobile.listTagTree()
        json.decodeFromString(raw)
    }

    fun startPeerServer(port: Int = 8788): Int = Mobile.startPeerServer(port.toLong()).toInt()

    fun stopPeerServer() {
        runCatching { Mobile.stopPeerServer() }
    }

    suspend fun syncOnce(timeoutSec: Int = 8): WhimSyncSummary = withContext(Dispatchers.IO) {
        val raw = Mobile.syncOnce(timeoutSec.toLong())
        json.decodeFromString(raw)
    }

    fun syncOnceBlocking(timeoutSec: Int = 8): WhimSyncSummary {
        val raw = Mobile.syncOnce(timeoutSec.toLong())
        return json.decodeFromString(raw)
    }

    fun getPairCode(): String = Mobile.getPairCode()

    fun setPairCode(code: String): String = Mobile.setPairCode(code)

    fun regeneratePairCode(): String = Mobile.regeneratePairCode()

    fun setManualPeers(addrs: List<String>) {
        Mobile.setManualPeers(json.encodeToString(addrs))
    }
}
