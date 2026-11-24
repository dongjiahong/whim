package sync

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
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
// It also drives real bidirectional ping/pong heartbeats (`event: ping` -> client `POST /sync/pong`)
// and instant unpair notification (`event: unpair`) when this host forgets the client.
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
		unpairCh:  make(chan string, 1),
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
		case remotePeerID := <-sub.unpairCh:
			payload, _ := json.Marshal(unpairRequest{PeerID: remotePeerID})
			_, _ = fmt.Fprintf(w, "event: unpair\ndata: %s\n\n", payload)
			flusher.Flush()
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

// ensureEventSubscriber starts the multi-peer SSE supervisor goroutine that maintains
// concurrent live SSE streams to all paired outbound hosts using each host's own 6-digit code.
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

type activeSSEWorker struct {
	addr   string
	code   string
	cancel context.CancelFunc
}

func (p *Peer) runEventSubscriberLoop(ctx context.Context) {
	active := make(map[string]activeSSEWorker)
	defer func() {
		for k, w := range active {
			w.cancel()
			delete(active, k)
		}
		p.sseMu.Lock()
		for k := range p.sseStreams {
			delete(p.sseStreams, k)
		}
		p.sseMu.Unlock()
	}()

	reconcile := func() {
		targets := p.findPairedOutboundTargets(ctx)
		desired := make(map[string]pairedOutboundTarget, len(targets))
		for _, t := range targets {
			key := t.peerID
			if key == "" {
				key = t.addr
			}
			desired[key] = t
		}

		// Tear down streams for peers that were unpaired or changed address/code.
		for key, w := range active {
			t, ok := desired[key]
			if !ok || t.addr != w.addr || t.code != w.code {
				w.cancel()
				delete(active, key)
				p.sseMu.Lock()
				delete(p.sseStreams, key)
				p.sseMu.Unlock()
			}
		}

		// Spawn concurrent SSE workers for newly paired hosts.
		for key, t := range desired {
			if _, exists := active[key]; exists {
				continue
			}
			streamCtx, streamCancel := context.WithCancel(ctx)
			active[key] = activeSSEWorker{
				addr:   t.addr,
				code:   t.code,
				cancel: streamCancel,
			}
			p.sseMu.Lock()
			p.sseStreams[key] = streamCancel
			p.sseMu.Unlock()

			go p.runSinglePeerSSE(streamCtx, key, t)
		}
	}

	reconcile()
	ticker := time.NewTicker(4 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-p.sseReconnect:
			reconcile()
		case <-ticker.C:
			reconcile()
		}
	}
}

func (p *Peer) runSinglePeerSSE(ctx context.Context, key string, target pairedOutboundTarget) {
	backoff := 1 * time.Second
	for {
		if ctx.Err() != nil {
			return
		}
		err := p.subscribeOneSSE(ctx, target.peerID, target.addr, target.code)
		if errors.Is(err, ErrPeerUnpaired) || ctx.Err() != nil {
			return
		}
		if err != nil {
			log.Printf("[whim-sync] sse disconnected from %s (%s): %v", target.displayName, target.addr, err)
		}
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		if backoff < 8*time.Second {
			backoff *= 2
			if backoff > 8*time.Second {
				backoff = 8 * time.Second
			}
		}
	}
}

func (p *Peer) subscribeOneSSE(ctx context.Context, peerID, addr, code string) error {
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

	if resp.StatusCode == http.StatusGone {
		p.handleRemoteUnpaired(peerID, addr)
		return ErrPeerUnpaired
	}
	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusUnauthorized {
			p.recordPeerFailure(peerID, "", addr, "wrong_code", "对方配对码已更换")
		}
		return fmt.Errorf("sse status %d", resp.StatusCode)
	}
	log.Printf("[whim-sync] sse subscribed to %s (peer=%s)", addr, peerID)

	// Trigger a catch-up sync whenever an SSE stream (re)connects.
	select {
	case p.remoteChanged <- struct{}{}:
	default:
	}

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
		} else if strings.HasPrefix(line, "data:") {
			rawData := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			switch currentEvent {
			case "unpair":
				var msg unpairRequest
				_ = json.Unmarshal([]byte(rawData), &msg)
				targetID := msg.PeerID
				if targetID == "" {
					targetID = peerID
				}
				p.handleRemoteUnpaired(targetID, addr)
				return ErrPeerUnpaired
			case "ping":
				var pingMsg ssePingMsg
				if json.Unmarshal([]byte(rawData), &pingMsg) == nil && pingMsg.ID != "" {
					go func(msg ssePingMsg) {
						pongCtx, cancel := context.WithTimeout(ctx, pingReplyTimeout)
						defer cancel()
						if perr := p.sendPong(pongCtx, addr, code, msg.ID, msg.TS); errors.Is(perr, ErrPeerUnpaired) {
							p.handleRemoteUnpaired(peerID, addr)
						}
					}(pingMsg)
				}
			}
		}
	}
	return scanner.Err()
}
