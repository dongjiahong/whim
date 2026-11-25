package sync

import (
	"fmt"
	"net"
)

// LocalLANAddr returns the best non-loopback IPv4 LAN address and HTTP port (e.g. "192.168.5.111:8788")
// for QR-code pairing display.
func (p *Peer) LocalLANAddr() string {
	p.mu.Lock()
	port := p.httpPort
	p.mu.Unlock()
	if port <= 0 {
		port = DefaultHTTPPort
	}

	// Prefer the outbound interface IP via a UDP dial (no packet actually sent)
	if conn, err := net.Dial("udp4", "8.8.8.8:80"); err == nil {
		if ua, ok := conn.LocalAddr().(*net.UDPAddr); ok && ua.IP != nil && !ua.IP.IsLoopback() {
			ip := ua.IP.To4()
			_ = conn.Close()
			if ip != nil {
				return fmt.Sprintf("%s:%d", ip.String(), port)
			}
		} else {
			_ = conn.Close()
		}
	}

	// Fallback: enumerate non-loopback IPv4 interfaces
	ifaces, err := net.Interfaces()
	if err == nil {
		for _, iface := range ifaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, a := range addrs {
				ipNet, ok := a.(*net.IPNet)
				if !ok || ipNet.IP == nil {
					continue
				}
				ip4 := ipNet.IP.To4()
				if ip4 != nil && !ip4.IsLoopback() && !ip4.IsLinkLocalUnicast() {
					return fmt.Sprintf("%s:%d", ip4.String(), port)
				}
			}
		}
	}
	return fmt.Sprintf("127.0.0.1:%d", port)
}
