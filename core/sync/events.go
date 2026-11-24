package sync

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

const sseIdleTimeout = 35 * time.Second

// handleEvents serves an authenticated Server-Sent Events (SSE) stream on /sync/events.
// Whenever a note is created, updated, deleted, or merged on this host, all connected
// clients receive an instant `event: changed` frame (< 50ms latency) over the existing HTTP port.
// It also drives real bidirectional ping/pong heartbeats (`event: ping` -> client `POST /sync/pong`).
func (p *Peer) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !p.verifyRequest(w, r) {
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprint(w, ": connected\n\n")
	flusher.Flush()

	clientPeerID := r.Header.Get(HeaderPeerID)
	clientIP := clientIPFromAddr(r.RemoteAddr)
	sub := &sseSubscriber{
		peerID:    clientPeerID,
		remoteIP:  clientIP,
		changedCh: make(chan struct{}, 1),
		pingCh:    make(chan ssePingMsg, 4),
		closeCh:   make(chan struct{}),
	}

	p.sseMu.Lock()
	p.sseSubs[sub] = struct{}{}
	if clientPeerID != "" {
		p.activeSSEPeers[clientPeerID] = time.Now().UnixMilli()
	}
	subCount := len(p.sseSubs)
	p.sseMu.Unlock()
	log.Printf("[whim-sync] sse client connected peer=%s remote=%s subs=%d", clientPeerID, r.RemoteAddr, subCount)

	if clientPeerID != "" {
		select {
		case p.localChanged <- struct{}{}:
		default:
		}
	}
	defer func() {
		sub.close()
		p.sseMu.Lock()
		delete(p.sseSubs, sub)
		if clientPeerID != "" {
			// Only clear activeSSEPeers if no other subscriber for the same peerID remains
			stillActive := false
			for s := range p.sseSubs {
				if s.peerID == clientPeerID {
					stillActive = true
					break
				}
			}
			if !stillActive {
				delete(p.activeSSEPeers, clientPeerID)
				if rec, ok := p.peerLiveness[clientPeerID]; ok {
					rec.Status = "offline"
					rec.LastPongAt = 0
					rec.Message = "连接已断开"
				}
			}
		}
		p.sseMu.Unlock()
		log.Printf("[whim-sync] sse client disconnected peer=%s", clientPeerID)
	}()

	writePing := func(msg ssePingMsg) error {
		payload, _ := json.Marshal(msg)
		if _, err := fmt.Fprintf(w, "event: ping\ndata: %s\n\n", payload); err != nil {
			return err
		}
		flusher.Flush()
		return nil
	}

	// Send an immediate ping challenge upon connection so liveness & RTT are verified right away.
	initPing := ssePingMsg{ID: newPingID(), TS: time.Now().UnixMilli()}
	p.registerPendingPing(initPing.ID, clientPeerID)
	if err := writePing(initPing); err != nil {
		p.clearPendingPing(initPing.ID)
		return
	}

	pingTicker := time.NewTicker(pingHeartbeatInterval)
	defer pingTicker.Stop()

	lastPingSentAt := time.Now().UnixMilli()
	missedPings := 0

	for {
		select {
		case <-r.Context().Done():
			return
		case <-sub.closeCh:
			return
		case <-sub.changedCh:
			if _, err := fmt.Fprintf(w, "event: changed\ndata: %d\n\n", time.Now().UnixMilli()); err != nil {
				return
			}
			flusher.Flush()
		case msg := <-sub.pingCh:
			if err := writePing(msg); err != nil {
				return
			}
		case <-pingTicker.C:
			// Check whether the client replied to our previous ping
			if clientPeerID != "" {
				p.sseMu.Lock()
				rec := p.peerLiveness[clientPeerID]
				gotPong := rec != nil && rec.LastPongAt >= lastPingSentAt
				p.sseMu.Unlock()
				if gotPong {
					missedPings = 0
				} else {
					missedPings++
					if missedPings >= 2 {
						log.Printf("[whim-sync] sse client peer=%s missed %d consecutive pings, closing stale stream", clientPeerID, missedPings)
						return
					}
				}
			}
			msg := ssePingMsg{ID: newPingID(), TS: time.Now().UnixMilli()}
			lastPingSentAt = msg.TS
			p.registerPendingPing(msg.ID, clientPeerID)
			if err := writePing(msg); err != nil {
				p.clearPendingPing(msg.ID)
				return
			}
		}
	}
}

