package sync

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// handleEvents serves an authenticated Server-Sent Events (SSE) stream on /sync/events.
// Whenever a note is created, updated, deleted, or merged on this host, all connected
// clients receive an instant `event: changed` frame (< 50ms latency) over the existing HTTP port.
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

	ch := make(chan struct{}, 1)
	clientPeerID := r.Header.Get(HeaderPeerID)
	p.sseMu.Lock()
	p.sseSubs[ch] = struct{}{}
	if clientPeerID != "" {
		p.activeSSEPeers[clientPeerID] = time.Now().UnixMilli()
	}
	p.sseMu.Unlock()
	if clientPeerID != "" {
		select {
		case p.localChanged <- struct{}{}:
		default:
		}
	}
	defer func() {
		p.sseMu.Lock()
		delete(p.sseSubs, ch)
		if clientPeerID != "" {
			delete(p.activeSSEPeers, clientPeerID)
		}
		p.sseMu.Unlock()
	}()

	keepalive := time.NewTicker(20 * time.Second)
	defer keepalive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ch:
			_, _ = fmt.Fprintf(w, "event: changed\ndata: %d\n\n", time.Now().UnixMilli())
			flusher.Flush()
		case <-keepalive.C:
			_, _ = fmt.Fprint(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

// ensureEventSubscriber starts a single lightweight background goroutine that discovers
// LAN hosts via UDP (or manual fallback addrs) and subscribes to their /sync/events SSE stream.
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
	for {
		if ctx.Err() != nil {
			return
		}
		code := NormalizeCode(p.auth.Code())
		if len(code) != 6 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
				continue
			}
		}

		addrs := p.findEventTargetAddrs(ctx)
		if len(addrs) == 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(3 * time.Second):
				continue
			}
		}

		// Subscribe to the first reachable host (re-discovers automatically on disconnect)
		_ = p.subscribeOneSSE(ctx, addrs[0], code)

		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
}

func (p *Peer) findEventTargetAddrs(ctx context.Context) []string {
	p.mu.Lock()
	discPort := p.discoveryPort
	p.mu.Unlock()

	seen := make(map[string]bool)
	var out []string
	if discovered, err := DiscoverPeers(ctx, discPort, p.peerID, 700*time.Millisecond); err == nil {
		for _, d := range discovered {
			if !seen[d.Addr] {
				seen[d.Addr] = true
				out = append(out, d.Addr)
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
				if !seen[a] {
					seen[a] = true
					out = append(out, a)
				}
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
		return fmt.Errorf("sse status %d", resp.StatusCode)
	}

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "event: changed") {
			select {
			case p.remoteChanged <- struct{}{}:
			default:
			}
		}
		// If local pairing code changed while stream is open, drop & reconnect with new code
		if NormalizeCode(p.auth.Code()) != code {
			return nil
		}
	}
	return scanner.Err()
}
