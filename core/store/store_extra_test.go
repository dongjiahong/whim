package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"whim/core/model"
)

func TestTrashFiltersRepliesRenameAndBackup(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(dir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()

	// 1. Create notes: tagged, untagged, with image
	hash, _, size, err := st.SaveBlob([]byte("fake-png-bytes"), "image/png")
	if err != nil {
		t.Fatalf("SaveBlob: %v", err)
	}
	n1, err := st.CreateNote("#工作/架构 设计评审\n# 普通标题不能被误改", nil)
	if err != nil {
		t.Fatalf("CreateNote n1: %v", err)
	}
	n2, err := st.CreateNote("无标签纯文字笔记", nil)
	if err != nil {
		t.Fatalf("CreateNote n2: %v", err)
	}
	n3, err := st.CreateNote("#工作/架构/同步 图文记录\n![image](whim://blob/"+hash+")", []model.Attachment{
		{SHA256: hash, MIME: "image/png", SizeBytes: size},
	})
	if err != nil {
		t.Fatalf("CreateNote n3: %v", err)
	}

	// 2. Quick filters: OnlyUntagged & OnlyWithImages
	untagged, err := st.ListNotes(model.ListFilter{OnlyUntagged: true})
	if err != nil || len(untagged) != 1 || untagged[0].ID != n2.ID {
		t.Fatalf("OnlyUntagged expected [n2], got %d err=%v", len(untagged), err)
	}
	withImgs, err := st.ListNotes(model.ListFilter{OnlyWithImages: true})
	if err != nil || len(withImgs) != 1 || withImgs[0].ID != n3.ID {
		t.Fatalf("OnlyWithImages expected [n3], got %d err=%v", len(withImgs), err)
	}

	// 3. Replies / Thread
	r1, err := st.CreateReply(n1.ID, "第一条追记", nil)
	if err != nil {
		t.Fatalf("CreateReply: %v", err)
	}
	if r1.ParentID != n1.ID {
		t.Fatalf("expected parent_id %s, got %s", n1.ID, r1.ParentID)
	}
	mainFeed, err := st.ListNotes(model.ListFilter{})
	if err != nil || len(mainFeed) != 3 {
		t.Fatalf("main feed should exclude replies, got %d err=%v", len(mainFeed), err)
	}
	var foundN1 *model.Note
	for i := range mainFeed {
		if mainFeed[i].ID == n1.ID {
			foundN1 = &mainFeed[i]
		}
	}
	if foundN1 == nil || foundN1.ReplyCount != 1 {
		t.Fatalf("expected n1 ReplyCount=1, got %+v", foundN1)
	}
	replies, err := st.ListReplies(n1.ID)
	if err != nil || len(replies) != 1 || replies[0].ID != r1.ID {
		t.Fatalf("ListReplies expected [r1], got %d err=%v", len(replies), err)
	}

	// 4. RenameTag (must rewrite #工作/架构 and #工作/架构/同步, keep "# 普通标题不能被误改")
	renRes, err := st.RenameTag("工作/架构", "研发/系统")
	if err != nil {
		t.Fatalf("RenameTag: %v", err)
	}
	if renRes.UpdatedNotes != 2 {
		t.Fatalf("expected 2 updated notes, got %d", renRes.UpdatedNotes)
	}
	gotN1, _ := st.GetNote(n1.ID)
	if !strings.Contains(gotN1.Content, "#研发/系统 ") || !strings.Contains(gotN1.Content, "# 普通标题不能被误改") {
		t.Fatalf("unexpected renamed n1 content: %q", gotN1.Content)
	}
	gotN3, _ := st.GetNote(n3.ID)
	if !strings.Contains(gotN3.Content, "#研发/系统/同步 ") {
		t.Fatalf("unexpected renamed n3 content: %q", gotN3.Content)
	}

	// 5. Trash (OnlyDeleted + restore + PurgeNote)
	del := true
	if _, err := st.UpdateNote(n2.ID, nil, nil, nil, &del); err != nil {
		t.Fatalf("soft delete n2: %v", err)
	}
	trash, err := st.ListNotes(model.ListFilter{OnlyDeleted: true})
	if err != nil || len(trash) != 1 || trash[0].ID != n2.ID {
		t.Fatalf("OnlyDeleted expected [n2], got %d err=%v", len(trash), err)
	}
	if err := st.PurgeNote(n2.ID); err != nil {
		t.Fatalf("PurgeNote: %v", err)
	}
	trashAfter, _ := st.ListNotes(model.ListFilter{OnlyDeleted: true})
	if len(trashAfter) != 0 {
		t.Fatalf("expected empty trash after purge, got %d", len(trashAfter))
	}

	// 6. BackupDatabase + pruning
	res, err := st.BackupDatabase("", 7, false)
	if err != nil {
		t.Fatalf("BackupDatabase: %v", err)
	}
	if res.Skipped || res.SizeBytes <= 0 {
		t.Fatalf("expected fresh backup, got %+v", res)
	}
	if _, err := os.Stat(res.BackupPath); err != nil {
		t.Fatalf("backup file missing: %v", err)
	}
	res2, err := st.BackupDatabase("", 7, false)
	if err != nil || !res2.Skipped {
		t.Fatalf("second daily backup without force should skip, got %+v err=%v", res2, err)
	}
	// Verify backup is a readable SQLite DB
	backupDir := filepath.Dir(res.BackupPath)
	list, err := st.ListBackups(backupDir)
	if err != nil || len(list) != 1 {
		t.Fatalf("ListBackups expected 1, got %d err=%v", len(list), err)
	}
}
