package sync

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"whim/core/model"
	"whim/core/store"
)

const (
	clockMarginMs    = int64(5 * 60 * 1000) // 5 minutes clock skew margin
	maxBlobBytes     = 32 * 1024 * 1024     // 32 MB per pasted image
	syncBatchLimit   = 500                  // max notes per /sync/exchange HTTP batch
	metaRevokedPeers = "whim.revoked_peers"
)

// ErrPeerUnpaired is returned when the remote peer explicitly unpaired this device (HTTP 410 Gone).
var ErrPeerUnpaired = errors.New("unpaired")

type pairedOutboundTarget struct {
	peerID      string
	displayName string
	addr        string
	code        string
}

type unpairRequest struct {
	PeerID string `json:"peer_id"`
}

// Peer manages both incoming peer sync requests (authenticated against THIS device's own localCode)
// and outgoing bidirectional sync exchanges (authenticated against EACH remote peer's own code).
type Peer struct {
	mu            sync.Mutex
	store         *store.Store
	auth          *Auth // verifies incoming requests using THIS device's own 6-digit code
	peerID        string
	displayName   string
	discoveryPort int

	server       *http.Server
	httpPort     int
	cancelServe  context.CancelFunc
	client       *http.Client
	streamClient *http.Client // no timeout for long-lived SSE push streams

	revokedMu     sync.Mutex
	revokedLoaded bool
	revokedPeers  map[string]bool

	sseMu          sync.Mutex
	sseSubs        map[*sseSubscriber]struct{}
	activeSSEPeers map[string]int64              // peerID -> connected unix ms
	peerLiveness   map[string]*peerLiveRecord    // peerID -> last verified ping/pong
	pendingPings   map[string]*pendingPing       // pingID -> in-flight SSE ping waiter
	sseStreams     map[string]context.CancelFunc // peerID -> active outbound SSE cancel
	localChanged   chan struct{}
	remoteChanged  chan struct{}
	sseReconnect   chan struct{}
	sseStarted     bool
	sseCancel      context.CancelFunc
	dataVersion    atomic.Int64
}

// NewPeer constructs a Peer attached to a local Store.
func NewPeer(st *store.Store, peerID, displayName, localCode string) *Peer {
	apiTransport := &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   2 * time.Second,
			KeepAlive: 15 * time.Second,
		}).DialContext,
		MaxIdleConns:        16,
		IdleConnTimeout:     30 * time.Second,
		TLSHandshakeTimeout: 3 * time.Second,
	}
	streamTransport := &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   3 * time.Second,
			KeepAlive: 15 * time.Second,
		}).DialContext,
		ResponseHeaderTimeout: 5 * time.Second,
		DisableKeepAlives:     true,
	}
	return &Peer{
		store:         st,
		auth:          NewAuth(localCode),
		peerID:        peerID,
		displayName:   displayName,
		discoveryPort: DefaultDiscoveryPort,
		client: &http.Client{
			Timeout:   10 * time.Second,
			Transport: apiTransport,
		},
		streamClient: &http.Client{
			Transport: streamTransport,
		},
		revokedPeers:   make(map[string]bool),
		sseSubs:        make(map[*sseSubscriber]struct{}),
		activeSSEPeers: make(map[string]int64),
		peerLiveness:   make(map[string]*peerLiveRecord),
		pendingPings:   make(map[string]*pendingPing),
		sseStreams:     make(map[string]context.CancelFunc),
		localChanged:   make(chan struct{}, 1),
		remoteChanged:  make(chan struct{}, 1),
		sseReconnect:   make(chan struct{}, 1),
	}
}

func (p *Peer) loadRevokedLocked() {
	if p.revokedLoaded {
		return
	}
	p.revokedLoaded = true
	if raw, err := p.store.GetMeta(metaRevokedPeers); err == nil && raw != "" {
		var ids []string
		if json.Unmarshal([]byte(raw), &ids) == nil {
			for _, id := range ids {
				if id != "" {
					p.revokedPeers[id] = true
				}
			}
		}
	}
}

func (p *Peer) saveRevokedLocked() {
	ids := make([]string, 0, len(p.revokedPeers))
	for id := range p.revokedPeers {
		ids = append(ids, id)
	}
	if b, err := json.Marshal(ids); err == nil {
		_ = p.store.SetMeta(metaRevokedPeers, string(b))
	}
}

func (p *Peer) isPeerRevoked(peerID string) bool {
	if peerID == "" {
		return false
	}
	p.revokedMu.Lock()
	defer p.revokedMu.Unlock()
	p.loadRevokedLocked()
	return p.revokedPeers[peerID]
}

