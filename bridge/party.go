package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/coder/websocket"
)

// Multiplayer ("party"): the player who runs the bridge (the host) invites
// friends into a cluster's world. Everyone sees everyone move and shoot
// (paintball: shots only hurt players, never the cluster), and when the
// cluster goes into alarm the game turns into a shared mission.
//
// Two pieces live here:
//   invites  codes the host hands out. A code is a credential of its own,
//            tied to one context, that only opens the read-only routes in
//            guestRoutes: a guest can look at the cluster and play, but no
//            change of any kind goes through with it, whatever the game
//            sends. The bridge's real token is never shared.
//   party    a relay per cluster (/api/play WebSocket): small JSON messages
//            (positions, shots, hits, mission progress) stamped with the
//            sender's id and passed on to the others, with limits on size,
//            rate and number of players.

const (
	inviteTTL     = 24 * time.Hour
	maxInvites    = 32
	partyMax      = 8    // players in one cluster's party
	partyMsgMax   = 2048 // bytes per message
	partyRate     = 30.0 // messages per second per player (burst the same)
	partyNameMax  = 20
	inviteCodeLen = 10
)

// Routes a guest may call: all of them only read, and always the
// invitation's cluster. Everything else answers 403 to a guest.
var guestRoutes = map[string]bool{
	"/api/version": true, "/api/whoami": true, "/api/state": true, "/api/summary": true,
	"/api/ws": true, "/api/play": true, "/api/pod": true, "/api/logs": true,
	"/api/obs": true, "/api/series": true, "/api/rollout": true, "/api/cani": true,
}

// ---------------------------------------------------------------- invites

type invite struct {
	Code    string    `json:"code"`
	Context string    `json:"context"`
	Label   string    `json:"label,omitempty"`
	Created time.Time `json:"created"`
	Expires time.Time `json:"expires"`
}

type invites struct {
	mu  sync.Mutex
	m   map[string]invite
	now func() time.Time // tests move the clock
}

func newInvites() *invites {
	return &invites{m: map[string]invite{}, now: time.Now}
}

// Codes avoid look-alike characters: they are read out loud and typed on phones.
const inviteAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

func newInviteCode() string {
	b := make([]byte, inviteCodeLen)
	rand.Read(b)
	for i := range b {
		b[i] = inviteAlphabet[int(b[i])%len(inviteAlphabet)]
	}
	return string(b)
}

func (iv *invites) create(ctx, label string) (invite, error) {
	iv.mu.Lock()
	defer iv.mu.Unlock()
	iv.prune()
	if len(iv.m) >= maxInvites {
		return invite{}, errors.New("too many open invitations: revoke some first")
	}
	now := iv.now()
	in := invite{Code: newInviteCode(), Context: ctx, Label: cleanName(label), Created: now, Expires: now.Add(inviteTTL)}
	iv.m[in.Code] = in
	return in, nil
}

// valid returns the invitation a code belongs to, if it is still open.
func (iv *invites) valid(code string) (invite, bool) {
	if iv == nil || len(code) != inviteCodeLen {
		return invite{}, false
	}
	iv.mu.Lock()
	defer iv.mu.Unlock()
	in, ok := iv.m[code]
	if !ok || !iv.now().Before(in.Expires) {
		return invite{}, false
	}
	return in, true
}

func (iv *invites) revoke(code string) bool {
	iv.mu.Lock()
	defer iv.mu.Unlock()
	_, ok := iv.m[code]
	delete(iv.m, code)
	return ok
}

func (iv *invites) list() []invite {
	iv.mu.Lock()
	defer iv.mu.Unlock()
	iv.prune()
	out := []invite{}
	for _, in := range iv.m {
		out = append(out, in)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created.Before(out[j].Created) })
	return out
}

// prune drops expired invitations. Caller holds iv.mu.
func (iv *invites) prune() {
	now := iv.now()
	for k, in := range iv.m {
		if !now.Before(in.Expires) {
			delete(iv.m, k)
		}
	}
}

