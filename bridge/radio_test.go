package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeFFmpeg: a started "ffmpeg" whose output the test writes.
type fakeFFmpeg struct {
	audio, video, logs *io.PipeWriter
	pipes              radioPipes
	args               []string
	done               chan struct{}
	once               sync.Once
	mu                 sync.Mutex
	killed             bool
}

func (f *fakeFFmpeg) Kill() error {
	f.mu.Lock()
	f.killed = true
	f.mu.Unlock()
	f.exit()
	return nil
}

func (f *fakeFFmpeg) wasKilled() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.killed
}

func (f *fakeFFmpeg) Wait() error { <-f.done; return nil }

// exit: the process ends, its pipes close.
func (f *fakeFFmpeg) exit() {
	f.once.Do(func() {
		f.audio.Close()
		f.logs.Close()
		if f.video != nil {
			f.video.Close()
		}
		close(f.done)
	})
}

type radioRig struct {
	r       *radio
	mu      sync.Mutex
	started []*fakeFFmpeg
	ytErr   error
	ytURLs  []string
	items   []radioItem
	q       radioQuality
}

func (g *radioRig) last(t *testing.T) *fakeFFmpeg {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		g.mu.Lock()
		n := len(g.started)
		g.mu.Unlock()
		if n > 0 {
			g.mu.Lock()
			defer g.mu.Unlock()
			return g.started[n-1]
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("ffmpeg never started")
	return nil
}

func (g *radioRig) count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.started)
}