func (p *Peer) addRevokedPeer(peerID string) {
	if peerID == "" {
		return
	}
	p.revokedMu.Lock()
	defer p.revokedMu.Unlock()
	p.loadRevokedLocked()
	if !p.revokedPeers[peerID] {
		p.revokedPeers[peerID] = true
		p.saveRevokedLocked()
	}
}

func (p *Peer) clearRevokedPeer(peerID string) {
	if peerID == "" {
		return
	}
	p.revokedMu.Lock()
	defer p.revokedMu.Unlock()
	p.loadRevokedLocked()
	if p.revokedPeers[peerID] {
		delete(p.revokedPeers, peerID)
		p.saveRevokedLocked()
	}
}

// DataVersion returns a monotonically increasing version bumped on every local write or remote merge.
func (p *Peer) DataVersion() int64 {
	return p.dataVersion.Load()
}

// ReconnectEvents tears down existing outbound SSE streams and wakes the supervisor
// so newly paired hosts connect immediately and unpaired hosts stay disconnected.
func (p *Peer) ReconnectEvents() {
	p.sseMu.Lock()
	cancels := make([]context.CancelFunc, 0, len(p.sseStreams))
	for _, cancel := range p.sseStreams {
		if cancel != nil {
			cancels = append(cancels, cancel)
		}
	}
	p.sseMu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
	select {
	case p.sseReconnect <- struct{}{}:
	default:
	}
}

func (p *Peer) stopOutboundSSE(peerID string) {
	if peerID == "" {
		return
	}
	p.sseMu.Lock()
	cancel := p.sseStreams[peerID]
	delete(p.sseStreams, peerID)
	p.sseMu.Unlock()
	if cancel != nil {
		cancel()
	}
	select {
	case p.sseReconnect <- struct{}{}:
	default:
	}
}

// NotifyChanged wakes local UI listeners and pushes an instant SSE event to all connected clients.
func (p *Peer) NotifyChanged() {
	p.dataVersion.Add(1)
	select {
	case p.localChanged <- struct{}{}:
	default:
	}
	p.sseMu.Lock()
	for sub := range p.sseSubs {
		select {
		case sub.changedCh <- struct{}{}:
		default:
		}
	}
	p.sseMu.Unlock()
}

// WaitForChange blocks until either a local incoming sync push or a remote SSE push arrives,
// or timeoutSec elapses. Returns true if woken by a real-time change.
func (p *Peer) WaitForChange(timeoutSec int) bool {
	if timeoutSec <= 0 {
		timeoutSec = 25
	}
	p.ensureEventSubscriber()
	timer := time.NewTimer(time.Duration(timeoutSec) * time.Second)
	defer timer.Stop()
	select {
	case <-p.localChanged:
		return true
	case <-p.remoteChanged:
		return true
	case <-timer.C:
		return false
	}
}

// PeerID returns this device's unique peer ID.
func (p *Peer) PeerID() string { return p.peerID }

// DisplayName returns this device's display name.
func (p *Peer) DisplayName() string { return p.displayName }

// PairCode returns THIS device's own 6-digit sync code (never overwritten when pairing with other devices).
func (p *Peer) PairCode() string { return p.auth.Code() }

// SetPairCode updates THIS device's own 6-digit sync code (e.g., when regenerating).
func (p *Peer) SetPairCode(code string) { p.auth.SetCode(code) }

// SetDiscoveryPort overrides the UDP discovery port (useful for isolated tests).
func (p *Peer) SetDiscoveryPort(port int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.discoveryPort = port
}

// HTTPPort returns the bound HTTP listen port (0 if server is not running).
func (p *Peer) HTTPPort() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.httpPort
}

// StartServer starts the HTTP sync server and UDP discovery responder idempotently.
func (p *Peer) StartServer(httpPort int, enableDiscovery bool) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.server != nil {
		return p.httpPort, nil
	}

	ln, err := net.Listen("tcp4", fmt.Sprintf("0.0.0.0:%d", httpPort))
	if err != nil {
		return 0, err
	}
	actualPort := ln.Addr().(*net.TCPAddr).Port

	mux := http.NewServeMux()
	mux.HandleFunc("/health", p.handleHealth)
	mux.HandleFunc("/sync/challenge", p.handleChallenge)
	mux.HandleFunc("/sync/exchange", p.handleExchange)
	mux.HandleFunc("/sync/events", p.handleEvents)
	mux.HandleFunc("/sync/ping", p.handlePing)
	mux.HandleFunc("/sync/pong", p.handlePong)
	mux.HandleFunc("/sync/unpair", p.handleUnpair)
	mux.HandleFunc("/sync/blobs/", p.handleBlob)

	srv := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	ctx, cancel := context.WithCancel(context.Background())
	p.server = srv
	p.httpPort = actualPort
	p.cancelServe = cancel

	go func() {
		_ = srv.Serve(ln)
	}()

	if enableDiscovery {
		discPort := p.discoveryPort
		go func() {
			_ = ServeDiscovery(ctx, discPort, p.peerID, p.displayName, actualPort)
		}()
	}

	return actualPort, nil
}

