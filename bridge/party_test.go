package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// partyHub: a hub with one ready test cluster ("test") behind the real
// routes, with the bridge token "secret".
func partyHub(t *testing.T) (*Hub, *httptest.Server) {
	t.Helper()
	t.Setenv("KUBECONFIG", t.TempDir()+"/none") // never the real kubeconfig
	h := newHub(context.Background(), "", "test", t.TempDir(), false, "secret")
	b := newTestBridge(t)
	b.ready.Store(true)
	h.clusters["test"] = b
	h.clusters["other"] = newTestBridge(t)
	h.clusters["other"].contextName = "other"
	h.clusters["other"].ready.Store(true)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/summary", h.cluster((*Bridge).handleSummary))
	mux.HandleFunc("GET /api/whoami", h.auth(h.handleWhoami))
	mux.HandleFunc("POST /api/action", h.cluster((*Bridge).handleAction))
	mux.HandleFunc("GET /api/play", h.cluster((*Bridge).handlePlay))
	mux.HandleFunc("/api/party/invite", h.auth(h.handleInvite))
	mux.HandleFunc("/api/kind", h.auth(h.handleKind))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return h, srv
}

func TestInviteCodes(t *testing.T) {
	iv := newInvites()
	now := time.Unix(1_000_000, 0)
	iv.now = func() time.Time { return now }
	a, err := iv.create("ctx-a", "  Ana\x07 la del equipo de plataforma  ")
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Code) != inviteCodeLen || strings.ContainsAny(a.Code, "0O1lI") {
		t.Errorf("code %q: want %d chars without look-alikes", a.Code, inviteCodeLen)
	}
	if a.Label != "Ana la del equipo de" {
		t.Errorf("label not cleaned/clipped: %q", a.Label)
	}
	b, _ := iv.create("ctx-b", "")
	if a.Code == b.Code {
		t.Error("two invitations got the same code")
	}
	if in, ok := iv.valid(a.Code); !ok || in.Context != "ctx-a" {
		t.Errorf("valid(a) = %+v %v", in, ok)
	}
	for _, bad := range []string{"", "secret", strings.ToUpper(a.Code), a.Code[:inviteCodeLen-1]} {
		if _, ok := iv.valid(bad); ok {
			t.Errorf("code %q accepted", bad)
		}
	}
	if !iv.revoke(b.Code) || iv.revoke(b.Code) {
		t.Error("revoke should succeed once")
	}
	if _, ok := iv.valid(b.Code); ok {
		t.Error("revoked code still valid")
	}
	if n := len(iv.list()); n != 1 {
		t.Errorf("list has %d, want 1", n)
	}
	now = now.Add(inviteTTL)
	if _, ok := iv.valid(a.Code); ok {
		t.Error("expired code still valid")
	}
	if n := len(iv.list()); n != 0 {
		t.Errorf("expired invitations still listed: %d", n)
	}
	for i := 0; i < maxInvites; i++ {
		if _, err := iv.create("c", ""); err != nil {
			t.Fatalf("invitation %d: %v", i, err)
		}
	}
	if _, err := iv.create("c", ""); err == nil {
		t.Error("more than maxInvites open invitations allowed")
	}
	var nilInv *invites
	if _, ok := nilInv.valid(a.Code); ok {
		t.Error("nil invites accepted a code")
	}
}

