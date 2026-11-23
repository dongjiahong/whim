package sync_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"whim/core/model"
	"whim/core/store"
	whimsync "whim/core/sync"
)

func TestSingleLibraryCodeBidirectionalSyncAndBlobs(t *testing.T) {
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

	// Both devices share the same library code (second device adopts the first device's 6-digit code)
	const sharedCode = "614284"
	peerMac := whimsync.NewPeer(stMac, "peer-mac", "MacBook", sharedCode)
	peerAndroid := whimsync.NewPeer(stAndroid, "peer-android", "Android", "999111")
	// Isolate test UDP discovery port so a running desktop Whim.app on :8789 is not picked up
	peerMac.SetDiscoveryPort(58789)
	peerAndroid.SetDiscoveryPort(58789)

	port, err := peerMac.StartServer(0, false)
	if err != nil {
		t.Fatalf("start mac server: %v", err)
	}
	defer peerMac.StopServer()
	macAddr := fmt.Sprintf("127.0.0.1:%d", port)
	rawManual, _ := json.Marshal([]string{macAddr})
	_ = stAndroid.SetMeta("whim.manual_addrs", string(rawManual))

	// 1. Before adopting Mac's code, SyncOnce reports wrong_code status for Mac
	wrongSum := peerAndroid.SyncOnce(context.Background())
	if wrongSum.PeersFound != 1 || wrongSum.PeersSynced != 0 || len(wrongSum.Peers) != 1 || wrongSum.Peers[0].Status != "wrong_code" {
		t.Fatalf("expected wrong_code status before adopting code, got %+v", wrongSum)
	}

	// 2. Mac & Android each create a note with an inline image
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

	// 3. Android adopts Mac's 6-digit code and runs SyncOnce -> automatic bidirectional sync!
	peerAndroid.SetPairCode(sharedCode)
	sum := peerAndroid.SyncOnce(context.Background())
	if sum.PeersSynced != 1 || sum.NotesMerged != 1 || sum.BlobsDownloaded != 1 || sum.BlobsUploaded != 1 {
		t.Fatalf("unexpected sync summary: %+v", sum)
	}
	if len(sum.Peers) != 1 || sum.Peers[0].Status != "synced" {
		t.Fatalf("expected synced peer status, got %+v", sum.Peers)
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

	peerAndroid.SyncOnce(context.Background())
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
	peerBad := whimsync.NewPeer(stBad, "peer-bad", "Intruder", "000000")
	peerMac.SetDiscoveryPort(58789)
	peerBad.SetDiscoveryPort(58789)

	port, err := peerMac.StartServer(0, false)
	if err != nil {
		t.Fatal(err)
	}
	defer peerMac.StopServer()
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	rawManual, _ := json.Marshal([]string{addr})
	_ = stBad.SetMeta("whim.manual_addrs", string(rawManual))

	var last model.SyncSummary
	for i := 0; i < 5; i++ {
		last = peerBad.SyncOnce(context.Background())
		if last.PeersSynced != 0 {
			t.Fatalf("attempt %d should have failed", i+1)
		}
	}
	if len(last.Peers) != 1 || last.Peers[0].Status != "locked" || !strings.Contains(last.Peers[0].Message, "尝试太多次") {
		t.Fatalf("expected lockout on 5th failed attempt, got: %+v", last.Peers)
	}
}

func TestSyncOnceNotifiesDataVersionAndConcurrentPeers(t *testing.T) {
	stMac, _ := store.Open(t.TempDir())
	defer stMac.Close()
	stAndroid, _ := store.Open(t.TempDir())
	defer stAndroid.Close()

	const code = "246810"
	peerMac := whimsync.NewPeer(stMac, "peer-mac", "Mac", code)
	peerAndroid := whimsync.NewPeer(stAndroid, "peer-android", "Android", code)
	peerMac.SetDiscoveryPort(58790)
	peerAndroid.SetDiscoveryPort(58790)

	port, err := peerMac.StartServer(0, false)
	if err != nil {
		t.Fatal(err)
	}
	defer peerMac.StopServer()

	// Include a dead/unreachable peer alongside the live Mac to verify concurrent sync succeeds quickly.
	liveAddr := fmt.Sprintf("127.0.0.1:%d", port)
	rawManual, _ := json.Marshal([]string{"127.0.0.1:1", liveAddr})
	_ = stAndroid.SetMeta("whim.manual_addrs", string(rawManual))

	if _, err := stMac.CreateNote("Mac 新笔记 #测试", nil); err != nil {
		t.Fatal(err)
	}

	vBefore := peerAndroid.DataVersion()
	sum := peerAndroid.SyncOnce(context.Background())
	if sum.PeersSynced != 1 || sum.NotesMerged != 1 {
		t.Fatalf("expected live Mac to sync despite unreachable sibling addr, got: %+v", sum)
	}
	if peerAndroid.DataVersion() <= vBefore {
		t.Fatalf("expected DataVersion to increment after outgoing sync merged notes (before=%d, after=%d)", vBefore, peerAndroid.DataVersion())
	}
	// WaitForChange should return immediately (localChanged signaled by SyncWithAddr)
	if !peerAndroid.WaitForChange(1) {
		t.Fatalf("expected WaitForChange to wake immediately after outgoing sync merged notes")
	}
}