// StopServer shuts down the HTTP listener, UDP discovery responder, and SSE subscriber.
func (p *Peer) StopServer() error {
	p.mu.Lock()
	srv := p.server
	cancel := p.cancelServe
	sseCancel := p.sseCancel
	p.server = nil
	p.httpPort = 0
	p.cancelServe = nil
	p.sseCancel = nil
	p.sseStarted = false
	p.mu.Unlock()

	if sseCancel != nil {
		sseCancel()
	}
	if cancel != nil {
		cancel()
	}
	if srv != nil {
		ctx, c := context.WithTimeout(context.Background(), 2*time.Second)
		defer c()
		return srv.Shutdown(ctx)
	}
	return nil
}

// DiscoverLAN scans the local Wi-Fi network and returns online Whim devices with paired status.
func (p *Peer) DiscoverLAN(ctx context.Context) ([]model.DiscoveredPeerInfo, error) {
	p.mu.Lock()
	discPort := p.discoveryPort
	p.mu.Unlock()

	discovered, err := DiscoverPeers(ctx, discPort, p.peerID, 700*time.Millisecond)
	if err != nil {
		return nil, err
	}
	pairedList, _ := p.store.ListSyncPeers()
	pairedSet := make(map[string]bool, len(pairedList))
	for _, sp := range pairedList {
		if sp.PeerID != "" {
			pairedSet[sp.PeerID] = true
		}
	}

	out := make([]model.DiscoveredPeerInfo, 0, len(discovered))
	for _, d := range discovered {
		out = append(out, model.DiscoveredPeerInfo{
			PeerID:      d.PeerID,
			DisplayName: d.DisplayName,
			Addr:        d.Addr,
			Paired:      pairedSet[d.PeerID],
		})
	}
	return out, nil
}

// PairAndSync connects to a specific remote peer using THAT peer's 6-digit code,
// performs a full bidirectional sync, and saves that peer + its code in sync_peers.
// Note: This NEVER modifies THIS device's own local sync code.
func (p *Peer) PairAndSync(ctx context.Context, addr, remoteCode string) (model.SyncSummary, error) {
	norm := NormalizeCode(remoteCode)
	if len(norm) != 6 {
		return model.SyncSummary{}, errors.New("对方配对码必须是 6 位数字")
	}
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return model.SyncSummary{}, errors.New("请先选择发现的设备或输入 IP:端口")
	}
	if !strings.Contains(addr, ":") {
		addr = fmt.Sprintf("%s:%d", addr, DefaultHTTPPort)
	}

	merged, dl, ul, remotePeerID, err := p.syncWithAddrInternal(ctx, addr, "", norm, true)
	if err != nil {
		return model.SyncSummary{}, err
	}
	if remotePeerID != "" {
		p.clearRevokedPeer(remotePeerID)
	}
	// Ensure background SSE supervisor immediately subscribes to this newly paired host.
	p.ensureEventSubscriber()
	select {
	case p.sseReconnect <- struct{}{}:
	default:
	}

	return model.SyncSummary{
		PeersFound:      1,
		PeersSynced:     1,
		NotesMerged:     merged,
		BlobsDownloaded: dl,
		BlobsUploaded:   ul,
	}, nil
}