// ensureEventSubscriber starts a single lightweight background goroutine that discovers
// LAN hosts via cached sync_peers + UDP (or manual fallback addrs) and subscribes to /sync/events.
func (p *Peer) ensureEventSubscriber() {
	p.mu.Lock()
	if p.sseStarted {
		p.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	p.sseStarted = true
	p.sseCancel = cancel
	p.mu.Unlock()

	go p.runEventSubscriberLoop(ctx)
}

func (p *Peer) runEventSubscriberLoop(ctx context.Context) {
	waitOrReconnect := func(d time.Duration) bool {
		timer := time.NewTimer(d)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return false
		case <-p.sseReconnect:
			return true
		case <-timer.C:
			return true
		}
	}

	for {
		if ctx.Err() != nil {
			return
		}
		code := NormalizeCode(p.auth.Code())
		if len(code) != 6 {
			if !waitOrReconnect(1 * time.Second) {
				return
			}
			continue
		}

		addrs := p.findEventTargetAddrs(ctx)
		if len(addrs) == 0 {
			if !waitOrReconnect(2 * time.Second) {
				return
			}
			continue
		}

		// Try each known host until one accepts the SSE stream
		for _, addr := range addrs {
			if ctx.Err() != nil {
				return
			}
			streamCtx, streamCancel := context.WithCancel(ctx)
			p.sseMu.Lock()
			p.sseStreamCancel = streamCancel
			p.sseMu.Unlock()

			err := p.subscribeOneSSE(streamCtx, addr, code)

			p.sseMu.Lock()
			p.sseStreamCancel = nil
			p.sseMu.Unlock()
			streamCancel()

			if err != nil && ctx.Err() == nil {
				log.Printf("[whim-sync] sse disconnected from %s: %v", addr, err)
			}
		}

		if !waitOrReconnect(1 * time.Second) {
			return
		}
	}
}

func (p *Peer) findEventTargetAddrs(ctx context.Context) []string {
	p.mu.Lock()
	discPort := p.discoveryPort
	p.mu.Unlock()

	seen := make(map[string]bool)
	var out []string
	add := func(a string) {
		a = strings.TrimSpace(a)
		if a == "" || seen[a] {
			return
		}
		seen[a] = true
		out = append(out, a)
	}

	// 1. Fresh UDP discovery (picks up DHCP IP changes automatically)
	if discovered, err := DiscoverPeers(ctx, discPort, p.peerID, 700*time.Millisecond); err == nil {
		for _, d := range discovered {
			add(d.Addr)
		}
	}
	// 2. Persisted server peers from SQLite sync_peers (entries with host:port, e.g. Mac host).
	// Immune to Android Wi-Fi UDP broadcast packet drops!
	if saved, err := p.store.ListSyncPeers(); err == nil {
		for _, sp := range saved {
			if strings.Contains(sp.LastAddr, ":") {
				add(sp.LastAddr)
			}
		}
	}
	// 3. Optional manual fallback addresses
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
				add(a)
			}
		}
	}
	return out
}

func (p *Peer) subscribeOneSSE(ctx context.Context, addr, code string) error {
	baseURL := "http://" + addr
	nonce, err := p.fetchNonce(ctx, baseURL)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/sync/events", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set(HeaderNonce, nonce)
	req.Header.Set(HeaderProof, ComputeProof(code, nonce))
	req.Header.Set(HeaderPeerID, p.peerID)

	resp, err := p.streamClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusUnauthorized {
			p.recordPeerFailure("", "", addr, "wrong_code", "配对码不匹配")
		}
		return fmt.Errorf("sse status %d", resp.StatusCode)
	}
	log.Printf("[whim-sync] sse subscribed to %s", addr)

	// Immediately trigger a catch-up sync whenever an SSE stream (re)connects so any
	// events missed while Android was asleep/frozen are pulled right away.
	select {
	case p.remoteChanged <- struct{}{}:
	default:
	}

	// Watchdog: server sends `event: ping` every 10s. If no bytes arrive for 35s
	// (e.g. half-open TCP socket after Android Doze/Wi-Fi sleep), close body to force reconnect.
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = resp.Body.Close()
		case <-done:
		}
	}()

	watchdog := time.AfterFunc(sseIdleTimeout, func() {
		log.Printf("[whim-sync] sse idle timeout from %s, forcing reconnect", addr)
		_ = resp.Body.Close()
	})
	defer watchdog.Stop()

	scanner := bufio.NewScanner(resp.Body)
	currentEvent := ""
	for scanner.Scan() {
		watchdog.Reset(sseIdleTimeout)
		line := scanner.Text()
		if line == "" {
			currentEvent = ""
			continue
		}
		if strings.HasPrefix(line, "event:") {
			currentEvent = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			if currentEvent == "changed" {
				log.Printf("[whim-sync] sse received change from %s", addr)
				select {
				case p.remoteChanged <- struct{}{}:
				default:
				}
			}
		} else if strings.HasPrefix(line, "data:") && currentEvent == "ping" {
			rawData := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			var pingMsg ssePingMsg
			if json.Unmarshal([]byte(rawData), &pingMsg) == nil && pingMsg.ID != "" {
				go func(msg ssePingMsg) {
					pongCtx, cancel := context.WithTimeout(ctx, pingReplyTimeout)
					defer cancel()
					_ = p.sendPong(pongCtx, addr, code, msg.ID, msg.TS)
				}(pingMsg)
			}
		}
		// If local pairing code changed while stream is open, drop & reconnect with new code
		if NormalizeCode(p.auth.Code()) != code {
			return nil
		}
	}
	return scanner.Err()
}
