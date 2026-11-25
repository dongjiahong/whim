package com.whim.app.core

import androidx.compose.runtime.Immutable
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Immutable
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

@Immutable
@Serializable
data class WhimNote(
    val id: String,
    @SerialName("parent_id") val parentId: String = "",
    val content: String,
    val tags: List<String> = emptyList(),
    val attachments: List<WhimAttachment> = emptyList(),
    @SerialName("reply_count") val replyCount: Int = 0,
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val deleted: Boolean = false,
    @SerialName("created_at") val createdAt: Long = 0,
    @SerialName("updated_at") val updatedAt: Long = 0
)

@Immutable
@Serializable
data class WhimTagNode(
    val name: String,
    @SerialName("full_path") val fullPath: String,
    val count: Int,
    val children: List<WhimTagNode> = emptyList()
)

@Immutable
@Serializable
data class WhimNoteCursor(
    val pinned: Boolean = false,
    @SerialName("created_at") val createdAt: Long = 0,
    val id: String = ""
)

@Immutable
@Serializable
data class WhimNotePage(
    val notes: List<WhimNote> = emptyList(),
    @SerialName("has_more") val hasMore: Boolean = false,
    @SerialName("next_cursor") val nextCursor: WhimNoteCursor? = null
)

@Immutable
@Serializable
data class WhimStats(
    @SerialName("total_notes") val totalNotes: Int = 0,
    @SerialName("total_tags") val totalTags: Int = 0,
    @SerialName("active_days") val activeDays: Int = 1,
    @SerialName("daily_counts") val dailyCounts: Map<String, Int> = emptyMap()
)

@Immutable
@Serializable
data class WhimListFilter(
    val query: String = "",
    @SerialName("tag_prefix") val tagPrefix: String = "",
    @SerialName("date_from_ms") val dateFromMs: Long = 0,
    @SerialName("date_to_ms") val dateToMs: Long = 0,
    @SerialName("include_archived") val includeArchived: Boolean = false,
    @SerialName("only_archived") val onlyArchived: Boolean = false,
    @SerialName("only_deleted") val onlyDeleted: Boolean = false,
    @SerialName("only_untagged") val onlyUntagged: Boolean = false,
    @SerialName("only_with_images") val onlyWithImages: Boolean = false,
    @SerialName("parent_id") val parentId: String = "",
    val limit: Int = 50,
    val cursor: WhimNoteCursor? = null
)

@Immutable
@Serializable
data class WhimPeerSyncStatus(
    @SerialName("peer_id") val peerId: String = "",
    @SerialName("display_name") val displayName: String = "",
    val addr: String = "",
    val status: String = "",
    val message: String = ""
)

@Immutable
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

@Immutable
@Serializable
data class WhimLivePeerStatus(
    @SerialName("peer_id") val peerId: String = "",
    @SerialName("display_name") val displayName: String = "",
    val addr: String = "",
    val online: Boolean = false,
    @SerialName("rtt_ms") val rttMs: Long = 0,
    @SerialName("last_pong_at") val lastPongAt: Long = 0,
    @SerialName("last_sync_at") val lastSyncAt: Long = 0,
    val status: String = "offline",
    val message: String = ""
)

@Immutable
@Serializable
data class WhimSyncHealthStatus(
    val state: String = "offline",
    val connected: Boolean = false,
    @SerialName("online_peers") val onlinePeers: Int = 0,
    @SerialName("total_peers") val totalPeers: Int = 0,
    @SerialName("rtt_ms") val rttMs: Long = 0,
    @SerialName("last_pong_at") val lastPongAt: Long = 0,
    @SerialName("last_sync_at") val lastSyncAt: Long = 0,
    @SerialName("peer_name") val peerName: String = "",
    @SerialName("error_message") val errorMessage: String = "",
    val peers: List<WhimLivePeerStatus> = emptyList()
)

@Immutable
@Serializable
data class WhimSyncPeer(
    @SerialName("peer_id") val peerId: String,
    @SerialName("display_name") val displayName: String = "",
    @SerialName("last_addr") val lastAddr: String = "",
    @SerialName("pair_code") val pairCode: String = "",
    @SerialName("last_heard_at") val lastHeardAt: Long = 0,
    @SerialName("last_sync_at") val lastSyncAt: Long = 0
)

@Immutable
@Serializable
data class WhimDiscoveredPeer(
    @SerialName("peer_id") val peerId: String,
    @SerialName("display_name") val displayName: String = "",
    val addr: String = "",
    val paired: Boolean = false
)

@Immutable
@Serializable
data class SavedBlob(
    val sha256: String,
    @SerialName("local_path") val localPath: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    val mime: String
)

@Immutable
@Serializable
data class WhimStorageCleanupResult(
    @SerialName("removed_files") val removedFiles: Int = 0,
    @SerialName("freed_bytes") val freedBytes: Long = 0
)

@Immutable
@Serializable
data class WhimTagRenameResult(
    @SerialName("old_tag") val oldTag: String = "",
    @SerialName("new_tag") val newTag: String = "",
    @SerialName("updated_notes") val updatedNotes: Int = 0
)

@Immutable
@Serializable
data class WhimBackupResult(
    @SerialName("backup_path") val backupPath: String = "",
    @SerialName("backup_dir") val backupDir: String = "",
    @SerialName("backup_count") val backupCount: Int = 0,
    @SerialName("size_bytes") val sizeBytes: Long = 0,
    @SerialName("created_at") val createdAt: Long = 0,
    val skipped: Boolean = false
)

@Immutable
@Serializable
data class WhimBackupInfo(
    val name: String = "",
    val path: String = "",
    @SerialName("size_bytes") val sizeBytes: Long = 0,
    @SerialName("mod_time") val modTime: Long = 0
)