func do(t *testing.T, method, url, token string, body any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, url, rd)
	if token != "" {
		req.Header.Set("X-Bridge-Token", token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func makeInvite(t *testing.T, srv *httptest.Server, ctx string) string {
	t.Helper()
	code, out := do(t, "POST", srv.URL+"/api/party/invite", "secret", map[string]string{"context": ctx, "label": "friend"})
	if code != 200 || out["ok"] != true {
		t.Fatalf("create invite: %d %v", code, out)
	}
	return out["invite"].(map[string]any)["code"].(string)
}

// A guest can watch and play, never change anything, and only sees the
// invitation's cluster.
func TestGuestIsReadOnly(t *testing.T) {
	h, srv := partyHub(t)
	// Unknown contexts can't be invited to.
	if _, out := do(t, "POST", srv.URL+"/api/party/invite", "secret", map[string]string{"context": "nope"}); out["ok"] != false {
		t.Errorf("invite to an unknown context: %v", out)
	}
	if code, _ := do(t, "POST", srv.URL+"/api/party/invite", "", nil); code != 401 {
		t.Errorf("invite without token: %d, want 401", code)
	}
	guest := makeInvite(t, srv, "test")
	h.shareURLs = []string{"https://192.0.2.10:8088"}
	if _, out := do(t, "POST", srv.URL+"/api/party/invite", "secret", nil); out["urls"].([]any)[0] != "https://192.0.2.10:8088" ||
		out["invite"].(map[string]any)["context"] != "test" {
		t.Errorf("invite with --lan: %v (default context, LAN urls)", out)
	}

	code, out := do(t, "GET", srv.URL+"/api/whoami", guest, nil)
	if code != 200 || out["guest"] != true || out["guest_context"] != "test" {
		t.Errorf("whoami as guest: %d %v", code, out)
	}
	if _, out := do(t, "GET", srv.URL+"/api/whoami", "secret", nil); out["guest"] != false {
		t.Errorf("host seen as guest: %v", out)
	}
	// Reads work, and ?context= can't escape to another cluster.
	code, out = do(t, "GET", srv.URL+"/api/summary?context=other&token="+guest, "", nil)
	if code != 200 || out["context"] != "test" {
		t.Errorf("guest summary of another context: %d context=%v (want test)", code, out["context"])
	}
	// Changes are refused before reaching the cluster, even on sandboxes.
	for _, c := range []struct{ method, path string }{
		{"POST", "/api/action"}, {"POST", "/api/party/invite"}, {"GET", "/api/party/invite"},
		{"DELETE", "/api/party/invite?code=x"}, {"GET", "/api/kind"}, {"POST", "/api/kind"},
	} {
		code, _ := do(t, c.method, srv.URL+c.path, guest, map[string]any{"action": "delete_pod", "ns": "default", "name": "x"})
		if code != http.StatusForbidden {
			t.Errorf("guest %s %s: %d, want 403", c.method, c.path, code)
		}
	}
	// A wrong code is just a wrong token.
	if code, _ := do(t, "GET", srv.URL+"/api/whoami", "abcdefghjk", nil); code != 401 {
		t.Errorf("bad code: %d, want 401", code)
	}
	// Revoked: out.
	if _, out := do(t, "DELETE", srv.URL+"/api/party/invite?code="+guest, "secret", nil); out["ok"] != true {
		t.Errorf("revoke: %v", out)
	}
	if code, _ := do(t, "GET", srv.URL+"/api/whoami", guest, nil); code != 401 {
		t.Errorf("revoked code: %d, want 401", code)
	}
	if _, out := do(t, "GET", srv.URL+"/api/party/invite", "secret", nil); len(out["invites"].([]any)) != 1 { // the --lan one is left
		t.Errorf("revoked invitation still listed: %v", out)
	}
}

// On a localhost bridge without a token, an invitation code still makes a
// guest (so two games on one machine can test the party).
func TestGuestWithoutBridgeToken(t *testing.T) {
	h, srv := partyHub(t)
	h.token = ""
	in, _ := h.invites.create("test", "")
	if _, out := do(t, "GET", srv.URL+"/api/whoami", in.Code, nil); out["guest"] != true {
		t.Errorf("code on a tokenless bridge: %v", out)
	}
	if code, _ := do(t, "POST", srv.URL+"/api/action", in.Code, map[string]any{}); code != 403 {
		t.Errorf("guest action on a tokenless bridge: %d", code)
	}
	if _, out := do(t, "GET", srv.URL+"/api/whoami", "", nil); out["guest"] != false {
		t.Errorf("no token on a tokenless bridge should be the host: %v", out)
	}
}

func TestPartyRelay(t *testing.T) {
	p := newParty()
	now := time.Unix(0, 0)
	p.now = func() time.Time { return now }
	a, _ := p.join("ana", true)
	b, err := p.join("  ", false)
	if err != nil {
		t.Fatal(err)
	}
	if b.Name != "Player 2" || a.Color == b.Color {
		t.Errorf("b = %+v (a color %d)", b, a.Color)
	}
	// a hears that b joined.
	if msg := recv(t, a); msg["t"] != "join" || msg["p"].(map[string]any)["name"] != "Player 2" {
		t.Errorf("join message: %v", msg)
	}
	// Positions go to the others, stamped with the sender (spoofed id replaced).
	if err := p.relay(b, []byte(`{"t":"pos","id":1,"p":[1,2,3],"y":0.5,"l":"plant"}`)); err != nil {
		t.Fatal(err)
	}
	if msg := recv(t, a); msg["t"] != "pos" || msg["id"] != float64(b.ID) {
		t.Errorf("relayed pos: %v", msg)
	}
	if len(b.send) != 0 {
		t.Error("sender got its own message back")
	}
	// Junk is dropped.
	for _, bad := range []string{`nope`, `{"t":"action","action":"delete_pod"}`, `{"t":"hit","v":"x"}`, `{"t":"hit"}`,
		`{"t":"pos","pad":"` + strings.Repeat("x", partyMsgMax) + `"}`} {
		if p.relay(b, []byte(bad)) == nil {
			t.Errorf("relayed %.40s", bad)
		}
	}
	if len(a.send) != 0 {
		t.Errorf("dropped messages reached a: %d", len(a.send))
	}
	// "ask" (guest asks to apply a fix) only reaches hosts.
	c, _ := p.join("carla", false)
	recv(t, a)
	recv(t, b)
	if err := p.relay(c, []byte(`{"t":"ask","req":{"action":"restart"}}`)); err != nil {
		t.Fatal(err)
	}
	if msg := recv(t, a); msg["t"] != "ask" || msg["id"] != float64(c.ID) {
		t.Errorf("host didn't get the ask: %v", msg)
	}
	if len(b.send) != 0 {
		t.Error("a guest got another guest's ask")
	}
	// Rate limit: a burst of partyRate, then refills with time.
	sent := 0
	for i := 0; i < int(partyRate)*2; i++ {
		if p.relay(c, []byte(`{"t":"pos"}`)) == nil {
			sent++
		}
	}
	if sent != int(partyRate)-1 { // one token went on the ask
		t.Errorf("burst let %d through, want %d", sent, int(partyRate)-1)
	}
	now = now.Add(time.Second)
	if p.relay(c, []byte(`{"t":"pos"}`)) != nil {
		t.Error("tokens did not refill after a second")
	}
	// Leaving tells the others; the roster follows.
	p.leave(b)
	p.leave(b)
	drain(a)
	if r := p.roster(); len(r) != 2 || r[0].ID != a.ID || r[1].ID != c.ID {
		t.Errorf("roster after leave: %+v", r)
	}
	// Full party.
	for len(p.roster()) < partyMax {
		if _, err := p.join("x", false); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := p.join("one too many", false); err == nil {
		t.Error("joined a full party")
	}
	// A new player reuses the lowest free color.
	q := newParty()
	q1, _ := q.join("1", true)
	q2, _ := q.join("2", false)
	q.leave(q1)
	q3, _ := q.join("3", false)
	if q3.Color != q1.Color || q3.Color == q2.Color {
		t.Errorf("colors: %d %d %d", q1.Color, q2.Color, q3.Color)
	}
}

func recv(t *testing.T, m *member) map[string]any {
	t.Helper()
	select {
	case raw := <-m.send:
		var msg map[string]any
		if err := json.Unmarshal(raw, &msg); err != nil {
			t.Fatal(err)
		}
		return msg
	default:
		t.Fatalf("%s got nothing", m.Name)
		return nil
	}
}

func drain(m *member) {
	for len(m.send) > 0 {
		<-m.send
	}
}

func TestCleanName(t *testing.T) {
	for in, want := range map[string]string{
		"  ana ":                        "ana",
		"a\x00b\nc":                     "abc",
		"ñandú":                         "ñandú",
		strings.Repeat("é", 30):         strings.Repeat("é", partyNameMax),
		"12345678901234567890 trailing": "12345678901234567890",
	} {
		if got := cleanName(in); got != want {
			t.Errorf("cleanName(%q) = %q, want %q", in, got, want)
		}
	}
}

// Two games over the real WebSocket: host and guest see each other.
func TestPlayWebSocket(t *testing.T) {
	_, srv := partyHub(t)
	code := makeInvite(t, srv, "test")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/play"
	host, _, err := websocket.Dial(ctx, ws+"?name=host&token=secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer host.CloseNow()
	hw := readMsg(t, ctx, host)
	if hw["t"] != "welcome" || hw["host"] != true {
		t.Fatalf("host welcome: %v", hw)
	}
	guest, _, err := websocket.Dial(ctx, ws+"?name=guest&context=other&token="+code, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer guest.CloseNow()
	gw := readMsg(t, ctx, guest)
	if gw["t"] != "welcome" || gw["host"] != false || len(gw["players"].([]any)) != 2 {
		t.Fatalf("guest welcome (same party as the host, not 'other'): %v", gw)
	}
	if j := readMsg(t, ctx, host); j["t"] != "join" {
		t.Fatalf("host didn't see the guest join: %v", j)
	}
	if err := guest.Write(ctx, websocket.MessageText, []byte(`{"t":"shot","from":[0,1,0],"to":[3,1,0],"w":"blaster"}`)); err != nil {
		t.Fatal(err)
	}
	if s := readMsg(t, ctx, host); s["t"] != "shot" || s["id"] != gw["id"] {
		t.Errorf("shot relayed as %v", s)
	}
	guest.Close(websocket.StatusNormalClosure, "")
	if l := readMsg(t, ctx, host); l["t"] != "leave" || l["id"] != gw["id"] {
		t.Errorf("leave: %v", l)
	}
	// A bad invitation can't open the relay.
	if _, _, err := websocket.Dial(ctx, ws+"?token=abcdefghjk", nil); err == nil {
		t.Error("relay opened with a bad code")
	}
}

func readMsg(t *testing.T, ctx context.Context, c *websocket.Conn) map[string]any {
	t.Helper()
	_, raw, err := c.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	return m
}
