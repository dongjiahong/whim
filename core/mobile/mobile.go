package mobile

import (
	"encoding/json"
	"errors"
	"sync"

	"whim/core/engine"
	"whim/core/model"
	whimsync "whim/core/sync"
)

var (
	mu  sync.Mutex
	eng *engine.Engine
)

// Init opens the local SQLite database and initializes the Whim core engine.
func Init(dataDir, displayName string) error {
	mu.Lock()
	defer mu.Unlock()
	if eng != nil {
		return nil
	}
	e, err := engine.Open(dataDir, displayName)
	if err != nil {
		return err
	}
	eng = e
	return nil
}

// Close shuts down networking and closes SQLite.
func Close() error {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		return nil
	}
	err := eng.Close()
	eng = nil
	return err
}

func requireEngine() (*engine.Engine, error) {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		return nil, errors.New("whim core not initialized")
	}
	return eng, nil
}

// SaveBlob saves raw image bytes and returns JSON {"sha256":..., "local_path":..., "size_bytes":...}.
func SaveBlob(data []byte, mime string) (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	hash, path, size, err := e.Store.SaveBlob(data, mime)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(map[string]any{
		"sha256":     hash,
		"local_path": path,
		"size_bytes": size,
		"mime":       mime,
	})
	return string(b), err
}

// CreateNote creates a new note. attachmentsJSON is optional JSON array of model.Attachment.
func CreateNote(content, attachmentsJSON string) (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	var atts []model.Attachment
	if attachmentsJSON != "" && attachmentsJSON != "[]" {
		if err := json.Unmarshal([]byte(attachmentsJSON), &atts); err != nil {
			return "", err
		}
	}
	note, err := e.Store.CreateNote(content, atts)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(note)
	return string(b), err
}

// UpdateNote updates note fields; pass empty/unchanged via JSON payload:
// {"id":"...", "content":"...", "pinned":true, "archived":false, "deleted":false, "attachments":[...]}
func UpdateNote(patchJSON string) (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	var p struct {
		ID          string             `json:"id"`
		Content     *string            `json:"content"`
		Pinned      *bool              `json:"pinned"`
		Archived    *bool              `json:"archived"`
		Deleted     *bool              `json:"deleted"`
		Attachments []model.Attachment `json:"attachments"`
	}
	if err := json.Unmarshal([]byte(patchJSON), &p); err != nil {
		return "", err
	}
	note, err := e.Store.UpdateNoteWithAttachments(p.ID, p.Content, p.Pinned, p.Archived, p.Deleted, p.Attachments)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(note)
	return string(b), err
}

// ListNotes queries notes with optional JSON model.ListFilter and returns JSON array.
func ListNotes(filterJSON string) (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	var f model.ListFilter
	if filterJSON != "" {
		if err := json.Unmarshal([]byte(filterJSON), &f); err != nil {
			return "", err
		}
	}
	notes, err := e.Store.ListNotes(f)
	if err != nil {
		return "", err
	}
	if notes == nil {
		notes = []model.Note{}
	}
	b, err := json.Marshal(notes)
	return string(b), err
}

// ListTodayNotes returns today's notes as JSON array (for Daily Review).
func ListTodayNotes() (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	notes, err := e.ListTodayNotes()
	if err != nil {
		return "", err
	}
	if notes == nil {
		notes = []model.Note{}
	}
	b, err := json.Marshal(notes)
	return string(b), err
}

// CountTodayNotes returns the number of active notes created today.
func CountTodayNotes() (int, error) {
	e, err := requireEngine()
	if err != nil {
		return 0, err
	}
	return e.CountTodayNotes()
}

// ListTagTree returns the hierarchical tag tree as JSON array.
func ListTagTree() (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	tree, err := e.Store.ListTagTree()
	if err != nil {
		return "", err
	}
	if tree == nil {
		tree = []model.TagNode{}
	}
	b, err := json.Marshal(tree)
	return string(b), err
}

// StartPeerServer starts the local HTTP + UDP discovery peer server (idempotent).
func StartPeerServer(port int) (int, error) {
	e, err := requireEngine()
	if err != nil {
		return 0, err
	}
	if port <= 0 {
		port = whimsync.DefaultHTTPPort
	}
	return e.Peer.StartServer(port, true)
}

// StopPeerServer stops the local peer server.
func StopPeerServer() error {
	e, err := requireEngine()
	if err != nil {
		return err
	}
	return e.Peer.StopServer()
}

// SyncOnce runs a single LAN discovery + bidirectional sync pass across all paired peers.
func SyncOnce(timeoutSec int) (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	summary := e.SyncOnce(timeoutSec)
	b, err := json.Marshal(summary)
	return string(b), err
}

// GetPairCode returns THIS device's own 6-digit sync code (never overwritten by pairing with other devices).
func GetPairCode() (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	return e.Peer.PairCode(), nil
}

// RegeneratePairCode generates a fresh random 6-digit sync code for THIS device.
func RegeneratePairCode() (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	return e.RegeneratePairCode()
}

// DiscoverLAN scans the local Wi-Fi network and returns JSON array of DiscoveredPeerInfo.
func DiscoverLAN() (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	peers, err := e.DiscoverLAN()
	if err != nil {
		return "", err
	}
	if peers == nil {
		peers = []model.DiscoveredPeerInfo{}
	}
	b, err := json.Marshal(peers)
	return string(b), err
}

// PairAndSync pairs with a remote peer using THAT peer's 6-digit code and saves it.
func PairAndSync(addr, remoteCode string) (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	res, err := e.PairAndSync(addr, remoteCode)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(res)
	return string(b), err
}

// ListPairedPeers returns JSON array of already paired remote devices.
func ListPairedPeers() (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	peers, err := e.ListPairedPeers()
	if err != nil {
		return "", err
	}
	if peers == nil {
		peers = []model.SyncPeer{}
	}
	b, err := json.Marshal(peers)
	return string(b), err
}

// RemovePairedPeer removes a paired remote device by peerID.
func RemovePairedPeer(peerID string) error {
	e, err := requireEngine()
	if err != nil {
		return err
	}
	return e.RemovePairedPeer(peerID)
}

// ExportMarkdown exports matching notes to outDir and returns JSON export.Result.
func ExportMarkdown(filterJSON, outDir string) (string, error) {
	e, err := requireEngine()
	if err != nil {
		return "", err
	}
	var f model.ListFilter
	if filterJSON != "" {
		if err := json.Unmarshal([]byte(filterJSON), &f); err != nil {
			return "", err
		}
	}
	res, err := e.ExportMarkdown(f, outDir)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(res)
	return string(b), err
}
