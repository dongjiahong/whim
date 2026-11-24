package engine

import (
	"context"
	"encoding/json"
	"errors"
	"runtime"
	"strings"
	"time"

	"whim/core/export"
	"whim/core/model"
	"whim/core/store"
	whimsync "whim/core/sync"
)

const (
	metaPeerID   = "whim.peer_id"
	metaPairCode = "whim.pair_code"
)

// Engine is the high-level unified facade shared by Android (gomobile),
// macOS (cbridge), and the local MCP server.
type Engine struct {
	Store *store.Store
	Peer  *whimsync.Peer
}

// Open opens or initializes a Whim engine at dataDir.
func Open(dataDir, displayName string) (*Engine, error) {
	st, err := store.Open(dataDir)
	if err != nil {
		return nil, err
	}

	peerID, err := st.GetMeta(metaPeerID)
	if err != nil {
		_ = st.Close()
		return nil, err
	}
	if peerID == "" {
		peerID = model.NewULID()
		if err := st.SetMeta(metaPeerID, peerID); err != nil {
			_ = st.Close()
			return nil, err
		}
	}

	pairCode, err := st.GetMeta(metaPairCode)
	if err != nil {
		_ = st.Close()
		return nil, err
	}
	// Mirror Navigator: desktop hosts generate a 6-digit code automatically,
	// while phones start empty until they enter the Mac's 6-digit code.
	if pairCode == "" && runtime.GOOS != "android" {
		pairCode = whimsync.GenerateCode()
		if err := st.SetMeta(metaPairCode, pairCode); err != nil {
			_ = st.Close()
			return nil, err
		}
	}

	peer := whimsync.NewPeer(st, peerID, displayName, pairCode)

	return &Engine{
		Store: st,
		Peer:  peer,
	}, nil
}

// Close shuts down networking and closes SQLite cleanly.
func (e *Engine) Close() error {
	if e.Peer != nil {
		_ = e.Peer.StopServer()
	}
	if e.Store != nil {
		return e.Store.Close()
	}
	return nil
}

// ImageInput describes a raw image passed in for saving.
type ImageInput struct {
	Data   []byte
	MIME   string
	Width  int
	Height int
}

// CreateNoteWithImages saves image blobs (if any) and inserts a new note.
func (e *Engine) CreateNoteWithImages(content string, images []ImageInput) (*model.Note, error) {
	var atts []model.Attachment
	for _, img := range images {
		if len(img.Data) == 0 {
			continue
		}
		hash, _, size, err := e.Store.SaveBlob(img.Data, img.MIME)
		if err != nil {
			return nil, err
		}
		atts = append(atts, model.Attachment{
			SHA256:    hash,
			MIME:      img.MIME,
			Width:     img.Width,
			Height:    img.Height,
			SizeBytes: size,
		})
	}
	if strings.TrimSpace(content) == "" && len(atts) == 0 {
		return nil, errors.New("note cannot be empty")
	}
	return e.Store.CreateNote(content, atts)
}

// CountTodayNotes returns the number of active notes created today in local time.
func (e *Engine) CountTodayNotes() (int, error) {
	now := time.Now()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	end := start.Add(24*time.Hour - time.Millisecond)
	return e.Store.CountNotesInRange(start.UnixMilli(), end.UnixMilli())
}

// ListTodayNotes returns active notes created today in local time.
func (e *Engine) ListTodayNotes() ([]model.Note, error) {
	now := time.Now()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	end := start.Add(24*time.Hour - time.Millisecond)
	return e.Store.ListNotes(model.ListFilter{
		DateFromMs:      start.UnixMilli(),
		DateToMs:        end.UnixMilli(),
		IncludeArchived: true,
		Limit:           200,
	})
}

// SetPairCode adopts the 6-digit pairing code of your note library (so all devices share one code).
func (e *Engine) SetPairCode(code string) (string, error) {
	norm := whimsync.NormalizeCode(code)
	if len(norm) != 6 {
		return "", errors.New("配对码必须是 6 位数字")
	}
	if err := e.Store.SetMeta(metaPairCode, norm); err != nil {
		return "", err
	}
	e.Peer.SetPairCode(norm)
	return norm, nil
}

// RegeneratePairCode generates a fresh random 6-digit sync code for THIS device.
func (e *Engine) RegeneratePairCode() (string, error) {
	return e.SetPairCode(whimsync.GenerateCode())
}

// SetManualPeers persists optional fallback host:port addresses when UDP broadcast is blocked.
func (e *Engine) SetManualPeers(addrs []string) error {
	clean := make([]string, 0, len(addrs))
	for _, a := range addrs {
		a = strings.TrimSpace(a)
		if a != "" {
			clean = append(clean, a)
		}
	}
	b, err := json.Marshal(clean)
	if err != nil {
		return err
	}
	return e.Store.SetMeta("whim.manual_addrs", string(b))
}

// DiscoverLAN scans the local network for nearby Whim devices.
func (e *Engine) DiscoverLAN() ([]model.DiscoveredPeerInfo, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return e.Peer.DiscoverLAN(ctx)
}

// PairAndSync connects to a remote device using THAT device's 6-digit code and saves it.
func (e *Engine) PairAndSync(addr, remoteCode string) (model.SyncSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return e.Peer.PairAndSync(ctx, addr, remoteCode)
}

// ListPairedPeers lists all paired remote devices.
func (e *Engine) ListPairedPeers() ([]model.SyncPeer, error) {
	return e.Store.ListSyncPeers()
}

// RemovePairedPeer bidirectionally unpairs a remote device and stops all reconnect attempts.
func (e *Engine) RemovePairedPeer(peerID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	return e.Peer.UnpairPeer(ctx, peerID)
}

// ExportMarkdown exports notes to Markdown files under outDir.
func (e *Engine) ExportMarkdown(f model.ListFilter, outDir string) (*export.Result, error) {
	return export.Markdown(e.Store, f, outDir)
}

// SyncOnce runs a single LAN discovery + bidirectional sync pass across all paired peers.
func (e *Engine) SyncOnce(timeoutSec int) model.SyncSummary {
	if timeoutSec <= 0 {
		timeoutSec = 10
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSec)*time.Second)
	defer cancel()
	return e.Peer.SyncOnce(ctx)
}

// CheckSyncHealth verifies real-time bidirectional connectivity via ping/pong.
func (e *Engine) CheckSyncHealth(activeProbe bool) model.SyncHealthStatus {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	return e.Peer.CheckSyncHealth(ctx, activeProbe)
}
