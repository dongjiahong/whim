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
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"whim/core/model"
	"whim/core/store"
)

const (
	clockMarginMs = int64(5 * 60 * 1000) // 5 minutes clock skew margin
	maxBlobBytes  = 32 * 1024 * 1024     // 32 MB per pasted image
)

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

	sseMu          sync.Mutex
	sseSubs        map[chan struct{}]struct{}
	activeSSEPeers map[string]int64 // peerID -> connected unix ms
	localChanged   chan struct{}
	remoteChanged  chan struct{}
	sseStarted     bool
	sseCancel      context.CancelFunc
}

// NewPeer constructs a Peer attached to a local Store.
func NewPeer(st *store.Store, peerID, displayName, localCode string) *Peer {
	return &Peer{
		store:         st,
		auth:          NewAuth(localCode),
		peerID:        peerID,
		displayName:   displayName,
		discoveryPort: DefaultDiscoveryPort,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
		streamClient:   &http.Client{},
		sseSubs:        make(map[chan struct{}]struct{}),
		activeSSEPeers: make(map[string]int64),
		localChanged:   make(chan struct{}, 1),
		remoteChanged:  make(chan struct{}, 1),
	}
}

// NotifyChanged wakes local UI listeners and pushes an instant SSE event to all connected clients.
func (p *Peer) NotifyChanged() {
	select {
	case p.localChanged <- struct{}{}:
	default:
	}
	p.sseMu.Lock()
	for ch := range p.sseSubs {
		select {
		case ch <- struct{}{}:
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
		if sp.PairCode != "" {
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

	merged, dl, ul, err := p.SyncWithAddr(ctx, addr, "", norm)
	if err != nil {
		return model.SyncSummary{}, err
	}
	return model.SyncSummary{
		PeersFound:      1,
		PeersSynced:     1,
		NotesMerged:     merged,
		BlobsDownloaded: dl,
		BlobsUploaded:   ul,
	}, nil
}

// SyncOnce discovers all online LAN peers via UDP (plus optional manual fallback addrs)
// and performs bidirectional sync with every discovered peer using the library's 6-digit code.
func (p *Peer) SyncOnce(ctx context.Context) model.SyncSummary {
	var summary model.SyncSummary

	p.mu.Lock()
	discPort := p.discoveryPort
	p.mu.Unlock()

	code := p.auth.Code()
	discovered, _ := DiscoverPeers(ctx, discPort, p.peerID, 700*time.Millisecond)

	// Merge optional manual fallback addresses and previously known server hosts (host:port)
	// so Android never misses a sync even if a Wi-Fi UDP broadcast packet is dropped.
	type targetPeer struct {
		peerID      string
		displayName string
		addr        string
	}
	byAddr := make(map[string]targetPeer)
	for _, dp := range discovered {
		byAddr[dp.Addr] = targetPeer{peerID: dp.PeerID, displayName: dp.DisplayName, addr: dp.Addr}
	}
	if savedPeers, err := p.store.ListSyncPeers(); err == nil {
		for _, sp := range savedPeers {
			if sp.PeerID == p.peerID || !strings.Contains(sp.LastAddr, ":") {
				continue
			}
			if _, exists := byAddr[sp.LastAddr]; !exists {
				byAddr[sp.LastAddr] = targetPeer{
					peerID:      sp.PeerID,
					displayName: sp.DisplayName,
					addr:        sp.LastAddr,
				}
			}
		}
	}
	if rawManual, _ := p.store.GetMeta("whim.manual_addrs"); rawManual != "" {
		var addrs []string
		if json.Unmarshal([]byte(rawManual), &addrs) == nil {
			for _, a := range addrs {
				a = strings.TrimSpace(a)
				if a == "" {
					continue
				}
				if !strings.Contains(a, ":") {
					a = fmt.Sprintf("%s:%d", a, DefaultHTTPPort)
				}
				if _, exists := byAddr[a]; !exists {
					byAddr[a] = targetPeer{displayName: "手动设备", addr: a}
				}
			}
		}
	}

	summary.PeersFound = len(byAddr)
	seenPeerIDs := make(map[string]bool)
	seenAddrs := make(map[string]bool)
	for _, t := range byAddr {
		if t.peerID != "" {
			seenPeerIDs[t.peerID] = true
		}
		if t.addr != "" {
			seenAddrs[t.addr] = true
		}
		if len(NormalizeCode(code)) != 6 {
			summary.Peers = append(summary.Peers, model.PeerSyncStatus{
				PeerID:      t.peerID,
				DisplayName: t.displayName,
				Addr:        t.addr,
				Status:      "need",
				Message:     "需要配对码",
			})
			continue
		}
		merged, dl, ul, serr := p.SyncWithAddr(ctx, t.addr, t.peerID, code)
		if serr != nil {
			errStr := serr.Error()
			status := "error"
			msg := errStr
			switch {
			case strings.Contains(errStr, "配对码不正确") || strings.Contains(errStr, "unauthorized"):
				status = "wrong_code"
				msg = "配对码不对"
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
			continue
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
	}

	// Also include incoming client devices (e.g. Android phones) recorded in SQLite sync_peers
	// so the Mac remembers paired/synced devices across restarts even though phones do not serve UDP.
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
	baseURL := "http://" + addr

	// 1. Determine watermark for this peer
	var since int64
	if knownPeerID != "" {
		if sp, gerr := p.store.GetSyncPeer(knownPeerID); gerr == nil && sp != nil && sp.LastHeardAt > clockMarginMs {
			since = sp.LastHeardAt - clockMarginMs
		}
	}

	// 2. Collect local changes & local blobs
	localNotes, localAtts, err := p.store.ListChangesSince(since)
	if err != nil {
		return 0, 0, 0, err
	}
	haveBlobs, _ := p.store.ListLocalBlobs()

	reqBody := model.SyncExchangeRequest{
		PeerID:      p.peerID,
		DisplayName: p.displayName,
		Since:       since,
		Notes:       localNotes,
		Attachments: localAtts,
		HaveBlobs:   haveBlobs,
	}

	// 3. Challenge + HMAC proof (using REMOTE peer's code) -> POST /sync/exchange
	respBytes, err := p.authedRequest(ctx, http.MethodPost, baseURL+"/sync/exchange", reqBody, "application/json", remoteCode)
	if err != nil {
		return 0, 0, 0, err
	}
	var resp model.SyncExchangeResponse
	if err := json.Unmarshal(respBytes, &resp); err != nil {
		return 0, 0, 0, fmt.Errorf("decode exchange response: %w", err)
	}

	// 4. Merge remote delta locally
	merged, err := p.store.MergeRemote(resp.Notes, resp.Attachments)
	if err != nil {
		return 0, 0, 0, err
	}

	// 5. Download any blobs we are missing
	missing, _ := p.store.MissingBlobs()
	for _, hash := range missing {
		data, mime, derr := p.downloadBlob(ctx, baseURL, hash, remoteCode)
		if derr == nil && len(data) > 0 {
			if _, _, _, serr := p.store.SaveBlob(data, mime); serr == nil {
				blobsDown++
			}
		}
	}

	// 6. Upload any blobs the peer asked for
	for _, hash := range resp.WantBlobs {
		data, mime, rerr := p.store.ReadBlob(hash)
		if rerr != nil {
			continue
		}
		if uerr := p.uploadBlob(ctx, baseURL, hash, data, mime, remoteCode); uerr == nil {
			blobsUp++
		}
	}

	// 7. Record updated watermark + save this peer's code in sync_peers
	now := time.Now().UnixMilli()
	heard := resp.ServerTime
	if heard <= 0 {
		heard = now
	}
	if resp.PeerID != "" {
		_ = p.store.UpsertSyncPeer(model.SyncPeer{
			PeerID:      resp.PeerID,
			DisplayName: resp.DisplayName,
			LastAddr:    addr,
			PairCode:    NormalizeCode(remoteCode),
			LastHeardAt: heard,
			LastSyncAt:  now,
		})
	}

	return merged, blobsDown, blobsUp, nil
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

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxBlobBytes+1024))
	if err != nil {
		return nil, err
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
	res := p.auth.Verify(r.Header.Get(HeaderNonce), r.Header.Get(HeaderProof))
	if res.OK {
		return true
	}
	if res.Locked {
		w.Header().Set("Retry-After", fmt.Sprintf("%d", res.RetryAfterSecond))
		http.Error(w, fmt.Sprintf("locked for %ds", res.RetryAfterSecond), http.StatusTooManyRequests)
		return false
	}
	http.Error(w, "unauthorized", http.StatusUnauthorized)
	return false
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

	since := req.Since
	if since < 0 {
		since = 0
	}
	outNotes, outAtts, err := p.store.ListChangesSince(since)
	if err != nil {
		http.Error(w, "read error", http.StatusInternalServerError)
		return
	}

	missing, _ := p.store.MissingBlobs()
	senderHave := make(map[string]struct{}, len(req.HaveBlobs))
	for _, h := range req.HaveBlobs {
		senderHave[h] = struct{}{}
	}
	var want []string
	for _, m := range missing {
		if _, ok := senderHave[m]; ok {
			want = append(want, m)
		}
	}

	now := time.Now().UnixMilli()
	if req.PeerID != "" {
		clientIP := r.RemoteAddr
		if host, _, herr := net.SplitHostPort(r.RemoteAddr); herr == nil && host != "" {
			clientIP = host
		}
		_ = p.store.UpsertSyncPeer(model.SyncPeer{
			PeerID:      req.PeerID,
			DisplayName: req.DisplayName,
			LastAddr:    clientIP,
			LastHeardAt: now,
			LastSyncAt:  now,
		})
		// Wake Mac UI so newly connected phone shows up immediately in Settings
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
