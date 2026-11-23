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

func TestPerDevicePairingBidirectionalSyncAndBlobs(t *testing.T) {
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

	// Each device has its OWN independent 6-digit code!
	const macCode = "328287"
	const androidCode = "814502"
	peerMac := whimsync.NewPeer(stMac, "peer-mac", "MacBook", macCode)
	peerAndroid := whimsync.NewPeer(stAndroid, "peer-android", "Android", androidCode)

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

	// 3. Android pairs with Mac using Mac's code (328287); Android's OWN code (814502) stays untouched!
	sum, err := peerAndroid.PairAndSync(context.Background(), macAddr, macCode)
	if err != nil {
		t.Fatalf("pair and sync failed: %v", err)
	}
	if sum.NotesMerged != 1 || sum.BlobsDownloaded != 1 || sum.BlobsUploaded != 1 {
		t.Fatalf("unexpected summary: %+v", sum)
	}
	if peerAndroid.PairCode() != androidCode {
		t.Fatalf("android local code should remain %s, got %s", androidCode, peerAndroid.PairCode())
	}

	// Verify paired peer is saved on Android so subsequent SyncOnce works without re-typing code
	paired, _ := stAndroid.ListSyncPeers()
	if len(paired) != 1 || paired[0].PeerID != "peer-mac" || paired[0].PairCode != macCode {
		t.Fatalf("expected peer-mac saved in sync_peers, got %+v", paired)
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

	// Subsequent SyncOnce automatically uses the saved per-peer code!
	sum2 := peerAndroid.SyncOnce(context.Background())
	if sum2.PeersSynced != 1 {
		t.Fatalf("expected SyncOnce to sync saved peer, got %+v", sum2)
	}

	gotMac, _ := stMac.GetNote(noteOnMac.ID)
	gotAnd, _ := stAndroid.GetNote(noteOnMac.ID)
	if gotMac.Content != newContent || !gotMac.Pinned {
		t.Fatalf("mac did not preserve concurrent edits: %+v", gotMac)
	}
	if gotAnd.Content != newContent || !gotAnd.Pinned {
		t.Fatalf("android did not preserve concurrent edits: %+v", gotAnd)
	}

	// 5. Tombstone deletion propagates
	delTrue := true
	if _, err := stAndroid.UpdateNote(noteOnAndroid.ID, nil, nil, nil, &delTrue); err != nil {
		t.Fatal(err)
	}
	peerAndroid.SyncOnce(context.Background())
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
	peerBad := whimsync.NewPeer(stBad, "peer-bad", "Intruder", "999999")

	port, err := peerMac.StartServer(0, false)
	if err != nil {
		t.Fatal(err)
	}
	defer peerMac.StopServer()
	addr := fmt.Sprintf("127.0.0.1:%d", port)

	var lastErr error
	for i := 0; i < 5; i++ {
		_, lastErr = peerBad.PairAndSync(context.Background(), addr, "000000")
		if lastErr == nil {
			t.Fatalf("attempt %d should have failed", i+1)
		}
	}
	if !strings.Contains(lastErr.Error(), "locked") {
		t.Fatalf("expected lockout on 5th failed attempt, got: %v", lastErr)
	}
}