// UnpairPeer removes a paired peer locally, tears down its SSE stream, records it as revoked
// so offline reconnects get 410 Gone, and notifies the remote peer immediately if reachable.
func (p *Peer) UnpairPeer(ctx context.Context, peerID string) error {
	peerID = strings.TrimSpace(peerID)
	if peerID == "" {
		return nil
	}
	sp, _ := p.store.GetSyncPeer(peerID)

	// 1. Mark revoked locally so any future reconnect from this peer returns 410 Gone
	// until the user explicitly re-pairs.
	p.addRevokedPeer(peerID)

	// 2. Delete from local sync_peers table.
	_ = p.store.DeleteSyncPeer(peerID)

	// 3. Clear liveness / active SSE maps & notify any online inbound SSE streams for this peer.
	p.sseMu.Lock()
	delete(p.peerLiveness, peerID)
	if sp != nil && sp.LastAddr != "" {
		delete(p.peerLiveness, "addr:"+sp.LastAddr)
	}
	delete(p.activeSSEPeers, peerID)
	var inboundSubs []*sseSubscriber
	for sub := range p.sseSubs {
		if sub.peerID == peerID {
			inboundSubs = append(inboundSubs, sub)
		}
	}
	p.sseMu.Unlock()

	for _, sub := range inboundSubs {
		select {
		case sub.unpairCh <- p.peerID:
		default:
			sub.close()
		}
	}

	// 4. Stop any outbound SSE goroutine targeting this peer.
	p.stopOutboundSSE(peerID)

	// 5. If this was an outbound paired host, send best-effort authenticated POST /sync/unpair.
	if sp != nil && len(NormalizeCode(sp.PairCode)) == 6 && strings.Contains(sp.LastAddr, ":") {
		unpairCtx, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
		defer cancel()
		addr := sp.LastAddr
		// Check if UDP discovery sees this peer on a fresher IP
		p.mu.Lock()
		discPort := p.discoveryPort
		p.mu.Unlock()
		if disc, err := DiscoverPeers(unpairCtx, discPort, p.peerID, 300*time.Millisecond); err == nil {
			for _, d := range disc {
				if d.PeerID == peerID && d.Addr != "" {
					addr = d.Addr
					break
				}
			}
		}
		_, _ = p.authedRequest(
			unpairCtx,
			http.MethodPost,
			"http://"+addr+"/sync/unpair",
			unpairRequest{PeerID: p.peerID},
			"application/json",
			sp.PairCode,
		)
	}

	// 6. Wake local UI so the removed device disappears immediately.
	p.NotifyChanged()
	return nil
}

// handleRemoteUnpaired cleans up local pairing state when the remote peer tells us
// (via POST /sync/unpair, SSE event: unpair, or HTTP 410 Gone) that it disconnected us.
func (p *Peer) handleRemoteUnpaired(peerID, addr string) {
	peerID = strings.TrimSpace(peerID)
	addr = strings.TrimSpace(addr)

	if peerID == "" && addr != "" {
		if saved, err := p.store.ListSyncPeers(); err == nil {
			for _, sp := range saved {
				if sp.LastAddr == addr {
					peerID = sp.PeerID
					break
				}
			}
		}
	}

	if peerID != "" {
		_ = p.store.DeleteSyncPeer(peerID)
	}

	p.sseMu.Lock()
	if peerID != "" {
		delete(p.peerLiveness, peerID)
		delete(p.activeSSEPeers, peerID)
	}
	if addr != "" {
		delete(p.peerLiveness, "addr:"+addr)
	}
	var inboundSubs []*sseSubscriber
	for sub := range p.sseSubs {
		if peerID != "" && sub.peerID == peerID {
			inboundSubs = append(inboundSubs, sub)
		}
	}
	p.sseMu.Unlock()

	for _, sub := range inboundSubs {
		sub.close()
	}
	if peerID != "" {
		p.stopOutboundSSE(peerID)
	}
	log.Printf("[whim-sync] remote peer unpaired us: peer=%s addr=%s (stopped reconnecting)", peerID, addr)
	p.NotifyChanged()
}

// findPairedOutboundTargets returns all paired remote server hosts (sync_peers entries with a
// 6-digit remote pair_code and host:port address), resolving fresh IPs via UDP discovery if available.
func (p *Peer) findPairedOutboundTargets(ctx context.Context) []pairedOutboundTarget {
	savedPeers, err := p.store.ListSyncPeers()
	if err != nil || len(savedPeers) == 0 {
		return nil
	}

	var outbound []model.SyncPeer
	for _, sp := range savedPeers {
		if sp.PeerID == "" || sp.PeerID == p.peerID {
			continue
		}
		if len(NormalizeCode(sp.PairCode)) == 6 && strings.Contains(sp.LastAddr, ":") {
			outbound = append(outbound, sp)
		}
	}
	if len(outbound) == 0 {
		return nil
	}

	p.mu.Lock()
	discPort := p.discoveryPort
	p.mu.Unlock()

	discoveredByID := make(map[string]DiscoveredPeer)
	if discovered, derr := DiscoverPeers(ctx, discPort, p.peerID, 500*time.Millisecond); derr == nil {
		for _, d := range discovered {
			if d.PeerID != "" {
				discoveredByID[d.PeerID] = d
			}
		}
	}

	targets := make([]pairedOutboundTarget, 0, len(outbound))
	for _, sp := range outbound {
		addr := sp.LastAddr
		name := sp.DisplayName
		if d, ok := discoveredByID[sp.PeerID]; ok {
			if d.Addr != "" && d.Addr != addr {
				addr = d.Addr
				_ = p.store.UpsertSyncPeer(model.SyncPeer{
					PeerID:      sp.PeerID,
					DisplayName: d.DisplayName,
					LastAddr:    addr,
					PairCode:    sp.PairCode,
				})
			}
			if d.DisplayName != "" {
				name = d.DisplayName
			}
		}
		targets = append(targets, pairedOutboundTarget{
			peerID:      sp.PeerID,
			displayName: name,
			addr:        addr,
			code:        NormalizeCode(sp.PairCode),
		})
	}
	return targets
}

