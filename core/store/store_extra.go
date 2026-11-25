package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"whim/core/model"
	"whim/core/tags"
)

// ListReplies returns all active replies (thread comments) for a parent note in chronological order.
func (s *Store) ListReplies(parentID string) ([]model.Note, error) {
	pid := strings.TrimSpace(parentID)
	if pid == "" {
		return []model.Note{}, nil
	}
	page, err := s.ListNotesPage(model.ListFilter{
		ParentID:        pid,
		IncludeArchived: true,
		Limit:           200,
	})
	if err != nil {
		return nil, err
	}
	return page.Notes, nil
}

// PurgeNote permanently removes a single soft-deleted note and its attachment metadata from SQLite.
func (s *Store) PurgeNote(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`DELETE FROM note_attachments WHERE note_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM note_tags WHERE note_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM notes_fts WHERE note_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM notes WHERE id = ? AND deleted = 1`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// PurgeOldDeleted permanently removes soft-deleted notes older than olderThanDays.
// When olderThanDays <= 0, all soft-deleted notes in the trash are permanently removed.
func (s *Store) PurgeOldDeleted(olderThanDays int) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	var (
		rows *sql.Rows
		err  error
	)
	if olderThanDays > 0 {
		cutoff := time.Now().AddDate(0, 0, -olderThanDays).UnixMilli()
		rows, err = s.db.Query(`SELECT id FROM notes WHERE deleted = 1 AND updated_at <= ?`, cutoff)
	} else {
		rows, err = s.db.Query(`SELECT id FROM notes WHERE deleted = 1`)
	}
	if err != nil {
		return 0, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	if len(ids) == 0 {
		return 0, nil
	}

	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	for _, id := range ids {
		if _, err := tx.Exec(`DELETE FROM note_attachments WHERE note_id = ?`, id); err != nil {
			return 0, err
		}
		if _, err := tx.Exec(`DELETE FROM note_tags WHERE note_id = ?`, id); err != nil {
			return 0, err
		}
		if _, err := tx.Exec(`DELETE FROM notes_fts WHERE note_id = ?`, id); err != nil {
			return 0, err
		}
		if _, err := tx.Exec(`DELETE FROM notes WHERE id = ? AND deleted = 1`, id); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return len(ids), nil
}

// RenameTag atomically renames or merges #oldPrefix (and its #oldPrefix/... subtags)
// to #newPrefix across all non-deleted notes, advancing content LWW timestamps for P2P sync.
func (s *Store) RenameTag(oldPrefix, newPrefix string) (*model.TagRenameResult, error) {
	oldNorm := tags.Normalize(oldPrefix)
	newNorm := tags.Normalize(newPrefix)
	if oldNorm == "" {
		return nil, errors.New("旧标签不能为空")
	}
	if newNorm == "" {
		return nil, errors.New("新标签不能为空")
	}
	if oldNorm == newNorm {
		return &model.TagRenameResult{OldTag: oldNorm, NewTag: newNorm, UpdatedNotes: 0}, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	rows, err := s.db.Query(`
		SELECT DISTINCT n.id, n.parent_id, n.content, n.pinned, n.archived, n.deleted, n.created_at, n.updated_at, n.stamps_json
		FROM notes n
		JOIN note_tags nt ON nt.note_id = n.id
		WHERE n.deleted = 0 AND (nt.tag_path = ? OR nt.tag_path LIKE ?)`,
		oldNorm, oldNorm+"/%")
	if err != nil {
		return nil, err
	}
	var matched []model.Note
	for rows.Next() {
		var n model.Note
		var pinned, archived, deleted int
		var stampsRaw string
		if err := rows.Scan(&n.ID, &n.ParentID, &n.Content, &pinned, &archived, &deleted, &n.CreatedAt, &n.UpdatedAt, &stampsRaw); err != nil {
			rows.Close()
			return nil, err
		}
		n.Pinned = pinned != 0
		n.Archived = archived != 0
		n.Deleted = deleted != 0
		_ = json.Unmarshal([]byte(stampsRaw), &n.Stamps)
		matched = append(matched, n)
	}
	rows.Close()

	if len(matched) == 0 {
		return &model.TagRenameResult{OldTag: oldNorm, NewTag: newNorm, UpdatedNotes: 0}, nil
	}

	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	updated := 0
	baseNow := time.Now().UnixMilli()
	for i := range matched {
		n := matched[i]
		nextContent, changed := tags.ReplacePrefix(n.Content, oldNorm, newNorm)
		if !changed {
			continue
		}
		ts := baseNow
		if ts <= n.UpdatedAt {
			ts = n.UpdatedAt + 1
		}
		n.Content = nextContent
		n.Stamps.Content = ts
		n.UpdatedAt = n.Stamps.Max()
		n.Tags = tags.Extract(n.Content)
		if err := s.upsertNoteTx(tx, &n); err != nil {
			return nil, err
		}
		updated++
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &model.TagRenameResult{
		OldTag:       oldNorm,
		NewTag:       newNorm,
		UpdatedNotes: updated,
	}, nil
}

// BackupDir returns the default local backup directory under dataDir/backups.
func (s *Store) BackupDir() string {
	return filepath.Join(s.dataDir, "backups")
}

// BackupDatabase creates a WAL-safe daily snapshot via SQLite VACUUM INTO and prunes old snapshots beyond keepDays.
func (s *Store) BackupDatabase(backupDir string, keepDays int, force bool) (*model.BackupResult, error) {
	if strings.TrimSpace(backupDir) == "" {
		backupDir = s.BackupDir()
	}
	if keepDays <= 0 {
		keepDays = 7
	}
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		return nil, fmt.Errorf("create backupDir: %w", err)
	}

	todayName := fmt.Sprintf("whim-%s.sqlite3", time.Now().Format("2006-01-02"))
	finalPath := filepath.Join(backupDir, todayName)

	s.mu.Lock()
	defer s.mu.Unlock()

	if !force {
		if info, err := os.Stat(finalPath); err == nil && info.Size() > 0 {
			backups := listBackupsDir(backupDir)
			return &model.BackupResult{
				BackupPath:  finalPath,
				BackupDir:   backupDir,
				BackupCount: len(backups),
				SizeBytes:   info.Size(),
				CreatedAt:   info.ModTime().UnixMilli(),
				Skipped:     true,
			}, nil
		}
	}

	tmpPath := finalPath + ".tmp"
	_ = os.Remove(tmpPath)
	escaped := strings.ReplaceAll(tmpPath, "'", "''")
	if _, err := s.db.Exec(fmt.Sprintf("VACUUM INTO '%s'", escaped)); err != nil {
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("vacuum into backup: %w", err)
	}
	if err := os.Rename(tmpPath, finalPath); err != nil {
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("finalize backup: %w", err)
	}

	// Prune backups beyond keepDays (newest first)
	backups := listBackupsDir(backupDir)
	if len(backups) > keepDays {
		for _, old := range backups[keepDays:] {
			_ = os.Remove(old.Path)
		}
		backups = backups[:keepDays]
	}

	info, err := os.Stat(finalPath)
	var size int64
	var modMs int64
	if err == nil {
		size = info.Size()
		modMs = info.ModTime().UnixMilli()
	}
	return &model.BackupResult{
		BackupPath:  finalPath,
		BackupDir:   backupDir,
		BackupCount: len(backups),
		SizeBytes:   size,
		CreatedAt:   modMs,
		Skipped:     false,
	}, nil
}

// ListBackups lists existing daily SQLite backup files newest-first.
func (s *Store) ListBackups(backupDir string) ([]model.BackupInfo, error) {
	if strings.TrimSpace(backupDir) == "" {
		backupDir = s.BackupDir()
	}
	return listBackupsDir(backupDir), nil
}

func listBackupsDir(backupDir string) []model.BackupInfo {
	entries, err := os.ReadDir(backupDir)
	if err != nil {
		return []model.BackupInfo{}
	}
	var out []model.BackupInfo
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "whim-") || !strings.HasSuffix(name, ".sqlite3") {
			continue
		}
		info, ierr := e.Info()
		if ierr != nil {
			continue
		}
		out = append(out, model.BackupInfo{
			Name:      name,
			Path:      filepath.Join(backupDir, name),
			SizeBytes: info.Size(),
			ModTime:   info.ModTime().UnixMilli(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name != out[j].Name {
			return out[i].Name > out[j].Name
		}
		return out[i].ModTime > out[j].ModTime
	})
	return out
}
