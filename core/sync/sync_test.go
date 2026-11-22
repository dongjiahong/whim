package sync_test

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"whim/core/model"
	"whim/core/store"
	whimsync "whim/core/sync"
)

func TestPeerToPeerBidirectionalSyncAndBlobs(t *testing.T) {
	stMac, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer stMac.Close()

	stAndroid, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer stAndroid.Close()

	const code = "482913"
	peerMac := whimsync.NewPeer(stMac, "peer-mac", "MacBook", code)
	peerAndroid := whimsync.NewPeer(stAndroid, "peer-android", "Android", code)

	port, err := peerMac.StartServer(0, false)
	if err != nil {
		t.Fatalf("start mac server: %v", err)
	}
	defer peerMac.StopServer()
	macAddr := fmt.Sprintf("127.0.0.1:%d", port)

	// 1. Mac creates a note with an image
	macImg := []byte("\x89PNG\r\n\x1a\nmac-image-payload")
	macHash, _, macSize, err := stMac.SaveBlob(macImg, "image/png")
	if err != nil {
		t.Fatal(err)
	}
	noteOnMac, err := stMac.CreateNote("Mac 写的闪念 #工作/架构", []model.Attachment{
		{SHA256: macHash, MIME: "image/png", SizeBytes: macSize},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 2. Android creates a note with its own image
	andImg := []byte("\x89PNG\r\n\x1a\nandroid-image-payload")
	andHash, _, andSize, err := stAndroid.SaveBlob(andImg, "image/png")
	if err != nil {
		t.Fatal(err)
	}
	noteOnAndroid, err := stAndroid.CreateNote("手机地铁上记的想法 #灵感/随手", []model.Attachment{
		{SHA256: andHash, MIME: "image/png", SizeBytes: andSize},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 3. Single bidirectional sync from Android -> Mac converges both sides AND transfers both images!
	merged, dl, ul, err := peerAndroid.SyncWithAddr(context.Background(), macAddr, "peer-mac")
	if err != nil {
		t.Fatalf("sync failed: %v", err)
	}
	if merged != 1 || dl != 1 || ul != 1 {
		t.Fatalf("expected merged=1 dl=1 ul=1, got merged=%d dl=%d ul=%d", merged, dl, ul)
	}

	// Verify both devices have both notes and both blobs
	macNotes, _ := stMac.ListNotes(model.ListFilter{})
	andNotes, _ := stAndroid.ListNotes(model.ListFilter{})
	if len(macNotes) != 2 || len(andNotes) != 2 {
		t.Fatalf("expected 2 notes on each side, got mac=%d android=%d", len(macNotes), len(andNotes))
	}
	if _, ok := stMac.BlobPath(andHash); !ok {
		t.Fatalf("mac missing android blob")
	}
	if _, ok := stAndroid.BlobPath(macHash); !ok {
		t.Fatalf("android missing mac blob")
	}

	// 4. Concurrent field-level edits: Mac edits content, Android pins the SAME note
	newContent := "Mac 更新了正文 #工作/架构/同步"
	if _, err := stMac.UpdateNote(noteOnMac.ID, &newContent, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	pinTrue := true
	if _, err := stAndroid.UpdateNote(noteOnMac.ID, nil, &pinTrue, nil, nil); err != nil {
		t.Fatal(err)
	}

	if _, _, _, err := peerAndroid.SyncWithAddr(context.Background(), macAddr, "peer-mac"); err != nil {
		t.Fatalf("second sync failed: %v", err)
	}

	gotMac, _ := stMac.GetNote(noteOnMac.ID)
	gotAnd, _ := stAndroid.GetNote(noteOnMac.ID)
	if gotMac.Content != newContent || !gotMac.Pinned {
		t.Fatalf("mac did not preserve both concurrent field edits: %+v", gotMac)
	}
	if gotAnd.Content != newContent || !gotAnd.Pinned {
		t.Fatalf("android did not preserve both concurrent field edits: %+v", gotAnd)
	}

	// 5. Tombstone deletion propagates and does not resurrect
	delTrue := true
	if _, err := stAndroid.UpdateNote(noteOnAndroid.ID, nil, nil, nil, &delTrue); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := peerAndroid.SyncWithAddr(context.Background(), macAddr, "peer-mac"); err != nil {
		t.Fatal(err)
	}
	gotDeletedOnMac, _ := stMac.GetNote(noteOnAndroid.ID)
	if !gotDeletedOnMac.Deleted {
		t.Fatalf("expected tombstone delete to propagate to Mac")
	}
}

func TestPairingCodeLockoutAfterFiveFailures(t *testing.T) {
	stMac, _ := store.Open(t.TempDir())
	defer stMac.Close()
	stBad, _ := store.Open(t.TempDir())
	defer stBad.Close()

	peerMac := whimsync.NewPeer(stMac, "peer-mac", "Mac", "123456")
	peerBad := whimsync.NewPeer(stBad, "peer-bad", "Intruder", "000000")

	port, err := peerMac.StartServer(0, false)
	if err != nil {
		t.Fatal(err)
	}
	defer peerMac.StopServer()
	addr := fmt.Sprintf("127.0.0.1:%d", port)

	var lastErr error
	for i := 0; i < 5; i++ {
		_, _, _, lastErr = peerBad.SyncWithAddr(context.Background(), addr, "peer-mac")
		if lastErr == nil {
			t.Fatalf("attempt %d should have failed", i+1)
		}
	}
	if !strings.Contains(lastErr.Error(), "locked") {
		t.Fatalf("expected lockout on 5th failed attempt, got: %v", lastErr)
	}
}