type guestKey struct{}

// guestFrom: the invitation a request came in with (ok false = not a guest).
func guestFrom(ctx context.Context) (invite, bool) {
	in, ok := ctx.Value(guestKey{}).(invite)
	return in, ok
}

// asGuest admits a request made with an invitation code: only the read-only
// routes, only GET, and only the invitation's cluster (?context= is
// overwritten). It writes the refusal itself and returns nil then.
func asGuest(w http.ResponseWriter, r *http.Request, in invite) *http.Request {
	if r.Method != http.MethodGet || !guestRoutes[r.URL.Path] {
		http.Error(w, "guests can only watch and play: changes are made by the host", http.StatusForbidden)
		return nil
	}
	r = r.Clone(context.WithValue(r.Context(), guestKey{}, in))
	q := r.URL.Query()
	q.Set("context", in.Context)
	q.Del("token")
	r.URL.RawQuery = q.Encode()
	return r
}

// /api/party/invite (host only): GET lists the open invitations, POST
// {context?, label?} makes one, DELETE ?code= revokes it.
func (h *Hub) handleInvite(w http.ResponseWriter, r *http.Request) {
	if _, guest := guestFrom(r.Context()); guest {
		writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": "only the host can invite"})
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "invites": h.invites.list()})
	case http.MethodPost:
		var req struct {
			Context string `json:"context"`
			Label   string `json:"label"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
			return
		}
		if req.Context == "" {
			req.Context = h.defaultCtx
		}
		if !h.known(req.Context) {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "unknown context " + req.Context})
			return
		}
		in, err := h.invites.create(req.Context, req.Label)
		if err != nil {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		log.Printf("party: invitation for %s created (expires %s)", in.Context, in.Expires.Format(time.RFC3339))
		// Where to send friends: the LAN addresses (--lan); otherwise the
		// game uses the URL it reached us at (a tunnel's, for internet).
		urls := h.shareURLs
		if urls == nil {
			urls = []string{}
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "invite": in, "urls": urls})
	case http.MethodDelete:
		writeJSON(w, http.StatusOK, map[string]any{"ok": h.invites.revoke(r.URL.Query().Get("code"))})
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// known: a context the bridge can serve (listed, or already running).
func (h *Hub) known(name string) bool {
	h.mu.Lock()
	_, running := h.clusters[name]
	h.mu.Unlock()
	if running {
		return true
	}
	list, _ := h.contexts()
	for _, c := range list {
		if c.Name == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- party

// Message types players may send. "ask" (a guest asking the host to apply
// a fix) only reaches hosts.
var partyTypes = map[string]bool{"pos": true, "shot": true, "hit": true, "dead": true, "prog": true, "ask": true}

type party struct {
	mu      sync.Mutex
	next    int
	members map[int]*member
	now     func() time.Time
}

type member struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Color int    `json:"color"`
	Host  bool   `json:"host"`
	send  chan []byte
	// token bucket for the rate limit
	tokens float64
	at     time.Time
}

func newParty() *party {
	return &party{members: map[int]*member{}, now: time.Now}
}

// partyOf: this cluster's party (made on first use).
func (b *Bridge) partyOf() *party {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.party == nil {
		b.party = newParty()
	}
	return b.party
}

// cleanName keeps a player name printable and short.
func cleanName(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsPrint(r) {
			return r
		}
		return -1
	}, strings.TrimSpace(s))
	if r := []rune(s); len(r) > partyNameMax {
		s = string(r[:partyNameMax])
	}
	return strings.TrimSpace(s)
}

// join adds a player and tells the others. The color is the lowest one free.
func (p *party) join(name string, host bool) (*member, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.members) >= partyMax {
		return nil, errors.New("the party is full")
	}
	used := map[int]bool{}
	for _, m := range p.members {
		used[m.Color] = true
	}
	p.next++
	m := &member{ID: p.next, Name: cleanName(name), Host: host, send: make(chan []byte, 64), tokens: partyRate, at: p.now()}
	for used[m.Color] {
		m.Color++
	}
	if m.Name == "" {
		m.Name = "Player " + strconv.Itoa(m.ID)
	}
	join, _ := json.Marshal(map[string]any{"t": "join", "p": m})
	p.fanout(join, m.ID, false)
	p.members[m.ID] = m
	return m, nil
}

func (p *party) leave(m *member) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, ok := p.members[m.ID]; !ok {
		return
	}
	delete(p.members, m.ID)
	msg, _ := json.Marshal(map[string]any{"t": "leave", "id": m.ID})
	p.fanout(msg, m.ID, false)
}

// roster: everyone in the party, by id.
func (p *party) roster() []member {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]member, 0, len(p.members))
	for _, m := range p.members {
		out = append(out, member{ID: m.ID, Name: m.Name, Color: m.Color, Host: m.Host})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (p *party) welcome(m *member) []byte {
	msg, _ := json.Marshal(map[string]any{"t": "welcome", "id": m.ID, "color": m.Color, "host": m.Host, "name": m.Name, "players": p.roster()})
	return msg
}

// errDropped: the message was not passed on (rate, size, type, shape).
var errDropped = errors.New("dropped")

// relay checks one message from m and passes it on to the others, stamped
// with m's id (whatever id the sender wrote is replaced).
func (p *party) relay(m *member, raw []byte) error {
	if len(raw) > partyMsgMax {
		return errDropped
	}
	var msg map[string]any
	if json.Unmarshal(raw, &msg) != nil {
		return errDropped
	}
	t, _ := msg["t"].(string)
	if !partyTypes[t] {
		return errDropped
	}
	if t == "hit" {
		if _, ok := msg["v"].(float64); !ok {
			return errDropped
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.now()
	m.tokens += now.Sub(m.at).Seconds() * partyRate
	if m.tokens > partyRate {
		m.tokens = partyRate
	}
	m.at = now
	if m.tokens < 1 {
		return errDropped
	}
	m.tokens--
	msg["id"] = m.ID
	out, _ := json.Marshal(msg)
	p.fanout(out, m.ID, t == "ask")
	return nil
}

// fanout queues msg for everyone but from (only hosts if hostsOnly). A slow
// player misses messages instead of slowing the others. Caller holds p.mu.
func (p *party) fanout(msg []byte, from int, hostsOnly bool) {
	for id, o := range p.members {
		if id == from || (hostsOnly && !o.Host) {
			continue
		}
		select {
		case o.send <- msg:
		default:
		}
	}
}

// GET /api/play?name=: the party relay of this cluster. The host is whoever
// came in with the bridge's own access (not an invitation code).
func (b *Bridge) handlePlay(w http.ResponseWriter, r *http.Request) {
	p := b.partyOf()
	_, guest := guestFrom(r.Context())
	name := r.URL.Query().Get("name")
	if id := identityFrom(r.Context()); id.User != "" {
		name = id.User // team mode: the signed-in name, not a chosen one
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true}) // origin checked in guard
	if err != nil {
		return
	}
	defer conn.CloseNow()
	m, err := p.join(name, !guest)
	if err != nil {
		conn.Close(websocket.StatusTryAgainLater, err.Error())
		return
	}
	defer p.leave(m)
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	log.Printf("party: %s joined %s from %s (host=%v)", m.Name, b.contextName, ip, m.Host)
	conn.SetReadLimit(partyMsgMax)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() {
		defer cancel()
		for {
			_, raw, err := conn.Read(ctx)
			if err != nil {
				return
			}
			_ = p.relay(m, raw)
		}
	}()
	if err := conn.Write(ctx, websocket.MessageText, p.welcome(m)); err != nil {
		return
	}
	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-m.send:
			wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Write(wctx, websocket.MessageText, msg)
			wcancel()
			if err != nil {
				return
			}
		case <-ping.C:
			if err := conn.Ping(ctx); err != nil {
				return
			}
		}
	}
}
