package sync_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"whim/core/model"
	"whim/core/store"
	whimsync "whim/core/sync"
)

func TestIndependentCodesThreeDeviceMultiSyncAndBlobs(t *testing.T) {
	stMac1, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer stMac1.Close()

	stMac2, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer stMac2.Close()

	stAndroid, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer stAndroid.Close()

	// Each Mac keeps its own independent 6-digit code; Android has no server code.
	peerMac1 := whimsync.NewPeer(stMac1, "peer-mac1", "MacBook Pro", "111111")
	peerMac2 := whimsync.NewPeer(stMac2, "peer-mac2", "Mac Studio", "222222")
	peerAndroid := whimsync.NewPeer(stAndroid, "peer-android", "Pixel", "")
	peerMac1.SetDiscoveryPort(58789)
	peerMac2.SetDiscoveryPort(58789)
	peerAndroid.SetDiscoveryPort(58789)

	port1, err := peerMac1.StartServer(0, false)
	if err != nil {
		t.Fatalf("start mac1 server: %v", err)
	}
	defer peerMac1.StopServer()
	mac1Addr := fmt.Sprintf("127.0.0.1:%d", port1)

	port2, err := peerMac2.StartServer(0, false)
	if err != nil {
		t.Fatalf("start mac2 server: %v", err)
	}
	defer peerMac2.StopServer()
	mac2Addr := fmt.Sprintf("127.0.0.1:%d", port2)

	// Create notes + blobs on Mac #1, Mac #2, and Android
	mac1Img := []byte("\x89PNG\r\n\x1a\nmac1-image-payload")
	mac1Hash, _, mac1Size, err := stMac1.SaveBlob(mac1Img, "image/png")
	if err != nil {
		t.Fatal(err)
	}
	noteOnMac1, err := stMac1.CreateNote("Mac1 写的闪念 #工作/架构", []model.Attachment{
		{SHA256: mac1Hash, MIME: "image/png", SizeBytes: mac1Size},
	})
	if err != nil {
		t.Fatal(err)
	}

	noteOnMac2, err := stMac2.CreateNote("Mac2 写的想法 #生活/复盘", nil)
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

	// 1. Mac #2 pairs with Mac #1 using Mac #1's code (111111) -> Mac #2's own code MUST stay 222222!
	if _, err := peerMac2.PairAndSync(context.Background(), mac1Addr, "111111"); err != nil {
		t.Fatalf("mac2 pair with mac1 failed: %v", err)
	}
	if peerMac2.PairCode() != "222222" {
		t.Fatalf("mac2 own code was overwritten! got %s, want 222222", peerMac2.PairCode())
	}

	// 2. Android pairs with BOTH Mac #1 (111111) and Mac #2 (222222) concurrently
	if _, err := peerAndroid.PairAndSync(context.Background(), mac1Addr, "111111"); err != nil {
		t.Fatalf("android pair with mac1 failed: %v", err)
	}
	if _, err := peerAndroid.PairAndSync(context.Background(), mac2Addr, "222222"); err != nil {
		t.Fatalf("android pair with mac2 failed: %v", err)
	}

	// Verify Android has notes from both Macs and Mac #1's blob
	if _, err := stAndroid.GetNote(noteOnMac1.ID); err != nil {
		t.Fatalf("android missing mac1 note: %v", err)
	}
	if _, err := stAndroid.GetNote(noteOnMac2.ID); err != nil {
		t.Fatalf("android missing mac2 note: %v", err)
	}
	if _, _, err := stAndroid.ReadBlob(mac1Hash); err != nil {
		t.Fatalf("android missing mac1 blob: %v", err)
	}
	if _, _, err := stMac1.ReadBlob(andHash); err != nil {
		t.Fatalf("mac1 missing android blob: %v", err)
	}

	// 3. Concurrent field-level edits + SyncOnce across both Macs using each Mac's saved code
	newContent := "Mac1 更新了正文 #工作/架构/同步"
	if _, err := stMac1.UpdateNote(noteOnMac1.ID, &newContent, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	pinTrue := true
	if _, err := stAndroid.UpdateNote(noteOnMac1.ID, nil, &pinTrue, nil, nil); err != nil {
		t.Fatal(err)
	}

	sum := peerAndroid.SyncOnce(context.Background())
	if sum.PeersSynced != 2 {
		t.Fatalf("expected android to sync with both Macs, got %+v", sum)
	}
	gotMac1, _ := stMac1.GetNote(noteOnMac1.ID)
	gotAnd, _ := stAndroid.GetNote(noteOnMac1.ID)
	if gotMac1.Content != newContent || !gotMac1.Pinned {
		t.Fatalf("mac1 did not preserve concurrent edits: %+v", gotMac1)
	}
	if gotAnd.Content != newContent || !gotAnd.Pinned {
		t.Fatalf("android did not preserve concurrent edits: %+v", gotAnd)
	}

	// 4. Tombstone deletion propagates
	delTrue := true
	if _, err := stAndroid.UpdateNote(noteOnAndroid.ID, nil, nil, nil, &delTrue); err != nil {
		t.Fatal(err)
	}
	peerAndroid.SyncOnce(context.Background())
	gotDeletedOnMac1, _ := stMac1.GetNote(noteOnAndroid.ID)
	if !gotDeletedOnMac1.Deleted {
		t.Fatalf("expected tombstone delete to propagate to Mac1")
	}

	// 5. Health check reports both Macs online on Android
	health := peerAndroid.CheckSyncHealth(context.Background(), true)
	if !health.Connected || health.OnlinePeers != 2 {
		t.Fatalf("expected 2 online peers on android, got %+v", health)
	}
}

func TestPerClientLockoutIsolation(t *testing.T) {
	auth := whimsync.NewAuth("123456")

	// Attacker IP fails 5 times -> locked
	for i := 0; i < 5; i++ {
		nonce := auth.IssueNonce()
		res := auth.VerifyFrom("192.168.1.99", nonce, whimsync.ComputeProof("000000", nonce))
		if i < 4 && res.Locked {
			t.Fatalf("attempt %d should not lock yet", i+1)
		}
		if i == 4 && !res.Locked {
			t.Fatalf("5th attempt should lock attacker IP")
		}
	}

	// Legitimate device from another IP is NOT locked out!
	goodNonce := auth.IssueNonce()
	goodRes := auth.VerifyFrom("192.168.1.10", goodNonce, whimsync.ComputeProof("123456", goodNonce))
	if !goodRes.OK || goodRes.Locked {
		t.Fatalf("legitimate client should not be affected by attacker IP lockout: %+v", goodRes)
	}
}

func TestPairingCodeLockoutAfterFiveFailures(t *testing.T) {
	stMac, _ := store.Open(t.TempDir())
	defer stMac.Close()
	stBad, _ := store.Open(t.TempDir())
	defer stBad.Close()

	peerMac := whimsync.NewPeer(stMac, "peer-mac", "Mac", "123456")
	peerBad := whimsync.NewPeer(stBad, "peer-bad", "Intruder", "")
	peerMac.SetDiscoveryPort(58791)
	peerBad.SetDiscoveryPort(58791)

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
		t.Fatalf("expected lockout error on 5th failed attempt, got: %v", lastErr)
	}
}

