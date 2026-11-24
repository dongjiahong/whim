package sync

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"whim/core/model"
)

const (
	pingHeartbeatInterval = 10 * time.Second
	pingReplyTimeout      = 2500 * time.Millisecond
	peerLivenessTTL       = 25 * time.Second
)

type ssePingMsg struct {
	ID string `json:"id"`
	TS int64  `json:"ts"`
}

type sseSubscriber struct {
	peerID      string
	displayName string
	remoteIP    string
	changedCh   chan struct{}
	pingCh      chan ssePingMsg
	unpairCh    chan string
	closeCh     chan struct{}
	closeOnce   sync.Once
}

func (s *sseSubscriber) close() {
	s.closeOnce.Do(func() {
		close(s.closeCh)
	})
}

type peerLiveRecord struct {
	PeerID      string
	DisplayName string
	Addr        string
	RTTMs       int64
	LastPongAt  int64
	Status      string // "connected" | "wrong_code" | "offline"
	Message     string
}

type pendingPing struct {
	peerID string
	sentAt time.Time
	done   chan int64
}

type syncPingRequest struct {
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	PingID      string `json:"ping_id"`
	SentAt      int64  `json:"sent_at"`
}

type syncPingResponse struct {
	OK          bool   `json:"ok"`
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	EchoID      string `json:"echo_id"`
	ServerTime  int64  `json:"server_time"`
}

type syncPongRequest struct {
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	PingID      string `json:"ping_id"`
	TS          int64  `json:"ts"`
}

type syncPongResponse struct {
	OK          bool   `json:"ok"`
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	ServerTime  int64  `json:"server_time"`
}

func newPingID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func clientIPFromAddr(remoteAddr string) string {
	if host, _, err := net.SplitHostPort(remoteAddr); err == nil && host != "" {
		return host
	}
	return remoteAddr
}

func (p *Peer) recordPeerAlive(peerID, displayName, addr string, rttMs int64) {
	if peerID == "" || peerID == p.peerID {
		return
	}
	now := time.Now().UnixMilli()
	p.sseMu.Lock()
	defer p.sseMu.Unlock()
	rec, ok := p.peerLiveness[peerID]
	if !ok {
		rec = &peerLiveRecord{PeerID: peerID}
		p.peerLiveness[peerID] = rec
	}
	if displayName != "" {
		rec.DisplayName = displayName
	}
	if addr != "" {
		rec.Addr = addr
	}
	if rttMs >= 0 {
		rec.RTTMs = rttMs
	}
	rec.LastPongAt = now
	rec.Status = "connected"
	rec.Message = "在线 · 可传输"
}

func (p *Peer) recordPeerFailure(peerID, displayName, addr, status, msg string) {
	key := peerID
	if key == "" {
		key = "addr:" + addr
	}
	if key == "" || key == p.peerID {
		return
	}
	p.sseMu.Lock()
	defer p.sseMu.Unlock()
	rec, ok := p.peerLiveness[key]
	if !ok {
		rec = &peerLiveRecord{PeerID: peerID}
		p.peerLiveness[key] = rec
	}
	if displayName != "" {
		rec.DisplayName = displayName
	}
	if addr != "" {
		rec.Addr = addr
	}
	rec.Status = status
	rec.Message = msg
	if status != "connected" {
		rec.LastPongAt = 0
	}
}

func (p *Peer) registerPendingPing(pingID, peerID string) chan int64 {
	ch := make(chan int64, 1)
	p.sseMu.Lock()
	p.pendingPings[pingID] = &pendingPing{
		peerID: peerID,
		sentAt: time.Now(),
		done:   ch,
	}
	p.sseMu.Unlock()
	return ch
}

func (p *Peer) clearPendingPing(pingID string) {
	p.sseMu.Lock()
	delete(p.pendingPings, pingID)
	p.sseMu.Unlock()
}

