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

// Peer manages both incoming peer sync requests (HTTP + UDP discovery)
// and outgoing bidirectional sync exchanges. Both macOS and Android run this exact same Peer.
type Peer struct {
	mu            sync.Mutex
	store         *store.Store
	auth          *Auth
	peerID        string
	displayName   string
	discoveryPort int
	manualAddrs   []string

	server      *http.Server
	httpPort    int
	cancelServe context.CancelFunc
	client      *http.Client
}

// NewPeer constructs a Peer attached to a local Store.
func NewPeer(st *store.Store, peerID, displayName, pairCode string) *Peer {
	if pairCode == "" {
		pairCode = GenerateCode()
	}
	return &Peer{
		store:         st,
		auth:          NewAuth(pairCode),
		peerID:        peerID,
		displayName:   displayName,
		discoveryPort: DefaultDiscoveryPort,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// PeerID returns this device's unique peer ID.
func (p *Peer) PeerID() string { return p.peerID }

// PairCode returns the current 6-digit pairing code.
func (p *Peer) PairCode() string { return p.auth.Code() }

// SetPairCode updates the 6-digit pairing code.
func (p *Peer) SetPairCode(code string) { p.auth.SetCode(code) }

// SetManualAddrs sets fallback host:port addresses when UDP broadcast is blocked.
func (p *Peer) SetManualAddrs(addrs []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	clean := make([]string, 0, len(addrs))
	for _, a := range addrs {
		a = strings.TrimSpace(a)
		if a != "" {
			clean = append(clean, a)
		}
	}
	p.manualAddrs = clean
}

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
// Pass httpPort=0 to let the OS assign an ephemeral port (for tests).
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
			_ = ServeDiscovery(ctx, discPort, p.peerID, actualPort)
		}()
	}

	return actualPort, nil
}

// StopServer shuts down the HTTP listener and UDP discovery responder.
func (p *Peer) StopServer() error {
	p.mu.Lock()
	srv := p.server
	cancel := p.cancelServe
	p.server = nil
	p.httpPort = 0
	p.cancelServe = nil
	p.mu.Unlock()

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

// SyncOnce discovers all LAN peers (plus manual fallback addresses) and performs
// bidirectional metadata + blob sync with each peer. Safe to invoke from Android WorkManager.
func (p *Peer) SyncOnce(ctx context.Context) model.SyncSummary {
	var summary model.SyncSummary

	p.mu.Lock()
	discPort := p.discoveryPort
	manuals := append([]string(nil), p.manualAddrs...)
	p.mu.Unlock()

	targets := make(map[string]string) // addr -> optional known peerID
	if discovered, err := DiscoverPeers(ctx, discPort, p.peerID, 700*time.Millisecond); err == nil {
		for _, dp := range discovered {
			targets[dp.Addr] = dp.PeerID
		}
	}
	for _, addr := range manuals {
		if _, ok := targets[addr]; !ok {
			targets[addr] = ""
		}
	}

	summary.PeersFound = len(targets)
	for addr, knownID := range targets {
		merged, dl, ul, err := p.SyncWithAddr(ctx, addr, knownID)
		if err != nil {
			summary.Errors = append(summary.Errors, fmt.Sprintf("%s: %v", addr, err))
			continue
		}
		summary.PeersSynced++
		summary.NotesMerged += merged
		summary.BlobsDownloaded += dl
		summary.BlobsUploaded += ul
	}
	return summary
}

// SyncWithAddr runs a full authenticated bidirectional sync with one specific peer host:port.
func (p *Peer) SyncWithAddr(ctx context.Context, addr, knownPeerID string) (notesMerged, blobsDown, blobsUp int, err error) {
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

	// 3. Challenge + HMAC proof -> POST /sync/exchange
	respBytes, err := p.authedRequest(ctx, http.MethodPost, baseURL+"/sync/exchange", reqBody, "application/json")
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
		data, mime, derr := p.downloadBlob(ctx, baseURL, hash)
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
		if uerr := p.uploadBlob(ctx, baseURL, hash, data, mime); uerr == nil {
			blobsUp++
		}
	}

	// 7. Record updated watermark
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

func (p *Peer) authedRequest(ctx context.Context, method, fullURL string, body any, contentType string) ([]byte, error) {
	// Extract base URL for /sync/challenge
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
	req.Header.Set(HeaderProof, ComputeProof(p.auth.Code(), nonce))
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
		return nil, errors.New("unauthorized: pairing code mismatch")
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, fmt.Errorf("locked: too many failed attempts (%s)", strings.TrimSpace(string(raw)))
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return raw, nil
}

func (p *Peer) downloadBlob(ctx context.Context, baseURL, hash string) ([]byte, string, error) {
	nonce, err := p.fetchNonce(ctx, baseURL)
	if err != nil {
		return nil, "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/sync/blobs/"+hash, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set(HeaderNonce, nonce)
	req.Header.Set(HeaderProof, ComputeProof(p.auth.Code(), nonce))
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

func (p *Peer) uploadBlob(ctx context.Context, baseURL, hash string, data []byte, mime string) error {
	_, err := p.authedRequest(ctx, http.MethodPut, baseURL+"/sync/blobs/"+hash, data, mime)
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

	if _, err := p.store.MergeRemote(req.Notes, req.Attachments); err != nil {
		http.Error(w, "merge error", http.StatusInternalServerError)
		return
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

	// Determine which blobs we are missing that the sender actually has
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
		_ = p.store.UpsertSyncPeer(model.SyncPeer{
			PeerID:      req.PeerID,
			DisplayName: req.DisplayName,
			LastHeardAt: now,
			LastSyncAt:  now,
		})
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
