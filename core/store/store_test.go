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
