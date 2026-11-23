import Foundation
import CWhimCore

struct WhimAttachment: Codable, Identifiable, Equatable {
    var id: String = ""
    var noteId: String = ""
    var sha256: String
    var mime: String
    var width: Int = 0
    var height: Int = 0
    var sizeBytes: Int64 = 0
    var sortOrder: Int = 0
    var deleted: Bool = false
    var updatedAt: Int64 = 0
    var localPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case noteId = "note_id"
        case sha256, mime, width, height
        case sizeBytes = "size_bytes"
        case sortOrder = "sort_order"
        case deleted
        case updatedAt = "updated_at"
        case localPath = "local_path"
    }
}

struct WhimNote: Codable, Identifiable, Equatable {
    let id: String
    let content: String
    let tags: [String]?
    let attachments: [WhimAttachment]?
    let pinned: Bool
    let archived: Bool
    let deleted: Bool
    let createdAt: Int64
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, content, tags, attachments, pinned, archived, deleted
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct WhimTagNode: Codable, Identifiable, Equatable {
    var id: String { fullPath }
    let name: String
    let fullPath: String
    let count: Int
    let children: [WhimTagNode]?

    enum CodingKeys: String, CodingKey {
        case name
        case fullPath = "full_path"
        case count, children
    }
}

struct WhimSyncSummary: Codable {
    let peersFound: Int
    let peersSynced: Int
    let notesMerged: Int
    let blobsDownloaded: Int
    let blobsUploaded: Int
    let errors: [String]?

    enum CodingKeys: String, CodingKey {
        case peersFound = "peers_found"
        case peersSynced = "peers_synced"
        case notesMerged = "notes_merged"
        case blobsDownloaded = "blobs_downloaded"
        case blobsUploaded = "blobs_uploaded"
        case errors
    }
}

struct WhimSyncPeer: Codable, Identifiable, Equatable {
    var id: String { peerId }
    let peerId: String
    let displayName: String
    let lastAddr: String
    let pairCode: String?
    let lastHeardAt: Int64
    let lastSyncAt: Int64

    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case displayName = "display_name"
        case lastAddr = "last_addr"
        case pairCode = "pair_code"
        case lastHeardAt = "last_heard_at"
        case lastSyncAt = "last_sync_at"
    }
}

struct WhimDiscoveredPeer: Codable, Identifiable, Equatable {
    var id: String { peerId }
    let peerId: String
    let displayName: String
    let addr: String
    let paired: Bool

    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case displayName = "display_name"
        case addr, paired
    }
}

struct SavedBlob: Codable {
    let sha256: String
    let localPath: String
    let sizeBytes: Int64
    let mime: String

    enum CodingKeys: String, CodingKey {
        case sha256
        case localPath = "local_path"
        case sizeBytes = "size_bytes"
        case mime
    }
}

struct ExportResult: Codable {
    let outputDir: String
    let filesWritten: [String]?
    let notesExported: Int
    let blobsCopied: Int

    enum CodingKeys: String, CodingKey {
        case outputDir = "output_dir"
        case filesWritten = "files_written"
        case notesExported = "notes_exported"
        case blobsCopied = "blobs_copied"
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

enum WhimCoreError: LocalizedError {
    case bridge(String)
    var errorDescription: String? {
        switch self {
        case .bridge(let msg): return msg
        }
    }
}

final class CoreBridge {
    static let shared = CoreBridge()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {}

    private func decodeCString<T: Decodable>(_ ptr: UnsafeMutablePointer<CChar>?, as type: T.Type) throws -> T {
        guard let ptr else { throw WhimCoreError.bridge("nil response from core") }
        defer { WhimFreeString(ptr) }
        let str = String(cString: ptr)
        let env = try decoder.decode(Envelope<T>.self, from: Data(str.utf8))
        if env.ok, let data = env.data {
            return data
        }
        throw WhimCoreError.bridge(env.error ?? "unknown core error")
    }

    func initialize() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Whim", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = Host.current().localizedName ?? "Mac"
        _ = try dir.path.withCString { cDir in
            try host.withCString { cHost in
                try decodeCString(WhimInit(UnsafeMutablePointer(mutating: cDir), UnsafeMutablePointer(mutating: cHost)), as: String.self)
            }
        }
    }

    @discardableResult
    func startPeerServer(port: Int32 = 8788) throws -> Int {
        try decodeCString(WhimStartPeerServer(port), as: Int.self)
    }