// handlePing responds to an authenticated POST /sync/ping with an echo of ping_id,
// proving both pairing auth and bidirectional message transmission.
func (p *Peer) handlePing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !p.verifyRequest(w, r) {
		return
	}
	var req syncPingRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	now := time.Now().UnixMilli()
	if req.PeerID != "" {
		var estRTT int64
		if req.SentAt > 0 && now >= req.SentAt && (now-req.SentAt) < 5000 {
			estRTT = now - req.SentAt
		}
		p.recordPeerAlive(req.PeerID, req.DisplayName, clientIPFromAddr(r.RemoteAddr), estRTT)
	}
	resp := syncPingResponse{
		OK:          true,
		PeerID:      p.peerID,
		DisplayName: p.displayName,
		EchoID:      req.PingID,
		ServerTime:  now,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// handlePong receives an authenticated POST /sync/pong from an SSE client replying to an `event: ping`.
func (p *Peer) handlePong(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !p.verifyRequest(w, r) {
		return
	}
	var req syncPongRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	now := time.Now().UnixMilli()
	var rttMs int64 = -1
	p.sseMu.Lock()
	if pp, ok := p.pendingPings[req.PingID]; ok {
		rttMs = time.Since(pp.sentAt).Milliseconds()
		if rttMs < 0 {
			rttMs = 0
		}
		delete(p.pendingPings, req.PingID)
		select {
		case pp.done <- rttMs:
		default:
		}
	}
	p.sseMu.Unlock()

	if req.PeerID != "" {
		p.recordPeerAlive(req.PeerID, req.DisplayName, clientIPFromAddr(r.RemoteAddr), rttMs)
	}
	resp := syncPongResponse{
		OK:          true,
		PeerID:      p.peerID,
		DisplayName: p.displayName,
		ServerTime:  now,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// PingAddr sends an authenticated ping with a random ping_id to addr and verifies the echoed reply.
func (p *Peer) PingAddr(ctx context.Context, addr, remoteCode string) (model.LivePeerStatus, error) {
	return p.pingPeer(ctx, "", addr, remoteCode)
}

func (p *Peer) pingPeer(ctx context.Context, knownPeerID, addr, remoteCode string) (model.LivePeerStatus, error) {
	baseURL := "http://" + addr
	pingID := newPingID()
	start := time.Now()
	reqBody := syncPingRequest{
		PeerID:      p.peerID,
		DisplayName: p.displayName,
		PingID:      pingID,
		SentAt:      start.UnixMilli(),
	}
	raw, err := p.authedRequest(ctx, http.MethodPost, baseURL+"/sync/ping", reqBody, "application/json", remoteCode)
	if err != nil {
		if errors.Is(err, ErrPeerUnpaired) {
			p.handleRemoteUnpaired(knownPeerID, addr)
			return model.LivePeerStatus{PeerID: knownPeerID, Addr: addr, Online: false, Status: "offline", Message: "已断开"}, err
		}
		errStr := err.Error()
		status := "offline"
		msg := errStr
		if strings.Contains(errStr, "配对码不正确") || strings.Contains(errStr, "unauthorized") {
			status = "wrong_code"
			msg = "对方配对码已更换"
		}
		p.recordPeerFailure(knownPeerID, "", addr, status, msg)
		return model.LivePeerStatus{
			PeerID:  knownPeerID,
			Addr:    addr,
			Online:  false,
			Status:  status,
			Message: msg,
		}, err
	}
	var resp syncPingResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return model.LivePeerStatus{PeerID: knownPeerID, Addr: addr, Online: false, Status: "offline", Message: "响应解析失败"}, err
	}
	if !resp.OK || resp.EchoID != pingID {
		return model.LivePeerStatus{PeerID: knownPeerID, Addr: addr, Online: false, Status: "offline", Message: "心跳校验失败"}, errors.New("ping echo mismatch")
	}
	rttMs := time.Since(start).Milliseconds()
	if rttMs < 0 {
		rttMs = 0
	}
	now := time.Now().UnixMilli()
	p.recordPeerAlive(resp.PeerID, resp.DisplayName, addr, rttMs)
	return model.LivePeerStatus{
		PeerID:      resp.PeerID,
		DisplayName: resp.DisplayName,
		Addr:        addr,
		Online:      true,
		RTTMs:       rttMs,
		LastPongAt:  now,
		Status:      "connected",
		Message:     fmt.Sprintf("在线 · %dms", rttMs),
	}, nil
}

// sendPong replies to a server's SSE `event: ping` over POST /sync/pong and updates client-side liveness.
func (p *Peer) sendPong(ctx context.Context, addr, remoteCode, pingID string, sentTS int64) error {
	baseURL := "http://" + addr
	start := time.Now()
	reqBody := syncPongRequest{
		PeerID:      p.peerID,
		DisplayName: p.displayName,
		PingID:      pingID,
		TS:          sentTS,
	}
	raw, err := p.authedRequest(ctx, http.MethodPost, baseURL+"/sync/pong", reqBody, "application/json", remoteCode)
	if err != nil {
		return err
	}
	var resp syncPongResponse
	if err := json.Unmarshal(raw, &resp); err == nil && resp.OK && resp.PeerID != "" {
		rttMs := time.Since(start).Milliseconds()
		if rttMs < 0 {
			rttMs = 0
		}
		p.recordPeerAlive(resp.PeerID, resp.DisplayName, addr, rttMs)
	}
	return nil
}

// probeSSESubscriber pushes a live ping frame over an open SSE stream and waits for the client's POST /sync/pong.
func (p *Peer) probeSSESubscriber(ctx context.Context, sub *sseSubscriber) (int64, bool) {
	pingID := newPingID()
	doneCh := p.registerPendingPing(pingID, sub.peerID)
	defer p.clearPendingPing(pingID)

	msg := ssePingMsg{ID: pingID, TS: time.Now().UnixMilli()}
	select {
	case sub.pingCh <- msg:
	case <-sub.closeCh:
		return 0, false
	case <-ctx.Done():
		return 0, false
	default:
	}

	timer := time.NewTimer(pingReplyTimeout)
	defer timer.Stop()
	select {
	case rtt := <-doneCh:
		return rtt, true
	case <-sub.closeCh:
		return 0, false
	case <-timer.C:
		if sub.peerID != "" {
			p.recordPeerFailure(sub.peerID, sub.displayName, sub.remoteIP, "offline", "心跳超时")
		}
		sub.close()
		return 0, false
	case <-ctx.Done():
		return 0, false
	}
}

// CheckSyncHealth returns the real-time verified sync status across all paired peers
// (both outbound paired hosts and inbound connected clients).
func (p *Peer) CheckSyncHealth(ctx context.Context, activeProbe bool) model.SyncHealthStatus {
	if activeProbe {
		probeCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()

		var wg sync.WaitGroup

		// 1. Actively ping all connected inbound SSE clients (e.g. Android phones connected to macOS)
		p.sseMu.Lock()
		subs := make([]*sseSubscriber, 0, len(p.sseSubs))
		for s := range p.sseSubs {
			subs = append(subs, s)
		}
		p.sseMu.Unlock()

		for _, s := range subs {
			s := s
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, _ = p.probeSSESubscriber(probeCtx, s)
			}()
		}

		// 2. Actively ping all paired outbound hosts using EACH host's own saved 6-digit code
		targets := p.findPairedOutboundTargets(probeCtx)
		for _, t := range targets {
			t := t
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, _ = p.pingPeer(probeCtx, t.peerID, t.addr, t.code)
			}()
		}

		wg.Wait()
	}

	now := time.Now().UnixMilli()
	ttlMs := peerLivenessTTL.Milliseconds()

	savedPeers, _ := p.store.ListSyncPeers()
	savedByID := make(map[string]model.SyncPeer, len(savedPeers))
	for _, sp := range savedPeers {
		if sp.PeerID != "" && sp.PeerID != p.peerID {
			savedByID[sp.PeerID] = sp
		}
	}

	p.sseMu.Lock()
	liveCopy := make(map[string]peerLiveRecord, len(p.peerLiveness))
	for k, v := range p.peerLiveness {
		liveCopy[k] = *v
	}
	activeSSECopy := make(map[string]int64, len(p.activeSSEPeers))
	for k, v := range p.activeSSEPeers {
		activeSSECopy[k] = v
	}
	p.sseMu.Unlock()

	if len(savedByID) == 0 && len(activeSSECopy) == 0 {
		return model.SyncHealthStatus{
			State:        "unpaired",
			Connected:    false,
			ErrorMessage: "尚未配对其他设备",
		}
	}

	seen := make(map[string]bool)
	var peers []model.LivePeerStatus
	var (
		onlineCount int
		bestRTT     int64 = -1
		latestPong  int64
		latestSync  int64
		primaryName string
		wrongCode   bool
		lastErrMsg  string
	)

	// Merge live records for currently paired or actively connected peers only
	for _, rec := range liveCopy {
		id := rec.PeerID
		if id == "" {
			continue
		}
		sp, hasSaved := savedByID[id]
		_, isActiveSSE := activeSSECopy[id]
		if !hasSaved && !isActiveSSE {
			continue
		}
		seen[id] = true
		name := rec.DisplayName
		if name == "" && hasSaved {
			name = sp.DisplayName
		}
		if name == "" {
			name = "局域网设备"
		}
		addr := rec.Addr
		if addr == "" && hasSaved {
			addr = sp.LastAddr
		}
		lastSync := sp.LastSyncAt
		if lastSync > latestSync {
			latestSync = lastSync
		}

		isOnline := rec.Status == "connected" && rec.LastPongAt > 0 && (now-rec.LastPongAt) <= ttlMs
		status := rec.Status
		msg := rec.Message
		if isOnline {
			status = "connected"
			msg = fmt.Sprintf("在线 · %dms", rec.RTTMs)
			onlineCount++
			if bestRTT < 0 || rec.RTTMs < bestRTT {
				bestRTT = rec.RTTMs
				primaryName = name
			}
			if rec.LastPongAt > latestPong {
				latestPong = rec.LastPongAt
			}
		} else {
			if status == "wrong_code" {
				wrongCode = true
				if lastErrMsg == "" {
					lastErrMsg = "对方配对码已更换"
				}
			} else {
				status = "offline"
				if msg == "" || msg == "在线 · 可传输" {
					msg = "离线"
				}
			}
		}
		peers = append(peers, model.LivePeerStatus{
			PeerID:      id,
			DisplayName: name,
			Addr:        addr,
			Online:      isOnline,
			RTTMs:       rec.RTTMs,
			LastPongAt:  rec.LastPongAt,
			LastSyncAt:  lastSync,
			Status:      status,
			Message:     msg,
		})
	}

	// Include paired peers that have not ponged in this session yet
	for _, sp := range savedPeers {
		if sp.PeerID == "" || sp.PeerID == p.peerID || seen[sp.PeerID] {
			continue
		}
		if sp.LastSyncAt > latestSync {
			latestSync = sp.LastSyncAt
		}
		name := sp.DisplayName
		if name == "" {
			name = "已配对设备"
		}
		peers = append(peers, model.LivePeerStatus{
			PeerID:      sp.PeerID,
			DisplayName: name,
			Addr:        sp.LastAddr,
			Online:      false,
			LastSyncAt:  sp.LastSyncAt,
			Status:      "offline",
			Message:     "离线",
		})
	}

	sort.Slice(peers, func(i, j int) bool {
		if peers[i].Online != peers[j].Online {
			return peers[i].Online
		}
		return peers[i].LastPongAt > peers[j].LastPongAt
	})

	state := "offline"
	if onlineCount > 0 {
		state = "connected"
	} else if wrongCode {
		state = "wrong_code"
	}
	if bestRTT < 0 {
		bestRTT = 0
	}

	return model.SyncHealthStatus{
		State:        state,
		Connected:    onlineCount > 0,
		OnlinePeers:  onlineCount,
		TotalPeers:   len(peers),
		RTTMs:        bestRTT,
		LastPongAt:   latestPong,
		LastSyncAt:   latestSync,
		PeerName:     primaryName,
		ErrorMessage: lastErrMsg,
		Peers:        peers,
	}
}