// SyncOnce performs bidirectional sync ONLY with paired outbound peers (using each peer's
// own saved 6-digit code) and reports status of inbound connected clients.
// It NEVER sends auth requests to unpaired LAN devices.
func (p *Peer) SyncOnce(ctx context.Context) model.SyncSummary {
	var summary model.SyncSummary

	targets := p.findPairedOutboundTargets(ctx)
	summary.PeersFound = len(targets)

	seenPeerIDs := make(map[string]bool, len(targets))
	seenAddrs := make(map[string]bool, len(targets))
	for _, t := range targets {
		if t.peerID != "" {
			seenPeerIDs[t.peerID] = true
		}
		if t.addr != "" {
			seenAddrs[t.addr] = true
		}
	}

	// Sync all paired outbound peers concurrently so an offline peer never delays live peers.
	var (
		wg    sync.WaitGroup
		resMu sync.Mutex
	)
	for _, t := range targets {
		t := t
		wg.Add(1)
		go func() {
			defer wg.Done()
			merged, dl, ul, _, serr := p.syncWithAddrInternal(ctx, t.addr, t.peerID, t.code, false)
			if errors.Is(serr, ErrPeerUnpaired) {
				p.handleRemoteUnpaired(t.peerID, t.addr)
				return
			}
			resMu.Lock()
			defer resMu.Unlock()
			if serr != nil {
				errStr := serr.Error()
				status := "error"
				msg := errStr
				switch {
				case strings.Contains(errStr, "配对码不正确") || strings.Contains(errStr, "unauthorized"):
					status = "wrong_code"
					msg = "对方配对码已更换，请重新配对"
				case strings.Contains(errStr, "locked"):
					status = "locked"
					msg = "尝试太多次，稍后再试"
				}
				summary.Peers = append(summary.Peers, model.PeerSyncStatus{
					PeerID:      t.peerID,
					DisplayName: t.displayName,
					Addr:        t.addr,
					Status:      status,
					Message:     msg,
				})
				summary.Errors = append(summary.Errors, fmt.Sprintf("%s: %s", t.addr, msg))
				return
			}
			summary.PeersSynced++
			summary.NotesMerged += merged
			summary.BlobsDownloaded += dl
			summary.BlobsUploaded += ul
			summary.Peers = append(summary.Peers, model.PeerSyncStatus{
				PeerID:      t.peerID,
				DisplayName: t.displayName,
				Addr:        t.addr,
				Status:      "synced",
				Message:     "已同步",
			})
		}()
	}
	wg.Wait()

	// Also include inbound client devices (e.g. Android phones) recorded in SQLite sync_peers
	// so the Mac displays all paired devices across restarts even though phones do not serve UDP.
	if savedPeers, err := p.store.ListSyncPeers(); err == nil {
		nowMs := time.Now().UnixMilli()
		p.sseMu.Lock()
		activeCopy := make(map[string]int64, len(p.activeSSEPeers))
		for k, v := range p.activeSSEPeers {
			activeCopy[k] = v
		}
		p.sseMu.Unlock()

		for _, sp := range savedPeers {
			if sp.PeerID == "" || sp.PeerID == p.peerID || seenPeerIDs[sp.PeerID] || (sp.LastAddr != "" && seenAddrs[sp.LastAddr]) {
				continue
			}
			seenPeerIDs[sp.PeerID] = true
			if sp.LastAddr != "" {
				seenAddrs[sp.LastAddr] = true
			}
			summary.PeersFound++
			_, sseOnline := activeCopy[sp.PeerID]
			recentlySynced := sp.LastSyncAt > 0 && (nowMs-sp.LastSyncAt) < 90_000
			msg := "已同步"
			if sseOnline || recentlySynced {
				summary.PeersSynced++
				msg = "在线 · 已同步"
			} else if sp.LastSyncAt > 0 {
				msg = "上次同步 " + time.UnixMilli(sp.LastSyncAt).Format("15:04")
			}
			name := sp.DisplayName
			if name == "" {
				name = "已连接设备"
			}
			summary.Peers = append(summary.Peers, model.PeerSyncStatus{
				PeerID:      sp.PeerID,
				DisplayName: name,
				Addr:        sp.LastAddr,
				Status:      "synced",
				Message:     msg,
			})
		}
	}
	return summary
}

