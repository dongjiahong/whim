package model

import (
	"crypto/rand"
	"encoding/binary"
	"time"
)

// FieldStamps tracks last-write-wins timestamps (Unix ms) per mutable field.
type FieldStamps struct {
	Content     int64 `json:"content"`
	Pinned      int64 `json:"pinned"`
	Archived    int64 `json:"archived"`
	Deleted     int64 `json:"deleted"`
	Attachments int64 `json:"attachments"`
}

// Max returns the maximum timestamp across all tracked fields.
func (s FieldStamps) Max() int64 {
	m := s.Content
	if s.Pinned > m {
		m = s.Pinned
	}
	if s.Archived > m {
		m = s.Archived
	}
	if s.Deleted > m {
		m = s.Deleted
	}
	if s.Attachments > m {
		m = s.Attachments
	}
	return m
}

// Attachment represents a content-addressed image attached to a note.
type Attachment struct {
	ID        string `json:"id"`
	NoteID    string `json:"note_id"`
	SHA256    string `json:"sha256"`
	MIME      string `json:"mime"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
	SizeBytes int64  `json:"size_bytes"`
	SortOrder int    `json:"sort_order"`
	Deleted   bool   `json:"deleted"`
	UpdatedAt int64  `json:"updated_at"`
	LocalPath string `json:"local_path,omitempty"` // populated locally, omitted in sync
}

// Note is the core card entity in Whim.
type Note struct {
	ID          string       `json:"id"`
	Content     string       `json:"content"`
	Tags        []string     `json:"tags,omitempty"`
	Attachments []Attachment `json:"attachments,omitempty"`
	Pinned      bool         `json:"pinned"`
	Archived    bool         `json:"archived"`
	Deleted     bool         `json:"deleted"`
	CreatedAt   int64        `json:"created_at"`
	UpdatedAt   int64        `json:"updated_at"`
	Stamps      FieldStamps  `json:"stamps"`
}

// TagNode represents a node in the hierarchical multi-level tag tree.
type TagNode struct {
	Name     string    `json:"name"`
	FullPath string    `json:"full_path"`
	Count    int       `json:"count"`
	Children []TagNode `json:"children,omitempty"`
}

// ListFilter controls note queries.
type ListFilter struct {
	Query           string `json:"query,omitempty"`
	TagPrefix       string `json:"tag_prefix,omitempty"`
	DateFromMs      int64  `json:"date_from_ms,omitempty"`
	DateToMs        int64  `json:"date_to_ms,omitempty"`
	IncludeArchived bool   `json:"include_archived,omitempty"`
	OnlyPinned      bool   `json:"only_pinned,omitempty"`
	Limit           int    `json:"limit,omitempty"`
	Offset          int    `json:"offset,omitempty"`
}

// SyncPeer records per-peer pairing credentials and sync watermark locally.
type SyncPeer struct {
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	LastAddr    string `json:"last_addr"`
	PairCode    string `json:"pair_code,omitempty"`
	LastHeardAt int64  `json:"last_heard_at"`
	LastSyncAt  int64  `json:"last_sync_at"`
}

// DiscoveredPeerInfo describes a LAN peer returned to the UI before or after pairing.
type DiscoveredPeerInfo struct {
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	Addr        string `json:"addr"`
	Paired      bool   `json:"paired"`
}

// SyncExchangeRequest is sent in POST /sync/exchange.
type SyncExchangeRequest struct {
	PeerID      string       `json:"peer_id"`
	DisplayName string       `json:"display_name"`
	Since       int64        `json:"since"`
	Notes       []Note       `json:"notes"`
	Attachments []Attachment `json:"attachments"`
	HaveBlobs   []string     `json:"have_blobs,omitempty"`
}

// SyncExchangeResponse is returned from POST /sync/exchange.
type SyncExchangeResponse struct {
	PeerID      string       `json:"peer_id"`
	DisplayName string       `json:"display_name"`
	ServerTime  int64        `json:"server_time"`
	Notes       []Note       `json:"notes"`
	Attachments []Attachment `json:"attachments"`
	WantBlobs   []string     `json:"want_blobs,omitempty"`
}

// PeerSyncStatus reports the latest sync outcome for one discovered LAN peer.
type PeerSyncStatus struct {
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	Addr        string `json:"addr"`
	Status      string `json:"status"` // "synced" | "wrong_code" | "locked" | "error"
	Message     string `json:"message,omitempty"`
}

// SyncSummary summarizes a SyncOnce execution.
type SyncSummary struct {
	PeersFound      int              `json:"peers_found"`
	PeersSynced     int              `json:"peers_synced"`
	NotesMerged     int              `json:"notes_merged"`
	BlobsDownloaded int              `json:"blobs_downloaded"`
	BlobsUploaded   int              `json:"blobs_uploaded"`
	Peers           []PeerSyncStatus `json:"peers,omitempty"`
	Errors          []string         `json:"errors,omitempty"`
}

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewULID generates a lexicographically sortable 26-char ULID.
func NewULID() string {
	return NewULIDAt(time.Now().UnixMilli())
}

// NewULIDAt generates a ULID with a specific millisecond timestamp.
func NewULIDAt(ms int64) string {
	var b [16]byte
	if ms < 0 {
		ms = 0
	}
	u := uint64(ms)
	b[0] = byte(u >> 40)
	b[1] = byte(u >> 32)
	b[2] = byte(u >> 24)
	b[3] = byte(u >> 16)
	b[4] = byte(u >> 8)
	b[5] = byte(u)
	_, _ = rand.Read(b[6:])

	var out [26]byte
	// 48-bit timestamp -> 10 chars
	out[0] = crockford[(b[0]&224)>>5]
	out[1] = crockford[b[0]&31]
	out[2] = crockford[(b[1]&248)>>3]
	out[3] = crockford[((b[1]&7)<<2)|((b[2]&192)>>6)]
	out[4] = crockford[(b[2]&62)>>1]
	out[5] = crockford[((b[2]&1)<<4)|((b[3]&240)>>4)]
	out[6] = crockford[((b[3]&15)<<1)|((b[4]&128)>>7)]
	out[7] = crockford[(b[4]&124)>>2]
	out[8] = crockford[((b[4]&3)<<3)|((b[5]&224)>>5)]
	out[9] = crockford[b[5]&31]

	// 80-bit entropy -> 16 chars
	hi := binary.BigEndian.Uint64(b[6:14])
	lo := uint16(b[14])<<8 | uint16(b[15])
	out[10] = crockford[(hi>>59)&31]
	out[11] = crockford[(hi>>54)&31]
	out[12] = crockford[(hi>>49)&31]
	out[13] = crockford[(hi>>44)&31]
	out[14] = crockford[(hi>>39)&31]
	out[15] = crockford[(hi>>34)&31]
	out[16] = crockford[(hi>>29)&31]
	out[17] = crockford[(hi>>24)&31]
	out[18] = crockford[(hi>>19)&31]
	out[19] = crockford[(hi>>14)&31]
	out[20] = crockford[(hi>>9)&31]
	out[21] = crockford[(hi>>4)&31]
	out[22] = crockford[((hi&15)<<1)|uint64((lo>>15)&1)]
	out[23] = crockford[(lo>>10)&31]
	out[24] = crockford[(lo>>5)&31]
	out[25] = crockford[lo&31]
	return string(out[:])
}