func TestBidirectionalUnpairOnlineAndOfflineRePair(t *testing.T) {
	stMac, _ := store.Open(t.TempDir())
	defer stMac.Close()
	stAndroid, _ := store.Open(t.TempDir())
	defer stAndroid.Close()

	peerMac := whimsync.NewPeer(stMac, "peer-mac", "MacBook", "654321")
	peerAndroid := whimsync.NewPeer(stAndroid, "peer-android", "Android", "")
	peerMac.SetDiscoveryPort(58792)
	peerAndroid.SetDiscoveryPort(58792)

	port, err := peerMac.StartServer(0, false)
	if err != nil {
		t.Fatal(err)
	}
	defer peerMac.StopServer()
	defer peerAndroid.StopServer()
	macAddr := fmt.Sprintf("127.0.0.1:%d", port)

	// 1. Pair Android -> Mac
	if _, err := peerAndroid.PairAndSync(context.Background(), macAddr, "654321"); err != nil {
		t.Fatalf("initial pair failed: %v", err)
	}
	// Verify both sides have each other in sync_peers
	macPeers, _ := stMac.ListSyncPeers()
	andPeers, _ := stAndroid.ListSyncPeers()
	if len(macPeers) != 1 || len(andPeers) != 1 {
		t.Fatalf("expected 1 peer on each side, got mac=%d android=%d", len(macPeers), len(andPeers))
	}

	// 2. Client-initiated unpair (Android unpairs Mac) -> Mac also removes Android immediately!
	if err := peerAndroid.UnpairPeer(context.Background(), "peer-mac"); err != nil {
		t.Fatalf("android unpair failed: %v", err)
	}
	macPeers, _ = stMac.ListSyncPeers()
	andPeers, _ = stAndroid.ListSyncPeers()
	if len(andPeers) != 0 {
		t.Fatalf("expected android sync_peers empty after unpair, got %+v", andPeers)
	}
	if len(macPeers) != 0 {
		t.Fatalf("expected mac sync_peers empty after client unpair, got %+v", macPeers)
	}

	// 3. Re-pair cleanly via PairAndSync
	if _, err := peerAndroid.PairAndSync(context.Background(), macAddr, "654321"); err != nil {
		t.Fatalf("re-pair after client unpair failed: %v", err)
	}

	// Wait briefly for Android's SSE stream to connect to Mac
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		h := peerMac.CheckSyncHealth(context.Background(), false)
		if h.OnlinePeers == 1 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	// 4. Server-initiated unpair while Android is online (Mac unpairs Android) ->
	// Mac pushes SSE `event: unpair` and records Android in revoked_peers; Android removes Mac automatically!
	if err := peerMac.UnpairPeer(context.Background(), "peer-android"); err != nil {
		t.Fatalf("mac unpair failed: %v", err)
	}

	// Wait for Android to process SSE `event: unpair` (or 410 Gone on SyncOnce)
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		peers, _ := stAndroid.ListSyncPeers()
		if len(peers) == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	andPeers, _ = stAndroid.ListSyncPeers()
	if len(andPeers) != 0 {
		t.Fatalf("expected android to auto-remove mac after server SSE unpair, got %+v", andPeers)
	}

	// 5. Simulate offline client that still has Mac in sync_peers attempting SyncOnce ->
	// Mac returns HTTP 410 Gone and Android auto-removes Mac so it stops wasting network!
	_ = stAndroid.UpsertSyncPeer(model.SyncPeer{
		PeerID:      "peer-mac",
		DisplayName: "MacBook",
		LastAddr:    macAddr,
		PairCode:    "654321",
	})
	_ = peerAndroid.SyncOnce(context.Background())
	andPeers, _ = stAndroid.ListSyncPeers()
	if len(andPeers) != 0 {
		t.Fatalf("expected android to auto-remove mac on 410 Gone, got %+v", andPeers)
	}

	// 6. Explicit re-pair via PairAndSync clears revoked status on Mac and succeeds!
	if _, err := peerAndroid.PairAndSync(context.Background(), macAddr, "654321"); err != nil {
		t.Fatalf("explicit re-pair after server unpair should succeed, got: %v", err)
	}
	andPeers, _ = stAndroid.ListSyncPeers()
	if len(andPeers) != 1 {
		t.Fatalf("expected android to have mac paired again, got %+v", andPeers)
	}
}
