package com.whim.app.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class WhimAttachment(
    val id: String = "",
    @SerialName("note_id") val noteId: String = "",
    val sha256: String = "",
    val mime: String = "image/png",
    val width: Int = 0,
    val height: Int = 0,
    @SerialName("size_bytes") val sizeBytes: Long = 0,
    @SerialName("sort_order") val sortOrder: Int = 0,
    val deleted: Boolean = false,
    @SerialName("updated_at") val updatedAt: Long = 0,
    @SerialName("local_path") val localPath: String = ""
)

@Serializable
data class WhimNote(
    val id: String,
    val content: String,
    val tags: List<String> = emptyList(),
    val attachments: List<WhimAttachment> = emptyList(),
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val deleted: Boolean = false,
    @SerialName("created_at") val createdAt: Long = 0,
    @SerialName("updated_at") val updatedAt: Long = 0
)

@Serializable
data class WhimTagNode(
    val name: String,
    @SerialName("full_path") val fullPath: String,
    val count: Int,
    val children: List<WhimTagNode> = emptyList()
)

@Serializable
data class WhimNoteCursor(
    val pinned: Boolean = false,
    @SerialName("created_at") val createdAt: Long = 0,
    val id: String = ""
)

@Serializable
data class WhimNotePage(
    val notes: List<WhimNote> = emptyList(),
    @SerialName("has_more") val hasMore: Boolean = false,
    @SerialName("next_cursor") val nextCursor: WhimNoteCursor? = null
)

@Serializable
data class WhimStats(
    @SerialName("total_notes") val totalNotes: Int = 0,
    @SerialName("total_tags") val totalTags: Int = 0,
    @SerialName("active_days") val activeDays: Int = 1,
    @SerialName("daily_counts") val dailyCounts: Map<String, Int> = emptyMap()
)

@Serializable
data class WhimListFilter(
    val query: String = "",
    @SerialName("tag_prefix") val tagPrefix: String = "",
    @SerialName("include_archived") val includeArchived: Boolean = false,
    @SerialName("only_archived") val onlyArchived: Boolean = false,
    val limit: Int = 50,
    val cursor: WhimNoteCursor? = null
)

@Serializable
data class WhimPeerSyncStatus(
    @SerialName("peer_id") val peerId: String = "",
    @SerialName("display_name") val displayName: String = "",
    val addr: String = "",
    val status: String = "",
    val message: String = ""
)

@Serializable
data class WhimSyncSummary(
    @SerialName("peers_found") val peersFound: Int = 0,
    @SerialName("peers_synced") val peersSynced: Int = 0,
    @SerialName("notes_merged") val notesMerged: Int = 0,
    @SerialName("blobs_downloaded") val blobsDownloaded: Int = 0,
    @SerialName("blobs_uploaded") val blobsUploaded: Int = 0,
    val peers: List<WhimPeerSyncStatus> = emptyList(),
    val errors: List<String> = emptyList()
)

@Serializable
data class WhimSyncPeer(
    @SerialName("peer_id") val peerId: String,
    @SerialName("display_name") val displayName: String = "",
    @SerialName("last_addr") val lastAddr: String = "",
    @SerialName("pair_code") val pairCode: String = "",
    @SerialName("last_heard_at") val lastHeardAt: Long = 0,
    @SerialName("last_sync_at") val lastSyncAt: Long = 0
)

@Serializable
data class WhimDiscoveredPeer(
    @SerialName("peer_id") val peerId: String,
    @SerialName("display_name") val displayName: String = "",
    val addr: String = "",
    val paired: Boolean = false
)

@Serializable
data class SavedBlob(
    val sha256: String,
    @SerialName("local_path") val localPath: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    val mime: String
)