    func saveBlob(data: Data, mime: String) throws -> SavedBlob {
        try data.withUnsafeBytes { rawBuf in
            try mime.withCString { cMime in
                try decodeCString(
                    WhimSaveBlob(UnsafeMutableRawPointer(mutating: rawBuf.baseAddress), Int32(data.count), UnsafeMutablePointer(mutating: cMime)),
                    as: SavedBlob.self
                )
            }
        }
    }

    func createNote(content: String, attachments: [WhimAttachment] = []) throws -> WhimNote {
        let attData = try encoder.encode(attachments)
        let attStr = String(data: attData, encoding: .utf8) ?? "[]"
        return try content.withCString { cContent in
            try attStr.withCString { cAtt in
                try decodeCString(
                    WhimCreateNote(UnsafeMutablePointer(mutating: cContent), UnsafeMutablePointer(mutating: cAtt)),
                    as: WhimNote.self
                )
            }
        }
    }

    func updateNote(
        id: String,
        content: String? = nil,
        pinned: Bool? = nil,
        archived: Bool? = nil,
        deleted: Bool? = nil,
        attachments: [WhimAttachment]? = nil
    ) throws -> WhimNote {
        var patch: [String: Any] = ["id": id]
        if let content { patch["content"] = content }
        if let pinned { patch["pinned"] = pinned }
        if let archived { patch["archived"] = archived }
        if let deleted { patch["deleted"] = deleted }
        if let attachments, !attachments.isEmpty {
            let attData = try encoder.encode(attachments)
            if let arr = try JSONSerialization.jsonObject(with: attData) as? [[String: Any]] {
                patch["attachments"] = arr
            }
        }
        let jsonData = try JSONSerialization.data(withJSONObject: patch)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
        return try jsonStr.withCString { cPatch in
            try decodeCString(WhimUpdateNote(UnsafeMutablePointer(mutating: cPatch)), as: WhimNote.self)
        }
    }

    func listNotes(
        query: String = "",
        tagPrefix: String = "",
        dateFromMs: Int64 = 0,
        dateToMs: Int64 = 0,
        includeArchived: Bool = false,
        limit: Int = 500
    ) throws -> [WhimNote] {
        var filter: [String: Any] = [
            "query": query,
            "tag_prefix": tagPrefix,
            "include_archived": includeArchived,
            "limit": limit
        ]
        if dateFromMs > 0 { filter["date_from_ms"] = dateFromMs }
        if dateToMs > 0 { filter["date_to_ms"] = dateToMs }
        let jsonData = try JSONSerialization.data(withJSONObject: filter)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
        return try jsonStr.withCString { cFilter in
            try decodeCString(WhimListNotes(UnsafeMutablePointer(mutating: cFilter)), as: [WhimNote].self)
        }
    }

    func listTodayNotes() throws -> [WhimNote] {
        try decodeCString(WhimListTodayNotes(), as: [WhimNote].self)
    }

    func listTagTree() throws -> [WhimTagNode] {
        try decodeCString(WhimListTagTree(), as: [WhimTagNode].self)
    }

    func syncOnce(timeoutSec: Int32 = 8) throws -> WhimSyncSummary {
        try decodeCString(WhimSyncOnce(timeoutSec), as: WhimSyncSummary.self)
    }

    func getPairCode() throws -> String {
        try decodeCString(WhimGetPairCode(), as: String.self)
    }

    func regeneratePairCode() throws -> String {
        try decodeCString(WhimRegeneratePairCode(), as: String.self)
    }

    func discoverLAN() throws -> [WhimDiscoveredPeer] {
        try decodeCString(WhimDiscoverLAN(), as: [WhimDiscoveredPeer].self)
    }

    func pairAndSync(addr: String, remoteCode: String) throws -> WhimSyncSummary {
        try addr.withCString { cAddr in
            try remoteCode.withCString { cCode in
                try decodeCString(
                    WhimPairAndSync(UnsafeMutablePointer(mutating: cAddr), UnsafeMutablePointer(mutating: cCode)),
                    as: WhimSyncSummary.self
                )
            }
        }
    }

    func listPairedPeers() throws -> [WhimSyncPeer] {
        try decodeCString(WhimListPairedPeers(), as: [WhimSyncPeer].self)
    }

    func removePairedPeer(peerId: String) throws {
        _ = try peerId.withCString { cId in
            try decodeCString(WhimRemovePairedPeer(UnsafeMutablePointer(mutating: cId)), as: String.self)
        }
    }

    func exportMarkdown(outDir: String) throws -> ExportResult {
        try "{}".withCString { cFilter in
            try outDir.withCString { cOut in
                try decodeCString(
                    WhimExportMarkdown(UnsafeMutablePointer(mutating: cFilter), UnsafeMutablePointer(mutating: cOut)),
                    as: ExportResult.self
                )
            }
        }
    }
}
