package sync

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultDiscoveryPort = 8789
	DefaultHTTPPort      = 8788
	discoverPrefix       = "WHIM/1 DISCOVER "
	offerPrefix          = "WHIM/1 OFFER "
)

// DiscoveredPeer represents a peer discovered via LAN UDP broadcast.
type DiscoveredPeer struct {
	PeerID      string
	DisplayName string
	Addr        string // host:port
	HTTPPort    int
}

// DirectedBroadcastAddrs computes per-interface IPv4 directed broadcast addresses
// so mobile devices with cellular default routes still broadcast over Wi-Fi.
func DirectedBroadcastAddrs() []net.IP {
	ifaces, err := net.Interfaces()
	if err != nil {
		return []net.IP{net.IPv4bcast}
	}
	seen := make(map[string]struct{})
	var out []net.IP
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if iface.Flags&net.FlagBroadcast == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipNet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil || len(ipNet.Mask) != 4 {
				continue
			}
			bcast := make(net.IP, 4)
			for i := 0; i < 4; i++ {
				bcast[i] = ip4[i] | ^ipNet.Mask[i]
			}
			key := bcast.String()
			if _, ok := seen[key]; !ok {
				seen[key] = struct{}{}
				out = append(out, bcast)
			}
		}
	}
	if len(out) == 0 {
		out = append(out, net.IPv4bcast)
	}
	return out
}

// ServeDiscovery listens for UDP DISCOVER probes and replies unicast OFFER with our HTTP port & display name.
func ServeDiscovery(ctx context.Context, discoveryPort int, selfPeerID, displayName string, httpPort int) error {
	if discoveryPort <= 0 {
		discoveryPort = DefaultDiscoveryPort
	}
	pc, err := net.ListenPacket("udp4", fmt.Sprintf("0.0.0.0:%d", discoveryPort))
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		_ = pc.Close()
	}()

	cleanName := strings.ReplaceAll(strings.TrimSpace(displayName), "\n", " ")
	if cleanName == "" {
		cleanName = "Whim Device"
	}

	buf := make([]byte, 512)
	for {
		n, addr, err := pc.ReadFrom(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			continue
		}
		msg := strings.TrimSpace(string(buf[:n]))
		if !strings.HasPrefix(msg, discoverPrefix) {
			continue
		}
		senderID := strings.TrimSpace(strings.TrimPrefix(msg, discoverPrefix))
		if senderID == selfPeerID {
			continue
		}
		reply := fmt.Sprintf("%s%s %d %s", offerPrefix, selfPeerID, httpPort, cleanName)
		_, _ = pc.WriteTo([]byte(reply), addr)
	}
}

// DiscoverPeers broadcasts a probe on every active IPv4 subnet and collects all OFFER replies.
func DiscoverPeers(ctx context.Context, discoveryPort int, selfPeerID string, timeout time.Duration) ([]DiscoveredPeer, error) {
	if discoveryPort <= 0 {
		discoveryPort = DefaultDiscoveryPort
	}
	if timeout <= 0 {
		timeout = 700 * time.Millisecond
	}
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	payload := []byte(discoverPrefix + selfPeerID)
	for _, bcast := range DirectedBroadcastAddrs() {
		_, _ = conn.WriteToUDP(payload, &net.UDPAddr{IP: bcast, Port: discoveryPort})
	}

	deadline := time.Now().Add(timeout)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	_ = conn.SetReadDeadline(deadline)

	seen := make(map[string]DiscoveredPeer)
	buf := make([]byte, 512)
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			break
		}
		msg := strings.TrimSpace(string(buf[:n]))
		if !strings.HasPrefix(msg, offerPrefix) {
			continue
		}
		rest := strings.TrimPrefix(msg, offerPrefix)
		parts := strings.SplitN(rest, " ", 3)
		if len(parts) < 2 {
			continue
		}
		peerID := parts[0]
		if peerID == "" || peerID == selfPeerID {
			continue
		}
		port, err := strconv.Atoi(parts[1])
		if err != nil || port <= 0 || port > 65535 {
			continue
		}
		name := "Whim Device"
		if len(parts) == 3 && strings.TrimSpace(parts[2]) != "" {
			name = strings.TrimSpace(parts[2])
		}
		// Read peer IP from packet source address (immune to DHCP IP changes).
		addr := net.JoinHostPort(from.IP.String(), strconv.Itoa(port))
		seen[peerID] = DiscoveredPeer{
			PeerID:      peerID,
			DisplayName: name,
			Addr:        addr,
			HTTPPort:    port,
		}
	}

	out := make([]DiscoveredPeer, 0, len(seen))
	for _, p := range seen {
		out = append(out, p)
	}
	return out, nil
}
