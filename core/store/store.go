package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	_ "modernc.org/sqlite"

	"whim/core/model"
	"whim/core/tags"
)

// Store manages the local SQLite database and content-addressed image blobs.
type Store struct {
	mu              sync.RWMutex
	db              *sql.DB
	dataDir         string
	blobsDir        string
	ftsTrigramReady bool
}

// Open initializes or opens the SQLite database under dataDir/whim.sqlite3.
func Open(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create dataDir: %w", err)
	}
	blobsDir := filepath.Join(dataDir, "blobs")
	if err := os.MkdirAll(blobsDir, 0o755); err != nil {
		return nil, fmt.Errorf("create blobsDir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "whim.sqlite3")
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)", dbPath)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)

	s := &Store{
		db:       db,
		dataDir:  dataDir,
		blobsDir: blobsDir,
	}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// Close closes the underlying database.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

// DataDir returns the store's root data directory.
func (s *Store) DataDir() string {
	return s.dataDir
}

func (s *Store) migrate() error {
	const schema = `
CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (
	id          TEXT PRIMARY KEY,
	content     TEXT NOT NULL DEFAULT '',
	pinned      INTEGER NOT NULL DEFAULT 0,
	archived    INTEGER NOT NULL DEFAULT 0,
	deleted     INTEGER NOT NULL DEFAULT 0,
	created_at  INTEGER NOT NULL,
	updated_at  INTEGER NOT NULL,
	stamps_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at);
CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at);
CREATE INDEX IF NOT EXISTS idx_notes_feed ON notes(deleted, archived, pinned DESC, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_notes_deleted_created ON notes(deleted, created_at);

CREATE TABLE IF NOT EXISTS note_tags (
	note_id  TEXT NOT NULL,
	tag_path TEXT NOT NULL,
	PRIMARY KEY (note_id, tag_path)
);
CREATE INDEX IF NOT EXISTS idx_note_tags_path ON note_tags(tag_path);

CREATE TABLE IF NOT EXISTS note_attachments (
	id         TEXT PRIMARY KEY,
	note_id    TEXT NOT NULL,
	sha256     TEXT NOT NULL,
	mime       TEXT NOT NULL,
	width      INTEGER NOT NULL DEFAULT 0,
	height     INTEGER NOT NULL DEFAULT 0,
	size_bytes INTEGER NOT NULL DEFAULT 0,
	sort_order INTEGER NOT NULL DEFAULT 0,
	deleted    INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_attachments_note ON note_attachments(note_id);
CREATE INDEX IF NOT EXISTS idx_attachments_sha  ON note_attachments(sha256);

CREATE TABLE IF NOT EXISTS sync_peers (
	peer_id       TEXT PRIMARY KEY,
	display_name  TEXT NOT NULL DEFAULT '',
	last_addr     TEXT NOT NULL DEFAULT '',
	pair_code     TEXT NOT NULL DEFAULT '',
	last_heard_at INTEGER NOT NULL DEFAULT 0,
	last_sync_at  INTEGER NOT NULL DEFAULT 0
);

CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
	note_id UNINDEXED,
	content,
	tokenize = 'unicode61'
);
`
	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	_, _ = s.db.Exec(`ALTER TABLE sync_peers ADD COLUMN pair_code TEXT NOT NULL DEFAULT ''`)
	s.ensureTrigramFTS()
	return nil
}

func (s *Store) ensureTrigramFTS() {
	var ver string
	_ = s.db.QueryRow(`SELECT value FROM meta WHERE key = 'whim.fts_version'`).Scan(&ver)
	if ver == "trigram_v1" {
		s.ftsTrigramReady = true
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		return
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`DROP TABLE IF EXISTS notes_fts`); err != nil {
		return
	}
	if _, err := tx.Exec(`CREATE VIRTUAL TABLE notes_fts USING fts5(note_id UNINDEXED, content, tokenize = 'trigram')`); err != nil {
		return
	}
	if _, err := tx.Exec(`INSERT INTO notes_fts(note_id, content) SELECT id, content FROM notes WHERE deleted = 0`); err != nil {
		return
	}
	if _, err := tx.Exec(`INSERT INTO meta(key, value) VALUES('whim.fts_version', 'trigram_v1') ON CONFLICT(key) DO UPDATE SET value=excluded.value`); err != nil {
		return
	}
	if err := tx.Commit(); err == nil {
		s.ftsTrigramReady = true
	}
}

func quoteFTSPhrase(q string) string {
	return `"` + strings.ReplaceAll(q, `"`, `""`) + `"`
}

// GetMeta retrieves a local key-value setting.
func (s *Store) GetMeta(key string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var val string
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = ?`, key).Scan(&val)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return val, err
}

// SetMeta stores a local key-value setting.
func (s *Store) SetMeta(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, key, value)
	return err
}

// SaveBlob stores binary image data content-addressed by SHA-256 and returns (sha256, localPath, size).
func (s *Store) SaveBlob(data []byte, mime string) (string, string, int64, error) {
	if len(data) == 0 {
		return "", "", 0, errors.New("empty blob data")
	}
	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])
	ext := extFromMIME(mime)
	path := filepath.Join(s.blobsDir, hash+ext)
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, data, 0o644); err != nil {
			return "", "", 0, err
		}
		if err := os.Rename(tmp, path); err != nil {
			_ = os.Remove(tmp)
			return "", "", 0, err
		}
	}
	return hash, path, int64(len(data)), nil
}

// BlobPathWithMIME locates an existing blob file directly via its MIME extension (O(1) stat),
// falling back to BlobPath only if the expected extension does not exist.
func (s *Store) BlobPathWithMIME(hash, mime string) (string, bool) {
	if len(hash) != 64 {
		return "", false
	}
	if mime != "" {
		candidate := filepath.Join(s.blobsDir, hash+extFromMIME(mime))
		if _, err := os.Stat(candidate); err == nil {
			return candidate, true
		}
	}
	return s.BlobPath(hash)
}

// BlobPath locates an existing blob file on disk by its SHA-256 hash.
func (s *Store) BlobPath(hash string) (string, bool) {
	if len(hash) != 64 {
		return "", false
	}
	for _, ext := range []string{".png", ".jpg", ".webp", ".gif", ".heic", ".jpeg", ".bin", ""} {
		candidate := filepath.Join(s.blobsDir, hash+ext)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, true
		}
	}
	matches, err := filepath.Glob(filepath.Join(s.blobsDir, hash+".*"))
	if err == nil && len(matches) > 0 {
		return matches[0], true
	}
	return "", false
}

// ReadBlob returns the raw bytes of a stored blob.
func (s *Store) ReadBlob(hash string) ([]byte, string, error) {
	path, ok := s.BlobPath(hash)
	if !ok {
		return nil, "", os.ErrNotExist
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	return b, mimeFromExt(filepath.Ext(path)), nil
}

// ListLocalBlobs returns all SHA-256 hashes present in blobsDir.
func (s *Store) ListLocalBlobs() ([]string, error) {
	entries, err := os.ReadDir(s.blobsDir)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || strings.HasSuffix(e.Name(), ".tmp") {
			continue
		}
		name := e.Name()
		if dot := strings.IndexByte(name, '.'); dot > 0 {
			name = name[:dot]
		}
		if len(name) == 64 {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out, nil
}

var blobRefRegex = regexp.MustCompile(`!\[[^\]]*\]\(whim://blob/([a-fA-F0-9]{64})\)`)

func extractReferencedBlobs(content string) map[string]bool {
	matches := blobRefRegex.FindAllStringSubmatch(content, -1)
	if len(matches) == 0 {
		return nil
	}
	out := make(map[string]bool, len(matches))
	for _, m := range matches {
		if len(m) >= 2 {
			out[strings.ToLower(m[1])] = true
		}
	}
	return out
}

// MissingBlobs returns SHA-256 hashes referenced by active attachments on active notes that do not exist locally.
func (s *Store) MissingBlobs() ([]string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`
		SELECT DISTINCT na.sha256
		FROM note_attachments na
		JOIN notes n ON n.id = na.note_id
		WHERE na.deleted = 0 AND n.deleted = 0`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var missing []string
	for rows.Next() {
		var h string
		if err := rows.Scan(&h); err != nil {
			return nil, err
		}
		if _, ok := s.BlobPath(h); !ok {
			missing = append(missing, h)
		}
	}
	sort.Strings(missing)
	return missing, nil
}

// CleanupOrphanBlobs scans blobsDir for image files not referenced by any active note.
// When dryRun is true it only reports counts/bytes without deleting anything.
// minAgeSec protects recently pasted blobs that may belong to an unsent draft.
func (s *Store) CleanupOrphanBlobs(minAgeSec int, dryRun bool) (*model.StorageCleanupResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	active := make(map[string]bool)
	rows, err := s.db.Query(`
		SELECT DISTINCT LOWER(na.sha256)
		FROM note_attachments na
		JOIN notes n ON n.id = na.note_id
		WHERE na.deleted = 0 AND n.deleted = 0`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var h string
		if err := rows.Scan(&h); err == nil && len(h) == 64 {
			active[h] = true
		}
	}
	rows.Close()

	// Belt-and-suspenders: also keep any blob referenced inline in active note markdown.
	nRows, err := s.db.Query(`SELECT content FROM notes WHERE deleted = 0 AND content LIKE '%whim://blob/%'`)
	if err == nil {
		for nRows.Next() {
			var c string
			if err := nRows.Scan(&c); err == nil {
				for h := range extractReferencedBlobs(c) {
					active[h] = true
				}
			}
		}
		nRows.Close()
	}

	entries, err := os.ReadDir(s.blobsDir)
	if err != nil {
		return nil, err
	}
	res := &model.StorageCleanupResult{}
	cutoff := time.Now().Add(-time.Duration(minAgeSec) * time.Second)
	for _, e := range entries {
		if e.IsDir() || strings.HasSuffix(e.Name(), ".tmp") {
			continue
		}
		name := e.Name()
		hash := name
		if dot := strings.IndexByte(name, '.'); dot > 0 {
			hash = name[:dot]
		}
		hash = strings.ToLower(hash)
		if len(hash) != 64 || active[hash] {
			continue
		}
		info, ierr := e.Info()
		if ierr != nil {
			continue
		}
		if minAgeSec > 0 && info.ModTime().After(cutoff) {
			continue
		}
		if !dryRun {
			if rerr := os.Remove(filepath.Join(s.blobsDir, name)); rerr != nil && !errors.Is(rerr, os.ErrNotExist) {
				continue
			}
		}
		res.RemovedFiles++
		res.FreedBytes += info.Size()
	}
	if !dryRun {
		_, _ = s.db.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
	}
	return res, nil
}

// CreateNote creates a new note with optional pre-saved attachments.
func (s *Store) CreateNote(content string, attachments []model.Attachment) (*model.Note, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now().UnixMilli()
	id := model.NewULIDAt(now)
	stamps := model.FieldStamps{
		Content:     now,
		Pinned:      now,
		Archived:    now,
		Deleted:     now,
		Attachments: now,
	}
	note := &model.Note{
		ID:        id,
		Content:   content,
		Tags:      tags.Extract(content),
		CreatedAt: now,
		UpdatedAt: now,
		Stamps:    stamps,
	}

	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if err := s.upsertNoteTx(tx, note); err != nil {
		return nil, err
	}
	for i := range attachments {
		att := attachments[i]
		if att.ID == "" {
			att.ID = model.NewULIDAt(now)
		}
		att.NoteID = id
		att.SortOrder = i
		att.UpdatedAt = now
		if err := s.upsertAttachmentTx(tx, &att); err != nil {
			return nil, err
		}
		if p, ok := s.BlobPath(att.SHA256); ok {
			att.LocalPath = p
		}
		note.Attachments = append(note.Attachments, att)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return note, nil
}

// UpdateNote updates mutable fields of an existing note and advances only touched field stamps.
func (s *Store) UpdateNote(id string, content *string, pinned *bool, archived *bool, deleted *bool) (*model.Note, error) {
	return s.UpdateNoteWithAttachments(id, content, pinned, archived, deleted, nil)
}

// UpdateNoteWithAttachments updates mutable fields, appends newly pasted attachments,
// and soft-deletes (or restores on undo) attachments removed from content or deleted notes.
func (s *Store) UpdateNoteWithAttachments(id string, content *string, pinned *bool, archived *bool, deleted *bool, newAttachments []model.Attachment) (*model.Note, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, err := s.getNoteLocked(id)
	if err != nil {
		return nil, err
	}
	now := time.Now().UnixMilli()
	if now <= existing.UpdatedAt {
		now = existing.UpdatedAt + 1
	}

	contentChanged := false
	if content != nil && *content != existing.Content {
		existing.Content = *content
		existing.Stamps.Content = now
		contentChanged = true
	}
	if pinned != nil && *pinned != existing.Pinned {
		existing.Pinned = *pinned
		existing.Stamps.Pinned = now
	}
	if archived != nil && *archived != existing.Archived {
		existing.Archived = *archived
		existing.Stamps.Archived = now
	}
	deletedChanged := false
	if deleted != nil && *deleted != existing.Deleted {
		existing.Deleted = *deleted
		existing.Stamps.Deleted = now
		deletedChanged = true
	}
	if len(newAttachments) > 0 || deletedChanged || contentChanged {
		existing.Stamps.Attachments = now
	}
	existing.UpdatedAt = existing.Stamps.Max()
	existing.Tags = tags.Extract(existing.Content)

	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if err := s.upsertNoteTx(tx, existing); err != nil {
		return nil, err
	}

	// 1. If the note itself was soft-deleted or restored (undo), cascade to its attachments.
	if deletedChanged {
		if existing.Deleted {
			if _, err := tx.Exec(`UPDATE note_attachments SET deleted = 1, updated_at = ? WHERE note_id = ? AND deleted = 0`, now, existing.ID); err != nil {
				return nil, err
			}
			existing.Attachments = nil
		} else {
			refs := extractReferencedBlobs(existing.Content)
			if len(refs) > 0 {
				for h := range refs {
					if _, err := tx.Exec(`UPDATE note_attachments SET deleted = 0, updated_at = ? WHERE note_id = ? AND LOWER(sha256) = ? AND deleted = 1`, now, existing.ID, h); err != nil {
						return nil, err
					}
				}
			} else {
				if _, err := tx.Exec(`UPDATE note_attachments SET deleted = 0, updated_at = ? WHERE note_id = ? AND deleted = 1`, now, existing.ID); err != nil {
					return nil, err
				}
			}
		}
	}

	// 2. If note content was edited, soft-delete any existing attachment no longer referenced in content or newAttachments.
	if content != nil && !existing.Deleted {
		kept := extractReferencedBlobs(*content)
		if kept == nil {
			kept = make(map[string]bool)
		}
		for _, a := range newAttachments {
			if a.SHA256 != "" {
				kept[strings.ToLower(a.SHA256)] = true
			}
		}
		filtered := make([]model.Attachment, 0, len(existing.Attachments))
		for _, a := range existing.Attachments {
			if kept[strings.ToLower(a.SHA256)] {
				filtered = append(filtered, a)
			} else {
				if _, err := tx.Exec(`UPDATE note_attachments SET deleted = 1, updated_at = ? WHERE id = ? AND deleted = 0`, now, a.ID); err != nil {
					return nil, err
				}
			}
		}
		existing.Attachments = filtered
	}

	// 3. Append any newly pasted attachments.
	if len(newAttachments) > 0 && !existing.Deleted {
		knownSHA := make(map[string]bool)
		for _, a := range existing.Attachments {
			knownSHA[strings.ToLower(a.SHA256)] = true
		}
		sortIdx := len(existing.Attachments)
		for _, att := range newAttachments {
			sha := strings.ToLower(att.SHA256)
			if sha == "" || knownSHA[sha] {
				continue
			}
			if att.ID == "" {
				att.ID = model.NewULIDAt(now)
			}
			att.NoteID = existing.ID
			att.SortOrder = sortIdx
			att.UpdatedAt = now
			sortIdx++
			if err := s.upsertAttachmentTx(tx, &att); err != nil {
				return nil, err
			}
			if p, ok := s.BlobPath(att.SHA256); ok {
				att.LocalPath = p
			}
			existing.Attachments = append(existing.Attachments, att)
			knownSHA[sha] = true
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	if deletedChanged && !existing.Deleted {
		if restored, lerr := s.listNoteAttachmentsLocked(existing.ID, false); lerr == nil {
			existing.Attachments = restored
		}
	}
	return existing, nil
}

// GetNote fetches a single note by ID.
func (s *Store) GetNote(id string) (*model.Note, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.getNoteLocked(id)
}

func (s *Store) getNoteLocked(id string) (*model.Note, error) {
	var n model.Note
	var pinned, archived, deleted int
	var stampsRaw string
	err := s.db.QueryRow(
		`SELECT id, content, pinned, archived, deleted, created_at, updated_at, stamps_json FROM notes WHERE id = ?`,
		id,
	).Scan(&n.ID, &n.Content, &pinned, &archived, &deleted, &n.CreatedAt, &n.UpdatedAt, &stampsRaw)
	if err != nil {
		return nil, err
	}
	n.Pinned = pinned != 0
	n.Archived = archived != 0
	n.Deleted = deleted != 0
	_ = json.Unmarshal([]byte(stampsRaw), &n.Stamps)
	n.Tags = tags.Extract(n.Content)
	atts, err := s.listNoteAttachmentsLocked(n.ID, false)
	if err != nil {
		return nil, err
	}
	n.Attachments = atts
	return &n, nil
}

// ListNotes queries active notes matching the given filter.
func (s *Store) ListNotes(f model.ListFilter) ([]model.Note, error) {
	page, err := s.ListNotesPage(f)
	if err != nil {
		return nil, err
	}
	return page.Notes, nil
}

// ListNotesPage queries notes with keyset cursor pagination (or offset fallback) and batch-loaded attachments.
func (s *Store) ListNotesPage(f model.ListFilter) (*model.NotePage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var where []string
	var args []any
	where = append(where, "n.deleted = 0")

	if f.OnlyArchived {
		where = append(where, "n.archived = 1")
	} else if !f.IncludeArchived {
		where = append(where, "n.archived = 0")
	}
	if f.OnlyPinned {
		where = append(where, "n.pinned = 1")
	}
	if f.DateFromMs > 0 {
		where = append(where, "n.created_at >= ?")
		args = append(args, f.DateFromMs)
	}
	if f.DateToMs > 0 {
		where = append(where, "n.created_at <= ?")
		args = append(args, f.DateToMs)
	}
	if tp := tags.Normalize(f.TagPrefix); tp != "" {
		where = append(where, "EXISTS (SELECT 1 FROM note_tags nt WHERE nt.note_id = n.id AND (nt.tag_path = ? OR nt.tag_path LIKE ?))")
		args = append(args, tp, tp+"/%")
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		if s.ftsTrigramReady && utf8.RuneCountInString(q) >= 3 {
			where = append(where, "EXISTS (SELECT 1 FROM notes_fts f WHERE f.note_id = n.id AND f.content MATCH ?)")
			args = append(args, quoteFTSPhrase(q))
		} else {
			where = append(where, "n.content LIKE ?")
			args = append(args, "%"+q+"%")
		}
	}

	useCursor := f.Cursor != nil && f.Cursor.ID != ""
	if useCursor {
		cp := boolInt(f.Cursor.Pinned)
		where = append(where, "(n.pinned < ? OR (n.pinned = ? AND (n.created_at < ? OR (n.created_at = ? AND n.id < ?))))")
		args = append(args, cp, cp, f.Cursor.CreatedAt, f.Cursor.CreatedAt, f.Cursor.ID)
	}

	limit := f.Limit
	if limit <= 0 {
		limit = 50
	} else if limit > 500 {
		limit = 500
	}
	offset := f.Offset
	if offset < 0 || useCursor {
		offset = 0
	}

	query := fmt.Sprintf(`
		SELECT n.id, n.content, n.pinned, n.archived, n.deleted, n.created_at, n.updated_at, n.stamps_json
		FROM notes n
		WHERE %s
		ORDER BY n.pinned DESC, n.created_at DESC, n.id DESC
		LIMIT ? OFFSET ?`, strings.Join(where, " AND "))
	args = append(args, limit+1, offset)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	notes := make([]model.Note, 0, limit)
	for rows.Next() {
		var n model.Note
		var pinned, archived, deleted int
		var stampsRaw string
		if err := rows.Scan(&n.ID, &n.Content, &pinned, &archived, &deleted, &n.CreatedAt, &n.UpdatedAt, &stampsRaw); err != nil {
			return nil, err
		}
		n.Pinned = pinned != 0
		n.Archived = archived != 0
		n.Deleted = deleted != 0
		_ = json.Unmarshal([]byte(stampsRaw), &n.Stamps)
		n.Tags = tags.Extract(n.Content)
		notes = append(notes, n)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	hasMore := false
	if len(notes) > limit {
		hasMore = true
		notes = notes[:limit]
	}

	if err := s.attachBatchLocked(notes); err != nil {
		return nil, err
	}

	var nextCursor *model.NoteCursor
	if hasMore && len(notes) > 0 {
		last := notes[len(notes)-1]
		nextCursor = &model.NoteCursor{
			Pinned:    last.Pinned,
			CreatedAt: last.CreatedAt,
			ID:        last.ID,
		}
	}

	return &model.NotePage{
		Notes:      notes,
		HasMore:    hasMore,
		NextCursor: nextCursor,
	}, nil
}

// GetStats computes sidebar totals and recent daily heatmap counts directly in SQL.
func (s *Store) GetStats(days int) (*model.Stats, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if days <= 0 {
		days = 90
	}
	stats := &model.Stats{
		ActiveDays:  1,
		DailyCounts: make(map[string]int),
	}

	if err := s.db.QueryRow(`SELECT COUNT(1) FROM notes WHERE deleted = 0 AND archived = 0`).Scan(&stats.TotalNotes); err != nil {
		return nil, err
	}
	if err := s.db.QueryRow(`
		SELECT COUNT(DISTINCT nt.tag_path)
		FROM note_tags nt
		JOIN notes n ON n.id = nt.note_id
		WHERE n.deleted = 0 AND n.archived = 0`).Scan(&stats.TotalTags); err != nil {
		return nil, err
	}

	var earliest sql.NullInt64
	if err := s.db.QueryRow(`SELECT MIN(created_at) FROM notes WHERE deleted = 0 AND archived = 0 AND created_at > 0`).Scan(&earliest); err != nil {
		return nil, err
	}
	if earliest.Valid && earliest.Int64 > 0 {
		now := time.Now()
		startDay := time.UnixMilli(earliest.Int64).In(now.Location())
		startMidnight := time.Date(startDay.Year(), startDay.Month(), startDay.Day(), 0, 0, 0, 0, now.Location())
		todayMidnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
		diffDays := int(todayMidnight.Sub(startMidnight)/(24*time.Hour)) + 1
		if diffDays > 1 {
			stats.ActiveDays = diffDays
		}
	}

	now := time.Now()
	cutoff := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).AddDate(0, 0, -(days - 1))
	rows, err := s.db.Query(`SELECT created_at FROM notes WHERE deleted = 0 AND archived = 0 AND created_at >= ?`, cutoff.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var ts int64
		if err := rows.Scan(&ts); err != nil {
			return nil, err
		}
		key := time.UnixMilli(ts).In(now.Location()).Format("2006-01-02")
		stats.DailyCounts[key]++
	}
	return stats, rows.Err()
}

// ListRandomNotes returns up to limit randomly sampled active notes directly from SQLite.
func (s *Store) ListRandomNotes(query string, limit int) ([]model.Note, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if limit <= 0 {
		limit = 10
	} else if limit > 50 {
		limit = 50
	}

	var where []string
	var args []any
	where = append(where, "deleted = 0", "archived = 0")
	if q := strings.TrimSpace(query); q != "" {
		if s.ftsTrigramReady && utf8.RuneCountInString(q) >= 3 {
			where = append(where, "EXISTS (SELECT 1 FROM notes_fts f WHERE f.note_id = notes.id AND f.content MATCH ?)")
			args = append(args, quoteFTSPhrase(q))
		} else {
			where = append(where, "content LIKE ?")
			args = append(args, "%"+q+"%")
		}
	}
	args = append(args, limit)

	sqlStr := fmt.Sprintf(`
		SELECT id, content, pinned, archived, deleted, created_at, updated_at, stamps_json
		FROM notes
		WHERE %s
		ORDER BY RANDOM()
		LIMIT ?`, strings.Join(where, " AND "))

	rows, err := s.db.Query(sqlStr, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	notes := make([]model.Note, 0, limit)
	for rows.Next() {
		var n model.Note
		var pinned, archived, deleted int
		var stampsRaw string
		if err := rows.Scan(&n.ID, &n.Content, &pinned, &archived, &deleted, &n.CreatedAt, &n.UpdatedAt, &stampsRaw); err != nil {
			return nil, err
		}
		n.Pinned = pinned != 0
		n.Archived = archived != 0
		n.Deleted = deleted != 0
		_ = json.Unmarshal([]byte(stampsRaw), &n.Stamps)
		n.Tags = tags.Extract(n.Content)
		notes = append(notes, n)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := s.attachBatchLocked(notes); err != nil {
		return nil, err
	}
	return notes, nil
}

func (s *Store) attachBatchLocked(notes []model.Note) error {
	if len(notes) == 0 {
		return nil
	}
	placeholders := make([]string, len(notes))
	args := make([]any, len(notes))
	idxByID := make(map[string]int, len(notes))
	for i := range notes {
		placeholders[i] = "?"
		args[i] = notes[i].ID
		idxByID[notes[i].ID] = i
	}

	q := fmt.Sprintf(`
		SELECT id, note_id, sha256, mime, width, height, size_bytes, sort_order, deleted, updated_at
		FROM note_attachments
		WHERE deleted = 0 AND note_id IN (%s)
		ORDER BY note_id ASC, sort_order ASC, id ASC`, strings.Join(placeholders, ","))

	rows, err := s.db.Query(q, args...)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var a model.Attachment
		var del int
		if err := rows.Scan(&a.ID, &a.NoteID, &a.SHA256, &a.MIME, &a.Width, &a.Height, &a.SizeBytes, &a.SortOrder, &del, &a.UpdatedAt); err != nil {
			return err
		}
		a.Deleted = del != 0
		if p, ok := s.BlobPathWithMIME(a.SHA256, a.MIME); ok {
			a.LocalPath = p
		}
		if idx, ok := idxByID[a.NoteID]; ok {
			notes[idx].Attachments = append(notes[idx].Attachments, a)
		}
	}
	return rows.Err()
}

// CountNotesInRange counts non-deleted notes created within [fromMs, toMs].
func (s *Store) CountNotesInRange(fromMs, toMs int64) (int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var cnt int
	err := s.db.QueryRow(
		`SELECT COUNT(1) FROM notes WHERE deleted = 0 AND created_at >= ? AND created_at <= ?`,
		fromMs, toMs,
	).Scan(&cnt)
	return cnt, err
}

// ListTagTree returns the hierarchical tag tree for all active notes.
func (s *Store) ListTagTree() ([]model.TagNode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`
		SELECT nt.tag_path, COUNT(DISTINCT nt.note_id)
		FROM note_tags nt
		JOIN notes n ON n.id = nt.note_id
		WHERE n.deleted = 0 AND n.archived = 0
		GROUP BY nt.tag_path`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	counts := make(map[string]int)
	for rows.Next() {
		var p string
		var c int
		if err := rows.Scan(&p, &c); err != nil {
			return nil, err
		}
		counts[p] = c
	}
	return tags.BuildTree(counts), nil
}

// ListChangesSincePaged returns a bounded batch of notes (including tombstones) and attachments
// ordered by (updated_at ASC, id ASC) so initial sync of 10,000+ notes never exceeds payload limits.
func (s *Store) ListChangesSincePaged(sinceMs int64, afterID string, limit int) ([]model.Note, []model.Attachment, int64, string, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if limit <= 0 || limit > 500 {
		limit = 500
	}

	var (nRows *sql.Rows; err error)
	if afterID == "" {
		nRows, err = s.db.Query(`
			SELECT id, content, pinned, archived, deleted, created_at, updated_at, stamps_json
			FROM notes WHERE updated_at >= ? ORDER BY updated_at ASC, id ASC LIMIT ?`, sinceMs, limit+1)
	} else {
		nRows, err = s.db.Query(`
			SELECT id, content, pinned, archived, deleted, created_at, updated_at, stamps_json
			FROM notes WHERE updated_at > ? OR (updated_at = ? AND id > ?) ORDER BY updated_at ASC, id ASC LIMIT ?`,
			sinceMs, sinceMs, afterID, limit+1)
	}
	if err != nil {
		return nil, nil, 0, "", false, err
	}
	defer nRows.Close()

	notes := make([]model.Note, 0, limit)
	for nRows.Next() {
		var n model.Note
		var pinned, archived, deleted int
		var stampsRaw string
		if err := nRows.Scan(&n.ID, &n.Content, &pinned, &archived, &deleted, &n.CreatedAt, &n.UpdatedAt, &stampsRaw); err != nil {
			return nil, nil, 0, "", false, err
		}
		n.Pinned = pinned != 0
		n.Archived = archived != 0
		n.Deleted = deleted != 0
		_ = json.Unmarshal([]byte(stampsRaw), &n.Stamps)
		notes = append(notes, n)
	}
	if err := nRows.Err(); err != nil {
		return nil, nil, 0, "", false, err
	}

	hasMore := false
	var nextSince int64
	var nextAfterID string
	if len(notes) > limit {
		hasMore = true
		notes = notes[:limit]
		last := notes[len(notes)-1]
		nextSince = last.UpdatedAt
		nextAfterID = last.ID
	}

	var atts []model.Attachment
	seenAtt := make(map[string]struct{})
	if len(notes) > 0 {
		placeholders := make([]string, len(notes))
		args := make([]any, len(notes))
		for i := range notes {
			placeholders[i] = "?"
			args[i] = notes[i].ID
		}
		q := fmt.Sprintf(`
			SELECT id, note_id, sha256, mime, width, height, size_bytes, sort_order, deleted, updated_at
			FROM note_attachments WHERE note_id IN (%s) ORDER BY updated_at ASC, id ASC`, strings.Join(placeholders, ","))
		aRows, err := s.db.Query(q, args...)
		if err != nil {
			return nil, nil, 0, "", false, err
		}
		for aRows.Next() {
			var a model.Attachment
			var del int
			if err := aRows.Scan(&a.ID, &a.NoteID, &a.SHA256, &a.MIME, &a.Width, &a.Height, &a.SizeBytes, &a.SortOrder, &del, &a.UpdatedAt); err != nil {
				aRows.Close()
				return nil, nil, 0, "", false, err
			}
			a.Deleted = del != 0
			seenAtt[a.ID] = struct{}{}
			atts = append(atts, a)
		}
		aRows.Close()
	}

	// On the final batch, also include any standalone attachment updates since watermark
	if !hasMore {
		aRows, err := s.db.Query(`
			SELECT id, note_id, sha256, mime, width, height, size_bytes, sort_order, deleted, updated_at
			FROM note_attachments WHERE updated_at >= ? ORDER BY updated_at ASC, id ASC`, sinceMs)
		if err != nil {
			return nil, nil, 0, "", false, err
		}
		defer aRows.Close()
		for aRows.Next() {
			var a model.Attachment
			var del int
			if err := aRows.Scan(&a.ID, &a.NoteID, &a.SHA256, &a.MIME, &a.Width, &a.Height, &a.SizeBytes, &a.SortOrder, &del, &a.UpdatedAt); err != nil {
				return nil, nil, 0, "", false, err
			}
			if _, ok := seenAtt[a.ID]; ok {
				continue
			}
			a.Deleted = del != 0
			atts = append(atts, a)
		}
	}

	return notes, atts, nextSince, nextAfterID, hasMore, nil
}

// ListChangesSince returns all notes (including tombstones) and attachments modified at or after sinceMs.
func (s *Store) ListChangesSince(sinceMs int64) ([]model.Note, []model.Attachment, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	nRows, err := s.db.Query(`
		SELECT id, content, pinned, archived, deleted, created_at, updated_at, stamps_json
		FROM notes WHERE updated_at >= ? ORDER BY updated_at ASC`, sinceMs)
	if err != nil {
		return nil, nil, err
	}
	defer nRows.Close()

	var notes []model.Note
	for nRows.Next() {
		var n model.Note
		var pinned, archived, deleted int
		var stampsRaw string
		if err := nRows.Scan(&n.ID, &n.Content, &pinned, &archived, &deleted, &n.CreatedAt, &n.UpdatedAt, &stampsRaw); err != nil {
			return nil, nil, err
		}
		n.Pinned = pinned != 0
		n.Archived = archived != 0
		n.Deleted = deleted != 0
		_ = json.Unmarshal([]byte(stampsRaw), &n.Stamps)
		notes = append(notes, n)
	}

	aRows, err := s.db.Query(`
		SELECT id, note_id, sha256, mime, width, height, size_bytes, sort_order, deleted, updated_at
		FROM note_attachments WHERE updated_at >= ? ORDER BY updated_at ASC`, sinceMs)
	if err != nil {
		return nil, nil, err
	}
	defer aRows.Close()

	var atts []model.Attachment
	for aRows.Next() {
		var a model.Attachment
		var del int
		if err := aRows.Scan(&a.ID, &a.NoteID, &a.SHA256, &a.MIME, &a.Width, &a.Height, &a.SizeBytes, &a.SortOrder, &del, &a.UpdatedAt); err != nil {
			return nil, nil, err
		}
		a.Deleted = del != 0
		atts = append(atts, a)
	}
	return notes, atts, nil
}

// MergeRemote applies incoming notes and attachments using field-level LWW merge.
// Returns the number of notes inserted or changed.
func (s *Store) MergeRemote(remoteNotes []model.Note, remoteAtts []model.Attachment) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	mergedCount := 0
	for _, rn := range remoteNotes {
		if rn.ID == "" {
			continue
		}
		if rn.Stamps.Max() == 0 {
			rn.Stamps = model.FieldStamps{
				Content:     rn.UpdatedAt,
				Pinned:      rn.UpdatedAt,
				Archived:    rn.UpdatedAt,
				Deleted:     rn.UpdatedAt,
				Attachments: rn.UpdatedAt,
			}
		}

		local, err := s.getNoteTx(tx, rn.ID)
		if errors.Is(err, sql.ErrNoRows) {
			rn.UpdatedAt = rn.Stamps.Max()
			rn.Tags = tags.Extract(rn.Content)
			if err := s.upsertNoteTx(tx, &rn); err != nil {
				return 0, err
			}
			mergedCount++
			continue
		}
		if err != nil {
			return 0, err
		}

		merged, changed := mergeNoteFields(*local, rn)
		if changed {
			merged.Tags = tags.Extract(merged.Content)
			if err := s.upsertNoteTx(tx, &merged); err != nil {
				return 0, err
			}
			mergedCount++
		}
	}

	for _, ra := range remoteAtts {
		if ra.ID == "" || ra.NoteID == "" || ra.SHA256 == "" {
			continue
		}
		var localUpdated int64
		var localDeleted int
		err := tx.QueryRow(`SELECT updated_at, deleted FROM note_attachments WHERE id = ?`, ra.ID).Scan(&localUpdated, &localDeleted)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && (ra.UpdatedAt > localUpdated || (ra.UpdatedAt == localUpdated && ra.Deleted && localDeleted == 0))) {
			if err := s.upsertAttachmentTx(tx, &ra); err != nil {
				return 0, err
			}
		} else if err != nil {
			return 0, err
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return mergedCount, nil
}

// mergeNoteFields merges two versions of the same note field-by-field using LWW + deterministic tie-breaker.
func mergeNoteFields(local, remote model.Note) (model.Note, bool) {
	out := local
	changed := false

	if remote.CreatedAt > 0 && (out.CreatedAt == 0 || remote.CreatedAt < out.CreatedAt) {
		out.CreatedAt = remote.CreatedAt
		changed = true
	}

	if remote.Stamps.Content > out.Stamps.Content ||
		(remote.Stamps.Content == out.Stamps.Content && remote.Content > out.Content) {
		out.Content = remote.Content
		out.Stamps.Content = remote.Stamps.Content
		changed = true
	}

	if remote.Stamps.Pinned > out.Stamps.Pinned ||
		(remote.Stamps.Pinned == out.Stamps.Pinned && remote.Pinned && !out.Pinned) {
		out.Pinned = remote.Pinned
		out.Stamps.Pinned = remote.Stamps.Pinned
		changed = true
	}

	if remote.Stamps.Archived > out.Stamps.Archived ||
		(remote.Stamps.Archived == out.Stamps.Archived && remote.Archived && !out.Archived) {
		out.Archived = remote.Archived
		out.Stamps.Archived = remote.Stamps.Archived
		changed = true
	}

	if remote.Stamps.Deleted > out.Stamps.Deleted ||
		(remote.Stamps.Deleted == out.Stamps.Deleted && remote.Deleted && !out.Deleted) {
		out.Deleted = remote.Deleted
		out.Stamps.Deleted = remote.Stamps.Deleted
		changed = true
	}

	if remote.Stamps.Attachments > out.Stamps.Attachments {
		out.Stamps.Attachments = remote.Stamps.Attachments
		changed = true
	}

	newUpdated := out.Stamps.Max()
	if newUpdated != out.UpdatedAt {
		out.UpdatedAt = newUpdated
		changed = true
	}
	return out, changed
}

// UpsertSyncPeer updates local pairing credentials and watermark for a peer.
func (s *Store) UpsertSyncPeer(p model.SyncPeer) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		INSERT INTO sync_peers(peer_id, display_name, last_addr, pair_code, last_heard_at, last_sync_at)
		VALUES(?, ?, ?, ?, ?, ?)
		ON CONFLICT(peer_id) DO UPDATE SET
			display_name  = CASE WHEN excluded.display_name <> '' THEN excluded.display_name ELSE sync_peers.display_name END,
			last_addr     = CASE WHEN excluded.last_addr <> '' THEN excluded.last_addr ELSE sync_peers.last_addr END,
			pair_code     = CASE WHEN excluded.pair_code <> '' THEN excluded.pair_code ELSE sync_peers.pair_code END,
			last_heard_at = MAX(sync_peers.last_heard_at, excluded.last_heard_at),
			last_sync_at  = MAX(sync_peers.last_sync_at, excluded.last_sync_at)`,
		p.PeerID, p.DisplayName, p.LastAddr, p.PairCode, p.LastHeardAt, p.LastSyncAt)
	return err
}

// DeleteSyncPeer removes a paired peer from local storage.
func (s *Store) DeleteSyncPeer(peerID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`DELETE FROM sync_peers WHERE peer_id = ?`, peerID)
	return err
}

// GetSyncPeer fetches a peer's stored watermark and pairing code.
func (s *Store) GetSyncPeer(peerID string) (*model.SyncPeer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var p model.SyncPeer
	err := s.db.QueryRow(`SELECT peer_id, display_name, last_addr, pair_code, last_heard_at, last_sync_at FROM sync_peers WHERE peer_id = ?`, peerID).
		Scan(&p.PeerID, &p.DisplayName, &p.LastAddr, &p.PairCode, &p.LastHeardAt, &p.LastSyncAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return &p, err
}

// ListSyncPeers lists all paired sync peers (both outbound hosts and inbound clients).
func (s *Store) ListSyncPeers() ([]model.SyncPeer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`SELECT peer_id, display_name, last_addr, pair_code, last_heard_at, last_sync_at FROM sync_peers ORDER BY last_sync_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.SyncPeer
	for rows.Next() {
		var p model.SyncPeer
		if err := rows.Scan(&p.PeerID, &p.DisplayName, &p.LastAddr, &p.PairCode, &p.LastHeardAt, &p.LastSyncAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

func (s *Store) getNoteTx(tx *sql.Tx, id string) (*model.Note, error) {
	var n model.Note
	var pinned, archived, deleted int
	var stampsRaw string
	err := tx.QueryRow(
		`SELECT id, content, pinned, archived, deleted, created_at, updated_at, stamps_json FROM notes WHERE id = ?`,
		id,
	).Scan(&n.ID, &n.Content, &pinned, &archived, &deleted, &n.CreatedAt, &n.UpdatedAt, &stampsRaw)
	if err != nil {
		return nil, err
	}
	n.Pinned = pinned != 0
	n.Archived = archived != 0
	n.Deleted = deleted != 0
	_ = json.Unmarshal([]byte(stampsRaw), &n.Stamps)
	return &n, nil
}

func (s *Store) upsertNoteTx(tx *sql.Tx, n *model.Note) error {
	stampsBytes, err := json.Marshal(n.Stamps)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`
		INSERT INTO notes(id, content, pinned, archived, deleted, created_at, updated_at, stamps_json)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			content     = excluded.content,
			pinned      = excluded.pinned,
			archived    = excluded.archived,
			deleted     = excluded.deleted,
			created_at  = excluded.created_at,
			updated_at  = excluded.updated_at,
			stamps_json = excluded.stamps_json`,
		n.ID, n.Content, boolInt(n.Pinned), boolInt(n.Archived), boolInt(n.Deleted),
		n.CreatedAt, n.UpdatedAt, string(stampsBytes))
	if err != nil {
		return err
	}

	if _, err := tx.Exec(`DELETE FROM note_tags WHERE note_id = ?`, n.ID); err != nil {
		return err
	}
	if !n.Deleted {
		for _, t := range tags.Extract(n.Content) {
			if _, err := tx.Exec(`INSERT OR IGNORE INTO note_tags(note_id, tag_path) VALUES(?, ?)`, n.ID, t); err != nil {
				return err
			}
		}
	}

	if _, err := tx.Exec(`DELETE FROM notes_fts WHERE note_id = ?`, n.ID); err != nil {
		return err
	}
	if !n.Deleted {
		if _, err := tx.Exec(`INSERT INTO notes_fts(note_id, content) VALUES(?, ?)`, n.ID, n.Content); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) upsertAttachmentTx(tx *sql.Tx, a *model.Attachment) error {
	_, err := tx.Exec(`
		INSERT INTO note_attachments(id, note_id, sha256, mime, width, height, size_bytes, sort_order, deleted, updated_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			note_id    = excluded.note_id,
			sha256     = excluded.sha256,
			mime       = excluded.mime,
			width      = excluded.width,
			height     = excluded.height,
			size_bytes = excluded.size_bytes,
			sort_order = excluded.sort_order,
			deleted    = excluded.deleted,
			updated_at = excluded.updated_at`,
		a.ID, a.NoteID, a.SHA256, a.MIME, a.Width, a.Height, a.SizeBytes, a.SortOrder, boolInt(a.Deleted), a.UpdatedAt)
	return err
}

func (s *Store) listNoteAttachmentsLocked(noteID string, includeDeleted bool) ([]model.Attachment, error) {
	q := `SELECT id, note_id, sha256, mime, width, height, size_bytes, sort_order, deleted, updated_at
	      FROM note_attachments WHERE note_id = ?`
	if !includeDeleted {
		q += ` AND deleted = 0`
	}
	q += ` ORDER BY sort_order ASC, id ASC`

	rows, err := s.db.Query(q, noteID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var atts []model.Attachment
	for rows.Next() {
		var a model.Attachment
		var del int
		if err := rows.Scan(&a.ID, &a.NoteID, &a.SHA256, &a.MIME, &a.Width, &a.Height, &a.SizeBytes, &a.SortOrder, &del, &a.UpdatedAt); err != nil {
			return nil, err
		}
		a.Deleted = del != 0
		if p, ok := s.BlobPath(a.SHA256); ok {
			a.LocalPath = p
		}
		atts = append(atts, a)
	}
	return atts, nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func extFromMIME(mime string) string {
	switch strings.ToLower(strings.TrimSpace(mime)) {
	case "image/png":
		return ".png"
	case "image/jpeg", "image/jpg":
		return ".jpg"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	case "image/heic":
		return ".heic"
	default:
		return ".bin"
	}
}

func mimeFromExt(ext string) string {
	switch strings.ToLower(ext) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".webp":
		return "image/webp"
	case ".gif":
		return "image/gif"
	case ".heic":
		return "image/heic"
	default:
		return "application/octet-stream"
	}
}
