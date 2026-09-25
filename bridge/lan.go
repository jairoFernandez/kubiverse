package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// --lan: serve the game to phones/tablets on the local network. The bridge
// then listens on every interface, so a token is mandatory (a random one is
// generated if none is given) and the LAN addresses are allowed as origins.
// It is served over HTTPS with a self-signed certificate made for the LAN
// addresses (browsers only run Godot web builds in a secure context); the
// phone warns once about the certificate and you accept it.
func lanSetup(addr, token, origins *string) []string {
	_, port, err := net.SplitHostPort(*addr)
	if err != nil || port == "" {
		port = "8088"
	}
	*addr = "0.0.0.0:" + port
	if *token == "" {
		b := make([]byte, 12)
		rand.Read(b)
		*token = hex.EncodeToString(b)
	}
	var urls, extra []string
	for _, ip := range lanIPs() {
		origin := fmt.Sprintf("https://%s:%s", ip.addr, port)
		extra = append(extra, origin)
		if !ip.virtual {
			urls = append(urls, fmt.Sprintf("%s/?token=%s", origin, *token))
		}
	}
	if *origins != "" {
		extra = append(extra, *origins)
	}
	*origins = strings.Join(extra, ",")
	return urls
}

type lanIP struct {
	addr    string
	virtual bool // docker/OrbStack/VM bridges: phones can't reach them
}

var virtualIface = []string{"bridge", "docker", "br-", "veth", "vmnet", "vboxnet", "virbr", "cni", "flannel", "utun", "tun", "tap", "orb", "kind"}

// lanIPs: private IPv4 addresses of the interfaces that are up.
func lanIPs() []lanIP {
	var out []lanIP
	ifaces, _ := net.Interfaces()
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if ok && ipn.IP.To4() != nil && ipn.IP.IsPrivate() {
				v := false
				for _, p := range virtualIface {
					v = v || strings.HasPrefix(ifc.Name, p)
				}
				out = append(out, lanIP{ipn.IP.String(), v})
			}
		}
	}
	return out
}

// exposed reports whether addr listens beyond this machine.
func exposed(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return true
	}
	return !isLoopback(host)
}

// lanCert returns a self-signed certificate for localhost + the LAN IPs,
// reusing the saved one while it still covers them (so the phone only has
// to accept it once).
func lanCert(dir string) (certFile, keyFile string, err error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", "", err
	}
	certFile, keyFile = filepath.Join(dir, "lan-cert.pem"), filepath.Join(dir, "lan-key.pem")
	ips := []net.IP{net.ParseIP("127.0.0.1")}
	for _, ip := range lanIPs() {
		ips = append(ips, net.ParseIP(ip.addr))
	}
	if raw, err := os.ReadFile(certFile); err == nil {
		if blk, _ := pem.Decode(raw); blk != nil {
			if c, err := x509.ParseCertificate(blk.Bytes); err == nil && time.Until(c.NotAfter) > 7*24*time.Hour && coversAll(c, ips) {
				if _, err := os.Stat(keyFile); err == nil {
					return certFile, keyFile, nil
				}
			}
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 62))
	tpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "Kubiverse bridge (LAN)"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  ips,
		DNSNames:     []string{"localhost"},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return "", "", err
	}
	kb, _ := x509.MarshalECPrivateKey(key)
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		return "", "", err
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600); err != nil {
		return "", "", err
	}
	return certFile, keyFile, nil
}

func coversAll(c *x509.Certificate, ips []net.IP) bool {
	for _, ip := range ips {
		found := false
		for _, have := range c.IPAddresses {
			found = found || have.Equal(ip)
		}
		if !found {
			return false
		}
	}
	return true
}