// SyncWithAddr runs a full authenticated bidirectional sync with one specific peer using remoteCode.
func (p *Peer) SyncWithAddr(ctx context.Context, addr, knownPeerID, remoteCode string) (notesMerged, blobsDown, blobsUp int, err error) {
	m, dl, ul, _, serr := p.syncWithAddrInternal(ctx, addr, knownPeerID, remoteCode, false)
	return m, dl, ul, serr
}

func (p *Peer) syncWithAddrInternal(ctx context.Context, addr, knownPeerID, remoteCode string, isExplicitPair bool) (notesMerged, blobsDown, blobsUp int, remotePeerID string, err error) {
	baseURL := "http://" + addr

	var since int64
	if knownPeerID != "" {
		if sp, gerr := p.store.GetSyncPeer(knownPeerID); gerr == nil && sp != nil && sp.LastHeardAt > clockMarginMs {
			since = sp.LastHeardAt - clockMarginMs
		}
	}

	var extraHeaders map[string]string
	if isExplicitPair {
		extraHeaders = map[string]string{HeaderPairIntent: "1"}
	}

	haveBlobs, _ := p.store.ListLocalBlobs()
	wantSet := make(map[string]struct{})
	var lastResp model.SyncExchangeResponse
	totalMerged := 0

	localSince := since
	localAfterID := ""
	for {
		localNotes, localAtts, nextLocalSince, nextLocalAfterID, localHasMore, lerr := p.store.ListChangesSincePaged(localSince, localAfterID, syncBatchLimit)
		if lerr != nil {
			return 0, 0, 0, "", lerr
		}
		reqBody := model.SyncExchangeRequest{
			PeerID:      p.peerID,
			DisplayName: p.displayName,
			Since:       since,
			BatchLimit:  syncBatchLimit,
			SkipPull:    localHasMore,
			Notes:       localNotes,
			Attachments: localAtts,
		}
		if !localHasMore {
			reqBody.HaveBlobs = haveBlobs
		}
		respBytes, rerr := p.authedRequestWithHeaders(ctx, http.MethodPost, baseURL+"/sync/exchange", reqBody, "application/json", remoteCode, extraHeaders)
		if rerr != nil {
			return 0, 0, 0, "", rerr
		}
		var resp model.SyncExchangeResponse
		if uerr := json.Unmarshal(respBytes, &resp); uerr != nil {
			return 0, 0, 0, "", fmt.Errorf("decode exchange response: %w", uerr)
		}
		lastResp = resp
		for _, w := range resp.WantBlobs {
			wantSet[w] = struct{}{}
		}
		if len(resp.Notes) > 0 || len(resp.Attachments) > 0 {
			m, merr := p.store.MergeRemote(resp.Notes, resp.Attachments)
			if merr != nil {
				return 0, 0, 0, "", merr
			}
			totalMerged += m
		}
		if !localHasMore {
			break
		}
		localSince = nextLocalSince
		localAfterID = nextLocalAfterID
	}

	for lastResp.HasMore && lastResp.NextAfterID != "" {
		reqBody := model.SyncExchangeRequest{
			PeerID:      p.peerID,
			DisplayName: p.displayName,
			Since:       lastResp.NextSince,
			AfterID:     lastResp.NextAfterID,
			BatchLimit:  syncBatchLimit,
		}
		respBytes, rerr := p.authedRequestWithHeaders(ctx, http.MethodPost, baseURL+"/sync/exchange", reqBody, "application/json", remoteCode, extraHeaders)
		if rerr != nil {
			return 0, 0, 0, "", rerr
		}
		var resp model.SyncExchangeResponse
		if uerr := json.Unmarshal(respBytes, &resp); uerr != nil {
			return 0, 0, 0, "", fmt.Errorf("decode exchange response: %w", uerr)
		}
		lastResp = resp
		if len(resp.Notes) > 0 || len(resp.Attachments) > 0 {
			m, merr := p.store.MergeRemote(resp.Notes, resp.Attachments)
			if merr != nil {
				return 0, 0, 0, "", merr
			}
			totalMerged += m
		}
	}

	missing, _ := p.store.MissingBlobs()
	for _, hash := range missing {
		data, mime, derr := p.downloadBlob(ctx, baseURL, hash, remoteCode)
		if derr == nil && len(data) > 0 {
			if _, _, _, serr := p.store.SaveBlob(data, mime); serr == nil {
				blobsDown++
			}
		}
	}

	for hash := range wantSet {
		data, mime, rerr := p.store.ReadBlob(hash)
		if rerr != nil {
			continue
		}
		if uerr := p.uploadBlob(ctx, baseURL, hash, data, mime, remoteCode); uerr == nil {
			blobsUp++
		}
	}

	now := time.Now().UnixMilli()
	heard := lastResp.ServerTime
	if heard <= 0 {
		heard = now
	}
	if lastResp.PeerID != "" {
		_ = p.store.UpsertSyncPeer(model.SyncPeer{
			PeerID:      lastResp.PeerID,
			DisplayName: lastResp.DisplayName,
			LastAddr:    addr,
			PairCode:    NormalizeCode(remoteCode),
			LastHeardAt: heard,
			LastSyncAt:  now,
		})
		p.recordPeerAlive(lastResp.PeerID, lastResp.DisplayName, addr, -1)
	}

	if totalMerged > 0 || blobsDown > 0 {
		p.NotifyChanged()
	}

	return totalMerged, blobsDown, blobsUp, lastResp.PeerID, nil
}