func newRadioRig(installed ...string) *radioRig {
	g := &radioRig{r: newRadio(), ytURLs: []string{"https://v.example/video", "https://v.example/audio"}}
	g.r.lookPath = func(name string) (string, error) {
		for _, i := range installed {
			if name == i {
				return "/usr/bin/" + i, nil
			}
		}
		return "", errors.New("not found")
	}
	g.r.start = func(name string, args []string, video bool) (radioProc, radioPipes, error) {
		f := &fakeFFmpeg{args: args, done: make(chan struct{})}
		var ar, lr *io.PipeReader
		ar, f.audio = io.Pipe()
		lr, f.logs = io.Pipe()
		f.pipes = radioPipes{audio: ar, logs: lr}
		if video {
			var vr *io.PipeReader
			vr, f.video = io.Pipe()
			f.pipes.video = vr
		}
		g.mu.Lock()
		g.started = append(g.started, f)
		g.mu.Unlock()
		return f, f.pipes, nil
	}
	g.r.resolve = func(_, _ string, _ bool, q radioQuality) (string, []string, error) {
		g.mu.Lock()
		g.q = q
		g.mu.Unlock()
		return "Lofi video", g.ytURLs, g.ytErr
	}
	g.r.list = func(_, _ string) ([]radioItem, error) {
		return g.items, g.ytErr
	}
	return g
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting: " + what)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestRadioURL(t *testing.T) {
	for _, ok := range []string{"https://ice2.somafm.com/defcon-128-mp3", "http://radio.example:8000/live", " https://youtu.be/abc "} {
		if _, err := radioURL(ok); err != nil {
			t.Errorf("%q refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "file:///etc/passwd", "/etc/passwd", "concat:a|b", "https://", "-i", "http://x/\nfoo", "http://x/a b", "https://x/" + strings.Repeat("a", 4100)} {
		if _, err := radioURL(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestIsYouTube(t *testing.T) {
	for _, u := range []string{"https://www.youtube.com/watch?v=x", "https://youtu.be/x", "https://m.youtube.com/watch?v=x", "https://music.youtube.com/watch?v=x", "https://www.youtube.com/@LofiGirl/live"} {
		if !isYouTube(u) {
			t.Errorf("%s should be YouTube", u)
		}
	}
	for _, u := range []string{"https://ice2.somafm.com/x", "https://notyoutube.com/x", "::"} {
		if isYouTube(u) {
			t.Errorf("%s is not YouTube", u)
		}
	}
}

func TestFFmpegArgs(t *testing.T) {
	a := ffmpegArgs([]string{"https://s/x"}, false, false, radioQualities["low"], "pipe:3")
	j := strings.Join(a, " ")
	for _, want := range []string{"-i https://s/x", "-map 0:a:0", "-f f32le pipe:1", "-ar 44100", "-ac 2", "-loglevel verbose", "-nostdin"} {
		if !strings.Contains(j, want) {
			t.Errorf("radio args miss %q: %s", want, j)
		}
	}
	if !slices.Contains(a, "-re") || strings.Contains(j, "mjpeg") {
		t.Errorf("a radio is read in real time (its burst on connect would overflow the game) and has no picture: %s", j)
	}
	v := strings.Join(ffmpegArgs([]string{"https://v/vid", "https://v/aud"}, true, true, radioQualities["low"], "pipe:3"), " ")
	for _, want := range []string{"-re -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i https://v/vid", "-re -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i https://v/aud",
		"-map 1:a:0", "-map 0:v:0", "fps=15,scale=426:-2", "-c:v mjpeg", "-q:v 7", "-f image2pipe pipe:3", "-loglevel warning"} {
		if !strings.Contains(v, want) {
			t.Errorf("YouTube video args miss %q: %s", want, v)
		}
	}
	if !strings.HasSuffix(v, "pipe:3") {
		t.Errorf("the video output must come last (startFFmpeg swaps it for a port): %s", v)
	}
	if m := strings.Join(ffmpegArgs([]string{"https://v/both"}, true, true, radioQualities["low"], "pipe:3"), " "); !strings.Contains(m, "-map 0:a:0") || !strings.Contains(m, "-map 0:v:0") {
		t.Errorf("one muxed input carries both: %s", m)
	}
}

func TestParseResolved(t *testing.T) {
	title, urls, err := parseResolved("Lofi radio\nhttps://v/1\nhttps://v/2\n")
	if err != nil || title != "Lofi radio" || !slices.Equal(urls, []string{"https://v/1", "https://v/2"}) {
		t.Fatalf("got %q %v %v", title, urls, err)
	}
	if _, _, err := parseResolved("Only a title\n"); err == nil {
		t.Error("no stream address must be an error")
	}
	if _, u, _ := parseResolved("t\nfile:///etc/passwd\nhttps://v/1"); !slices.Equal(u, []string{"https://v/1"}) {
		t.Errorf("non-web addresses from yt-dlp are dropped: %v", u)
	}
	if lastLine("a\nb\n  ERROR: gone  \n") != "ERROR: gone" {
		t.Error("lastLine")
	}
}

func TestRadioStreamsToTheGame(t *testing.T) {
	g := newRadioRig("ffmpeg")
	r := g.r
	l := r.listen()
	if err := r.play("https://s/one", true, ""); err != nil {
		t.Fatal(err)
	}
	f := g.last(t)
	if f.pipes.video != nil {
		t.Error("a radio station never decodes video, even if asked")
	}
	waitFor(t, "playing", r.playing)
	// 50 ms of PCM, written in two odd pieces, arrives as one 'A' chunk.
	pcm := make([]byte, radioChunk)
	for i := 0; i < len(pcm); i += 4 {
		binary.LittleEndian.PutUint32(pcm[i:], math.Float32bits(0.25))
	}
	go func() {
		f.audio.Write(pcm[:1001])
		f.audio.Write(pcm[1001:])
	}()
	select {
	case msg := <-l.ch:
		if msg[0] != 'A' || len(msg) != 1+radioChunk || math.Float32frombits(binary.LittleEndian.Uint32(msg[1:])) != 0.25 {
			t.Fatalf("audio chunk: %c %d bytes", msg[0], len(msg))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no audio reached the game")
	}
	// The stream's "now playing" from ffmpeg's log.
	go f.logs.Write([]byte("[https @ 0x1] Metadata update for StreamTitle: Artist - Song\n"))
	waitFor(t, "title", func() bool { return r.status().Title == "Artist - Song" })
	st := r.status()
	if !st.Available || st.YouTube || !st.Playing || st.Tuning || st.URL != "https://s/one" {
		t.Fatalf("status: %+v", st)
	}
	// A new station replaces the old ffmpeg.
	if err := r.play("https://s/two", false, ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "second ffmpeg", func() bool { return g.count() == 2 })
	if !f.wasKilled() {
		t.Error("the previous ffmpeg keeps running")
	}
	waitFor(t, "playing two", r.playing)
	time.Sleep(10 * time.Millisecond) // the old one's exit must not clear the new one
	if st := r.status(); !st.Playing || st.URL != "https://s/two" || st.Title != "" {
		t.Fatalf("after switching: %+v", st)
	}
	r.stop()
	if !g.last(t).wasKilled() || r.playing() || r.status().Error != "" {
		t.Errorf("stop must kill ffmpeg quietly: %+v", r.status())
	}
	r.unlisten(l)
}

func TestRadioYouTubeVideo(t *testing.T) {
	g := newRadioRig("ffmpeg", "yt-dlp")
	r := g.r
	l := r.listen()
	if err := r.play("https://www.youtube.com/@LofiGirl/live", true, ""); err != nil {
		t.Fatal(err)
	}
	f := g.last(t)
	j := strings.Join(f.args, " ")
	if !strings.Contains(j, "-i https://v.example/video") || !strings.Contains(j, "-map 1:a:0") || f.pipes.video == nil {
		t.Fatalf("ffmpeg must read yt-dlp's streams and make frames: %s", j)
	}
	waitFor(t, "title", func() bool { return r.status().Title == "Lofi video" })
	// Two JPEGs, split across writes, become two 'V' messages.
	jpeg1 := []byte{0xFF, 0xD8, 1, 2, 0xFF, 0x00, 3, 0xFF, 0xD9}
	jpeg2 := []byte{0xFF, 0xD8, 9, 0xFF, 0xD9}
	go func() {
		f.video.Write(jpeg1[:4])
		f.video.Write(append(jpeg1[4:], jpeg2[:2]...))
		f.video.Write(jpeg2[2:])
	}()
	for i, want := range [][]byte{jpeg1, jpeg2} {
		select {
		case msg := <-l.ch:
			if msg[0] != 'V' || !slices.Equal(msg[1:], want) {
				t.Fatalf("frame %d: % x", i, msg)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("frame %d never came", i)
		}
	}
	// The video ends: the status says so.
	go f.logs.Write([]byte("[hls] HTTP error 403 Forbidden\n"))
	time.Sleep(5 * time.Millisecond)
	f.exit()
	waitFor(t, "stopped", func() bool { return !r.playing() && r.status().Error != "" })
	if e := r.status().Error; !strings.Contains(e, "403") {
		t.Errorf("why it stopped: %q", e)
	}
	r.unlisten(l)
}

func TestRadioYouTubeErrors(t *testing.T) {
	g := newRadioRig("ffmpeg")
	if err := g.r.play("https://youtu.be/x", false, ""); err == nil || !strings.Contains(err.Error(), "yt-dlp") {
		t.Fatalf("YouTube without yt-dlp: %v", err)
	}
	g = newRadioRig("ffmpeg", "yt-dlp")
	g.ytErr = errors.New("ERROR: video unavailable")
	if err := g.r.play("https://youtu.be/x", true, ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "error", func() bool { return strings.Contains(g.r.status().Error, "unavailable") })
	if g.count() != 0 || g.r.status().Playing || g.r.status().Tuning {
		t.Errorf("no ffmpeg for a video yt-dlp can't find: %+v", g.r.status())
	}
}

func TestRadioRefuses(t *testing.T) {
	g := newRadioRig()
	if err := g.r.play("https://s/x", false, ""); err == nil || !strings.Contains(err.Error(), "ffmpeg") {
		t.Fatalf("without ffmpeg: %v", err)
	}
	if st := g.r.status(); st.Available || st.Playing {
		t.Fatalf("status: %+v", st)
	}
	g = newRadioRig("ffmpeg")
	if err := g.r.play("file:///etc/passwd", false, ""); err == nil {
		t.Fatal("a local file must be refused")
	}
}

func TestRadioDropsWhenTheGameIsBehind(t *testing.T) {
	g := newRadioRig("ffmpeg")
	l := g.r.listen()
	g.r.play("https://s/x", false, "")
	f := g.last(t)
	waitFor(t, "playing", g.r.playing)
	done := make(chan struct{})
	go func() { // 3x more chunks than the queue holds, nobody reading
		f.audio.Write(make([]byte, radioChunk*cap(l.ch)*3))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("a slow game must not stall ffmpeg")
	}
	if len(l.ch) != cap(l.ch) {
		t.Errorf("queue: %d of %d", len(l.ch), cap(l.ch))
	}
	g.r.stop()
}

func TestRadioStopsWhenTheGameIsGone(t *testing.T) {
	g := newRadioRig("ffmpeg")
	r := g.r
	r.idle, r.tick = 30*time.Millisecond, 5*time.Millisecond
	l := r.listen()
	r.play("https://s/x", false, "")
	f := g.last(t)
	time.Sleep(60 * time.Millisecond)
	if f.wasKilled() {
		t.Fatal("stopped while the game was listening")
	}
	r.unlisten(l) // the game quit
	waitFor(t, "stopped", f.wasKilled)
	if !strings.Contains(r.status().Error, "stopped listening") {
		t.Fatalf("status: %+v", r.status())
	}
}

func TestRadioOneListener(t *testing.T) {
	r := newRadio()
	a := r.listen()
	b := r.listen()
	select {
	case <-a.done:
	default:
		t.Error("the older listener must be told to go")
	}
	r.unlisten(a) // late cleanup of the old one keeps the new one
	if r.lis != b {
		t.Error("the newest listener was dropped")
	}
	r.unlisten(b)
	if r.lis != nil {
		t.Error("nobody listens")
	}
}

func TestHandleRadio(t *testing.T) {
	old := music
	defer func() { music = old }()
	g := newRadioRig("ffmpeg")
	music = g.r
	h := &Hub{}
	do := func(method, body, remote string) (int, map[string]any) {
		req := httptest.NewRequest(method, "/api/radio", strings.NewReader(body))
		req.RemoteAddr = remote
		w := httptest.NewRecorder()
		h.handleRadio(w, req)
		var out map[string]any
		json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}
	local := "127.0.0.1:5555"
	if code, _ := do("POST", `{"action":"play","url":"https://s/x"}`, "192.168.1.20:5555"); code != http.StatusForbidden {
		t.Errorf("a phone on the LAN must not drive this computer's speakers: %d", code)
	}
	if code, out := do("POST", `{"action":"play","url":"https://s/x","quality":"high"}`, local); code != 200 || out["ok"] != true {
		t.Fatalf("play: %d %v", code, out)
	}
	waitFor(t, "playing", g.r.playing)
	if code, out := do("GET", "", "[::1]:5555"); code != 200 || out["playing"] != true || out["url"] != "https://s/x" {
		t.Fatalf("status: %d %v", code, out)
	}
	if code, out := do("POST", `{"action":"play","url":"file:///etc/passwd"}`, local); code != 400 || out["ok"] != false {
		t.Errorf("a file URL: %d %v", code, out)
	}
	if code, _ := do("POST", `{"action":"dance"}`, local); code != 400 {
		t.Errorf("unknown action: %d", code)
	}
	if code, _ := do("POST", `not json`, local); code != 400 {
		t.Errorf("bad JSON: %d", code)
	}
	if code, _ := do("DELETE", "", local); code != http.StatusMethodNotAllowed {
		t.Errorf("DELETE: %d", code)
	}
	if code, _ := do("POST", `{"action":"stop"}`, local); code != 200 || g.r.playing() || !g.last(t).wasKilled() {
		t.Errorf("stop: %d", code)
	}
	h.userHeader = "X-Auth-Request-Email"
	if code, _ := do("GET", "", local); code != http.StatusForbidden {
		t.Errorf("a team bridge has no speakers for the player: %d", code)
	}
}

func TestHandleRadioWS(t *testing.T) {
	old := music
	defer func() { music = old }()
	g := newRadioRig("ffmpeg")
	music = g.r
	h := &Hub{}
	srv := httptest.NewServer(http.HandlerFunc(h.handleRadioWS))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()
	waitFor(t, "listener", func() bool { g.r.mu.Lock(); defer g.r.mu.Unlock(); return g.r.lis != nil })
	g.r.play("https://s/x", false, "")
	f := g.last(t)
	go f.audio.Write(make([]byte, radioChunk))
	typ, msg, err := c.Read(ctx)
	if err != nil || typ != websocket.MessageBinary || msg[0] != 'A' || len(msg) != 1+radioChunk {
		t.Fatalf("over the socket: %v %v %d", err, typ, len(msg))
	}
	// A second game window takes over; the first is closed.
	c2, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c2.CloseNow()
	if _, _, err := c.Read(ctx); websocket.CloseStatus(err) != websocket.StatusNormalClosure {
		t.Errorf("the old listener should be closed normally: %v", err)
	}
	g.r.stop()
	c2.CloseNow() // its handler must be gone before music is restored
	waitFor(t, "handler gone", func() bool { g.r.mu.Lock(); defer g.r.mu.Unlock(); return g.r.lis == nil })
	req := httptest.NewRequest("GET", "/api/radio/ws", nil)
	req.RemoteAddr = "10.0.0.9:1"
	w := httptest.NewRecorder()
	h.handleRadioWS(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("the sound is for this computer only: %d", w.Code)
	}
}

func TestRadioQuality(t *testing.T) {
	if n, q := qualityOf("high"); n != "high" || q.Height != 480 || q.FPS != 30 {
		t.Errorf("high: %s %+v", n, q)
	}
	if n, _ := qualityOf("8k"); n != "medium" {
		t.Errorf("an unknown quality falls back to medium, not %s", n)
	}
	for name, q := range radioQualities {
		f := ytFormat(true, q)
		if !strings.Contains(f, fmt.Sprintf("height<=?%d", q.Height)) || !strings.Contains(f, "+bestaudio") {
			t.Errorf("%s: yt-dlp format %s", name, f)
		}
		a := strings.Join(ffmpegArgs([]string{"https://v/1", "https://v/2"}, true, true, q, "pipe:3"), " ")
		if !strings.Contains(a, fmt.Sprintf("fps=%d,scale=%d:-2", q.FPS, q.Width)) || !strings.Contains(a, fmt.Sprintf("-q:v %d", q.JPEG)) {
			t.Errorf("%s: ffmpeg %s", name, a)
		}
	}
	if ytFormat(false, radioQualities["high"]) != "bestaudio/best" {
		t.Error("sound only never fetches video")
	}
	g := newRadioRig("ffmpeg", "yt-dlp")
	g.r.play("https://youtu.be/x", true, "high")
	f := g.last(t)
	if !strings.Contains(strings.Join(f.args, " "), "fps=30,scale=854:-2") {
		t.Errorf("high quality reaches ffmpeg: %v", f.args)
	}
	g.mu.Lock()
	h := g.q.Height
	g.mu.Unlock()
	if h != 480 {
		t.Errorf("and yt-dlp: %d", h)
	}
	waitFor(t, "playing", g.r.playing)
	if st := g.r.status(); st.Quality != "high" {
		t.Errorf("status quality: %+v", st)
	}
	g.r.play("https://s/radio", true, "high")
	waitFor(t, "radio", func() bool { return g.count() == 2 })
	if st := g.r.status(); st.Quality != "" || st.Video {
		t.Errorf("a radio has no picture and no quality: %+v", st)
	}
	g.r.stop()
}

func TestRadioStationName(t *testing.T) {
	g := newRadioRig("ffmpeg")
	g.r.play("https://s/x", false, "")
	f := g.last(t)
	go f.logs.Write([]byte("  Metadata:\n    icy-name        : DEF CON Radio [SomaFM]\n    icy-genre       : Electronic\n"))
	waitFor(t, "name", func() bool { return g.r.status().Station == "DEF CON Radio [SomaFM]" })
	g.r.stop()
	if g.r.status().Station != "" {
		t.Error("the name goes with the station")
	}
}

func TestRadioExpand(t *testing.T) {
	items := parseList("First song\thttps://www.youtube.com/watch?v=aaaaaaaaaaa\nbad line\nLocal\tfile:///etc/passwd\n Second \thttps://www.youtube.com/watch?v=bbbbbbbbbbb\n")
	if len(items) != 2 || items[0].Title != "First song" || items[1].Title != "Second" || items[1].URL != "https://www.youtube.com/watch?v=bbbbbbbbbbb" {
		t.Fatalf("parseList: %+v", items)
	}
	long := strings.Repeat("t\thttps://youtu.be/x\n", radioListMax+50)
	if n := len(parseList(long)); n != radioListMax {
		t.Errorf("a playlist is capped at %d, got %d", radioListMax, n)
	}
	g := newRadioRig("ffmpeg")
	if _, err := g.r.expand("https://www.youtube.com/playlist?list=PL1"); err == nil || !strings.Contains(err.Error(), "yt-dlp") {
		t.Errorf("no yt-dlp: %v", err)
	}
	g = newRadioRig("ffmpeg", "yt-dlp")
	if _, err := g.r.expand("https://ice2.somafm.com/x"); err == nil {
		t.Error("only YouTube playlists")
	}
	if _, err := g.r.expand("file:///x"); err == nil {
		t.Error("a file is no playlist")
	}
	if _, err := g.r.expand("https://www.youtube.com/playlist?list=PL1"); err == nil || !strings.Contains(err.Error(), "no videos") {
		t.Errorf("empty playlist: %v", err)
	}
	g.items = items
	got, err := g.r.expand("https://www.youtube.com/playlist?list=PL1")
	if err != nil || len(got) != 2 {
		t.Fatalf("expand: %v %+v", err, got)
	}
	old := music
	defer func() { music = old }()
	music = g.r
	req := httptest.NewRequest("POST", "/api/radio", strings.NewReader(`{"action":"expand","url":"https://www.youtube.com/playlist?list=PL1"}`))
	req.RemoteAddr = "127.0.0.1:9"
	w := httptest.NewRecorder()
	(&Hub{}).handleRadio(w, req)
	var out struct {
		OK    bool        `json:"ok"`
		Items []radioItem `json:"items"`
	}
	json.Unmarshal(w.Body.Bytes(), &out)
	if w.Code != 200 || !out.OK || len(out.Items) != 2 || out.Items[0].Title != "First song" {
		t.Errorf("POST expand: %d %s", w.Code, w.Body.String())
	}
}

func TestHandleRadioStream(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/live":
			if !strings.HasPrefix(r.UserAgent(), "kubiverse-bridge/") {
				w.WriteHeader(http.StatusForbidden) // like SomaFM to a browser on another site
				return
			}
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Write([]byte("ID3 mp3 bytes"))
		case "/page":
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte("<html>"))
		default:
			w.WriteHeader(http.StatusForbidden)
		}
	}))
	defer up.Close()
	h := &Hub{}
	get := func(target, remote string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "/api/radio/stream?url="+url.QueryEscape(target), nil)
		req.RemoteAddr = remote
		w := httptest.NewRecorder()
		h.handleRadioStream(w, req)
		return w
	}
	local := "127.0.0.1:9"
	if w := get(up.URL+"/live", local); w.Code != 200 || w.Body.String() != "ID3 mp3 bytes" || w.Header().Get("Content-Type") != "audio/mpeg" {
		t.Fatalf("the station through the bridge: %d %q %q", w.Code, w.Header().Get("Content-Type"), w.Body.String())
	}
	if w := get(up.URL+"/page", local); w.Code != http.StatusUnsupportedMediaType {
		t.Errorf("never a proxy for web pages: %d", w.Code)
	}
	if w := get(up.URL+"/gone", local); w.Code != http.StatusBadGateway || !strings.Contains(w.Body.String(), "403") {
		t.Errorf("the station's refusal is passed on: %d %s", w.Code, w.Body.String())
	}
	if w := get("file:///etc/passwd", local); w.Code != http.StatusBadRequest {
		t.Errorf("a file: %d", w.Code)
	}
	if w := get("https://youtu.be/abcdefghijk", local); w.Code != http.StatusBadRequest {
		t.Errorf("YouTube has its own player: %d", w.Code)
	}
	if w := get(up.URL+"/live", "192.168.1.30:9"); w.Code != http.StatusForbidden {
		t.Errorf("only for this computer: %d", w.Code)
	}
	if w := get("http://127.0.0.1:1/live", local); w.Code != http.StatusBadGateway {
		t.Errorf("a station that doesn't answer: %d", w.Code)
	}
	for ct, ok := range map[string]bool{"audio/mpeg": true, "audio/aacp; charset=x": true, "application/ogg": true, "text/html": false, "": false, "video/mp4": false} {
		if radioAudio(ct) != ok {
			t.Errorf("radioAudio(%q) != %v", ct, ok)
		}
	}
}
