package store_test

import (
	"os"
	"path/filepath"
	"testing"

	"whim/core/export"
	"whim/core/model"
	"whim/core/store"
)

func TestStoreCRUDTagsBlobsAndExport(t *testing.T) {
	dir := t.TempDir()
	st, err := store.Open(dir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()

	// Save image blob (content-addressed dedup)
	imgBytes := []byte("\x89PNG\r\n\x1a\nfake-png-bytes")
	hash1, path1, size1, err := st.SaveBlob(imgBytes, "image/png")
	if err != nil {
		t.Fatalf("save blob: %v", err)
	}
	hash2, _, _, err := st.SaveBlob(imgBytes, "image/png")
	if err != nil || hash1 != hash2 {
		t.Fatalf("expected deduplicated sha256 hash, got %s vs %s (%v)", hash1, hash2, err)
	}
	if size1 != int64(len(imgBytes)) || path1 == "" {
		t.Fatalf("unexpected blob metadata")
	}

	// Create notes with multi-level tags
	n1, err := st.CreateNote("今天梳理了同步协议 #项目/whim/同步 #工作/架构", []model.Attachment{
		{SHA256: hash1, MIME: "image/png", Width: 800, Height: 600, SizeBytes: size1},
	})
	if err != nil {
		t.Fatalf("create note 1: %v", err)
	}
	if len(n1.Tags) != 2 || len(n1.Attachments) != 1 {
		t.Fatalf("unexpected tags/attachments: %+v", n1)
	}

	_, err = st.CreateNote("晚上复盘一下价格行为 #交易/价格行为/双腿回调", nil)
	if err != nil {
		t.Fatalf("create note 2: %v", err)
	}

	// Tag prefix query
	whimNotes, err := st.ListNotes(model.ListFilter{TagPrefix: "项目/whim"})
	if err != nil || len(whimNotes) != 1 || whimNotes[0].ID != n1.ID {
		t.Fatalf("expected 1 note under 项目/whim, got %d (%v)", len(whimNotes), err)
	}

	// Tag tree hierarchy
	tree, err := st.ListTagTree()
	if err != nil || len(tree) != 3 {
		t.Fatalf("expected 3 root tag nodes, got %+v (%v)", tree, err)
	}

	// Keyword search (Chinese substring)
	found, err := st.ListNotes(model.ListFilter{Query: "双腿回调"})
	if err != nil || len(found) != 1 {
		t.Fatalf("expected 1 note matching 双腿回调, got %d (%v)", len(found), err)
	}

	// Export Markdown
	exportDir := filepath.Join(t.TempDir(), "md")
	res, err := export.Markdown(st, model.ListFilter{}, exportDir)
	if err != nil {
		t.Fatalf("export markdown: %v", err)
	}
	if res.NotesExported != 2 || res.BlobsCopied != 1 || len(res.FilesWritten) != 1 {
		t.Fatalf("unexpected export result: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(exportDir, "attachments", hash1+".png")); err != nil {
		t.Fatalf("expected exported attachment image: %v", err)
	}
}

func TestPaginationStatsRandomAndBatchExport(t *testing.T) {
	dir := t.TempDir()
	st, err := store.Open(dir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()

	// Create 560 active notes (3 pinned), 5 archived, 2 deleted
	const totalActive = 560
	for i := 0; i < totalActive; i++ {
		content := "笔记内容 #测试/分页"
		if i%2 == 0 {
			content += " #偶数"
		}
		n, err := st.CreateNote(content, nil)
		if err != nil {
			t.Fatalf("create note %d: %v", i, err)
		}
		if i < 3 {
			pinned := true
			if _, err := st.UpdateNote(n.ID, nil, &pinned, nil, nil); err != nil {
				t.Fatalf("pin note %d: %v", i, err)
			}
		}
	}
	for i := 0; i < 5; i++ {
		n, err := st.CreateNote("归档内容 #归档", nil)
		if err != nil {
			t.Fatalf("create archived: %v", err)
		}
		arch := true
		if _, err := st.UpdateNote(n.ID, nil, nil, &arch, nil); err != nil {
			t.Fatalf("archive: %v", err)
		}
	}
	for i := 0; i < 2; i++ {
		n, err := st.CreateNote("已删内容", nil)
		if err != nil {
			t.Fatalf("create deleted: %v", err)
		}
		del := true
		if _, err := st.UpdateNote(n.ID, nil, nil, nil, &del); err != nil {
			t.Fatalf("delete: %v", err)
		}
	}

	// Walk all active notes via keyset cursor pagination (page size 50)
	seen := make(map[string]bool)
	var cursor *model.NoteCursor
	pages := 0
	for {
		page, err := st.ListNotesPage(model.ListFilter{Limit: 50, Cursor: cursor})
		if err != nil {
			t.Fatalf("list page %d: %v", pages, err)
		}
		pages++
		for _, n := range page.Notes {
			if seen[n.ID] {
				t.Fatalf("duplicate note id %s across pages", n.ID)
			}
			seen[n.ID] = true
		}
		if !page.HasMore {
			break
		}
		if page.NextCursor == nil {
			t.Fatalf("expected next cursor when has_more is true")
		}
		cursor = page.NextCursor
	}
	if len(seen) != totalActive {
		t.Fatalf("expected %d unique active notes across pages, got %d (pages=%d)", totalActive, len(seen), pages)
	}

	// OnlyArchived filter
	archPage, err := st.ListNotesPage(model.ListFilter{OnlyArchived: true, Limit: 50})
	if err != nil || len(archPage.Notes) != 5 || archPage.HasMore {
		t.Fatalf("expected 5 archived notes, got %d (hasMore=%v, err=%v)", len(archPage.Notes), archPage.HasMore, err)
	}

	// SQL Stats
	stats, err := st.GetStats(84)
	if err != nil {
		t.Fatalf("get stats: %v", err)
	}
	if stats.TotalNotes != totalActive {
		t.Fatalf("expected TotalNotes=%d, got %d", totalActive, stats.TotalNotes)
	}
	if stats.TotalTags != 2 {
		t.Fatalf("expected TotalTags=2, got %d", stats.TotalTags)
	}
	if stats.ActiveDays < 1 {
		t.Fatalf("expected ActiveDays >= 1, got %d", stats.ActiveDays)
	}

	// Random walk
	rnd, err := st.ListRandomNotes("", 10)
	if err != nil || len(rnd) != 10 {
		t.Fatalf("expected 10 random notes, got %d (%v)", len(rnd), err)
	}

	// Export all 560 notes (must not truncate at 500)
	expDir := filepath.Join(t.TempDir(), "md_all")
	res, err := export.Markdown(st, model.ListFilter{}, expDir)
	if err != nil {
		t.Fatalf("export markdown: %v", err)
	}
	if res.NotesExported != totalActive {
		t.Fatalf("expected %d exported notes, got %d", totalActive, res.NotesExported)
	}
}
