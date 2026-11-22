package engine

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"whim/core/export"
	"whim/core/model"
	"whim/core/store"
	whimsync "whim/core/sync"
)

const (
	metaPeerID      = "whim.peer_id"
	metaPairCode    = "whim.pair_code"
	metaManualAddrs = "whim.manual_addrs"
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
	if pairCode == "" {
		pairCode = whimsync.GenerateCode()
		if err := st.SetMeta(metaPairCode, pairCode); err != nil {
			_ = st.Close()
			return nil, err
		}
	}

	peer := whimsync.NewPeer(st, peerID, displayName, pairCode)
	if rawManual, _ := st.GetMeta(metaManualAddrs); rawManual != "" {
		var addrs []string
		if json.Unmarshal([]byte(rawManual), &addrs) == nil {
			peer.SetManualAddrs(addrs)
		}
	}

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

// CreateNoteWithImages saves image blobs (if any) and inserts a new note.
type ImageInput struct {
	Data   []byte
	MIME   string
	Width  int
	Height int
}

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

// SetPairCode persists and applies a new 6-digit pairing code.
func (e *Engine) SetPairCode(code string) (string, error) {
	norm := whimsync.NormalizeCode(code)
	if len(norm) != 6 {
		return "", errors.New("pairing code must be 6 digits")
	}
	if err := e.Store.SetMeta(metaPairCode, norm); err != nil {
		return "", err
	}
	e.Peer.SetPairCode(norm)
	return norm, nil
}

// RegeneratePairCode creates and persists a fresh 6-digit pairing code.
func (e *Engine) RegeneratePairCode() (string, error) {
	return e.SetPairCode(whimsync.GenerateCode())
}

// SetManualPeers persists fallback host:port addresses.
func (e *Engine) SetManualPeers(addrs []string) error {
	b, err := json.Marshal(addrs)
	if err != nil {
		return err
	}
	if err := e.Store.SetMeta(metaManualAddrs, string(b)); err != nil {
		return err
	}
	e.Peer.SetManualAddrs(addrs)
	return nil
}

// ExportMarkdown exports notes to Markdown files under outDir.
func (e *Engine) ExportMarkdown(f model.ListFilter, outDir string) (*export.Result, error) {
	return export.Markdown(e.Store, f, outDir)
}

// SyncOnce runs a single LAN discovery + bidirectional sync pass.
func (e *Engine) SyncOnce(timeoutSec int) model.SyncSummary {
	if timeoutSec <= 0 {
		timeoutSec = 10
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSec)*time.Second)
	defer cancel()
	return e.Peer.SyncOnce(ctx)
}