func (p *Peer) fetchNonce(ctx context.Context, baseURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/sync/challenge", nil)
	if err != nil {
		return "", err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("challenge status %d", resp.StatusCode)
	}
	var payload struct {
		Nonce string `json:"nonce"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if payload.Nonce == "" {
		return "", errors.New("empty nonce")
	}
	return payload.Nonce, nil
}

func (p *Peer) authedRequest(ctx context.Context, method, fullURL string, body any, contentType, remoteCode string) ([]byte, error) {
	return p.authedRequestWithHeaders(ctx, method, fullURL, body, contentType, remoteCode, nil)
}

func (p *Peer) authedRequestWithHeaders(ctx context.Context, method, fullURL string, body any, contentType, remoteCode string, extraHeaders map[string]string) ([]byte, error) {
	idx := strings.Index(fullURL, "/sync/")
	if idx < 0 {
		return nil, errors.New("invalid sync url")
	}
	baseURL := fullURL[:idx]
	nonce, err := p.fetchNonce(ctx, baseURL)
	if err != nil {
		return nil, err
	}

	var reader io.Reader
	if body != nil {
		switch v := body.(type) {
		case []byte:
			reader = bytes.NewReader(v)
		default:
			b, err := json.Marshal(v)
			if err != nil {
				return nil, err
			}
			reader = bytes.NewReader(b)
		}
	}

	req, err := http.NewRequestWithContext(ctx, method, fullURL, reader)
	if err != nil {
		return nil, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	req.Header.Set(HeaderNonce, nonce)
	req.Header.Set(HeaderProof, ComputeProof(remoteCode, nonce))
	req.Header.Set(HeaderPeerID, p.peerID)
	for k, v := range extraHeaders {
		req.Header.Set(k, v)
	}

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxBlobBytes+1024))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusGone {
		return nil, ErrPeerUnpaired
	}
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, errors.New("配对码不正确")
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, fmt.Errorf("locked: 尝试次数过多，请稍后再试 (%s)", strings.TrimSpace(string(raw)))
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return raw, nil
}

func (p *Peer) downloadBlob(ctx context.Context, baseURL, hash, remoteCode string) ([]byte, string, error) {
	nonce, err := p.fetchNonce(ctx, baseURL)
	if err != nil {
		return nil, "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/sync/blobs/"+hash, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set(HeaderNonce, nonce)
	req.Header.Set(HeaderProof, ComputeProof(remoteCode, nonce))
	req.Header.Set(HeaderPeerID, p.peerID)

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusGone {
		return nil, "", ErrPeerUnpaired
	}
	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("blob get status %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBlobBytes))
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != hash {
		return nil, "", errors.New("blob sha256 mismatch")
	}
	mime := resp.Header.Get("Content-Type")
	if mime == "" {
		mime = "image/png"
	}
	return data, mime, nil
}

func (p *Peer) uploadBlob(ctx context.Context, baseURL, hash string, data []byte, mime, remoteCode string) error {
	_, err := p.authedRequest(ctx, http.MethodPut, baseURL+"/sync/blobs/"+hash, data, mime, remoteCode)
	return err
}

func (p *Peer) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func (p *Peer) handleChallenge(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	nonce := p.auth.IssueNonce()
	_ = json.NewEncoder(w).Encode(map[string]string{"nonce": nonce})
}

func (p *Peer) verifyRequest(w http.ResponseWriter, r *http.Request) bool {
	clientKey := clientIPFromAddr(r.RemoteAddr)
	res := p.auth.VerifyFrom(clientKey, r.Header.Get(HeaderNonce), r.Header.Get(HeaderProof))
	if !res.OK {
		if res.Locked {
			w.Header().Set("Retry-After", fmt.Sprintf("%d", res.RetryAfterSecond))
			http.Error(w, fmt.Sprintf("locked for %ds", res.RetryAfterSecond), http.StatusTooManyRequests)
			return false
		}
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return false
	}

	callerPeerID := strings.TrimSpace(r.Header.Get(HeaderPeerID))
	if callerPeerID != "" && p.isPeerRevoked(callerPeerID) {
		if r.URL.Path == "/sync/exchange" && r.Header.Get(HeaderPairIntent) == "1" {
			p.clearRevokedPeer(callerPeerID)
			return true
		}
		if r.URL.Path != "/sync/unpair" {
			http.Error(w, "unpaired", http.StatusGone)
			return false
		}
	}
	return true
}

func (p *Peer) handleUnpair(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !p.verifyRequest(w, r) {
		return
	}
	var req unpairRequest
	_ = json.NewDecoder(io.LimitReader(r.Body, 16*1024)).Decode(&req)
	targetPeerID := strings.TrimSpace(req.PeerID)
	if targetPeerID == "" {
		targetPeerID = strings.TrimSpace(r.Header.Get(HeaderPeerID))
	}
	p.handleRemoteUnpaired(targetPeerID, clientIPFromAddr(r.RemoteAddr))
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func (p *Peer) handleExchange(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !p.verifyRequest(w, r) {
		return
	}
	var req model.SyncExchangeRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 16*1024*1024)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}

	merged, err := p.store.MergeRemote(req.Notes, req.Attachments)
	if err != nil {
		http.Error(w, "merge error", http.StatusInternalServerError)
		return
	}
	if merged > 0 {
		p.NotifyChanged()
	}

	var (
		outNotes    []model.Note
		outAtts     []model.Attachment
		nextSince   int64
		nextAfterID string
		hasMore     bool
	)
	if !req.SkipPull {
		since := req.Since
		if since < 0 {
			since = 0
		}
		batchLimit := req.BatchLimit
		if batchLimit <= 0 || batchLimit > syncBatchLimit {
			batchLimit = syncBatchLimit
		}
		outNotes, outAtts, nextSince, nextAfterID, hasMore, err = p.store.ListChangesSincePaged(since, req.AfterID, batchLimit)
		if err != nil {
			http.Error(w, "read error", http.StatusInternalServerError)
			return
		}
	}

	var want []string
	if len(req.HaveBlobs) > 0 {
		missing, _ := p.store.MissingBlobs()
		senderHave := make(map[string]struct{}, len(req.HaveBlobs))
		for _, h := range req.HaveBlobs {
			senderHave[h] = struct{}{}
		}
		for _, m := range missing {
			if _, ok := senderHave[m]; ok {
				want = append(want, m)
			}
		}
	}

	now := time.Now().UnixMilli()
	if req.PeerID != "" {
		clientIP := clientIPFromAddr(r.RemoteAddr)
		_ = p.store.UpsertSyncPeer(model.SyncPeer{
			PeerID:      req.PeerID,
			DisplayName: req.DisplayName,
			LastAddr:    clientIP,
			LastHeardAt: now,
			LastSyncAt:  now,
		})
		p.recordPeerAlive(req.PeerID, req.DisplayName, clientIP, -1)
		select {
		case p.localChanged <- struct{}{}:
		default:
		}
	}

	resp := model.SyncExchangeResponse{
		PeerID:      p.peerID,
		DisplayName: p.displayName,
		ServerTime:  now,
		Notes:       outNotes,
		Attachments: outAtts,
		WantBlobs:   want,
		HasMore:     hasMore,
		NextSince:   nextSince,
		NextAfterID: nextAfterID,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (p *Peer) handleBlob(w http.ResponseWriter, r *http.Request) {
	if !p.verifyRequest(w, r) {
		return
	}
	hash := strings.TrimPrefix(r.URL.Path, "/sync/blobs/")
	if len(hash) != 64 {
		http.Error(w, "invalid hash", http.StatusBadRequest)
		return
	}
	switch r.Method {
	case http.MethodGet:
		data, mime, err := p.store.ReadBlob(hash)
		if err != nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", mime)
		_, _ = w.Write(data)
	case http.MethodPut:
		data, err := io.ReadAll(io.LimitReader(r.Body, maxBlobBytes))
		if err != nil {
			http.Error(w, "read error", http.StatusBadRequest)
			return
		}
		sum := sha256.Sum256(data)
		if hex.EncodeToString(sum[:]) != hash {
			http.Error(w, "sha256 mismatch", http.StatusBadRequest)
			return
		}
		mime := r.Header.Get("Content-Type")
		if mime == "" {
			mime = "image/png"
		}
		if _, _, _, err := p.store.SaveBlob(data, mime); err != nil {
			http.Error(w, "save error", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}
