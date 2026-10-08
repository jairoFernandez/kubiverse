package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// The retro radio: online stations and YouTube are decoded by one headless
// ffmpeg the bridge starts (yt-dlp finds YouTube's stream addresses first),
// and the game gets them over a WebSocket: raw PCM it mixes itself (its
// volume sliders and mute just work) and small JPEG frames it paints in a
// mini player inside its own window. No player window of its own: on macOS
// any extra window that draws video costs ~300 MB of graphics memory, while
// this costs ~7 MB for a radio and ~50 MB for 240p video.
// It only answers requests from this machine: the sound is for the person
// sitting at the computer running the bridge.

// What the game receives on /api/radio/ws, one binary message each:
// 'A' + 32-bit float little-endian stereo PCM at radioRate Hz (50 ms), or
// 'V' + one JPEG frame (size and rate from the radioQuality asked for).
const (
	radioRate  = 44100
	radioChunk = radioRate / 20 * 2 * 4 // 50 ms of stereo float32
)

// radioQuality: how YouTube video is fetched and sent to the game. Measured
// on the Lofi Girl live stream (ffmpeg memory, CPU of one core, loopback):
// low ~56 MB 2% 140 KB/s, medium ~78 MB 5% 670 KB/s, high ~107 MB 10% 1.4 MB/s.
type radioQuality struct {
	Height, FPS, Width, JPEG int // JPEG: ffmpeg -q:v, 2 (best) to 31
}

var radioQualities = map[string]radioQuality{
	"low":    {Height: 240, FPS: 15, Width: 426, JPEG: 7},
	"medium": {Height: 360, FPS: 24, Width: 640, JPEG: 5},
	"high":   {Height: 480, FPS: 30, Width: 854, JPEG: 4},
}

func qualityOf(name string) (string, radioQuality) {
	if q, ok := radioQualities[name]; ok {
		return name, q
	}
	return "medium", radioQualities["medium"]
}

// radioProc is a started ffmpeg (an *exec.Cmd's process in production).
type radioProc interface {
	Kill() error
	Wait() error
}

// What ffmpeg writes: PCM, JPEG frames (nil without video) and its log.
type radioPipes struct {
	audio, video, logs io.ReadCloser
}

type execProc struct{ cmd *exec.Cmd }

func (p execProc) Kill() error { return p.cmd.Process.Kill() }
func (p execProc) Wait() error { return p.cmd.Wait() }

// radioListener: the game's WebSocket. Only the newest one gets the sound.
type radioListener struct {
	ch   chan []byte
	done chan struct{}
}

type radio struct {
	mu       sync.Mutex
	lookPath func(string) (string, error)
	start    func(name string, args []string, video bool) (radioProc, radioPipes, error)
	resolve  func(ytdl, u string, video bool, q radioQuality) (title string, urls []string, err error)
	list     func(ytdl, u string) ([]radioItem, error)

	gen     int // bumped on every start/stop: stale goroutines see it and give up
	proc    radioProc
	url     string // station being played ("" = off)
	video   bool
	quality string
	title   string // what is on: the stream's "now playing" or the video's title
	station string // the stream's own name (icy-name)
	err     string // why the last station stopped by itself
	lis     *radioListener

	// The game listens on the WebSocket or asks for the status; when neither
	// happens for `idle` (quit, crash, a bridge it didn't start) the radio
	// goes quiet instead of decoding for nobody.
	seen time.Time
	idle time.Duration
	tick time.Duration
}

func newRadio() *radio {
	return &radio{
		lookPath: exec.LookPath,
		start:    startFFmpeg,
		resolve:  resolveYouTube,
		list:     listYouTube,
		idle:     20 * time.Second,
		tick:     5 * time.Second,
	}
}

var music = newRadio()

// Where tools are installed besides PATH: apps opened from the Dock get a
// bare PATH.
var radioDirs = []string{"/opt/homebrew/bin", "/usr/local/bin", "/snap/bin"}

func (r *radio) find(name string) string {
	if p, err := r.lookPath(name); err == nil {
		return p
	}
	for _, d := range radioDirs {
		if p, err := r.lookPath(filepath.Join(d, name)); err == nil {
			return p
		}
	}
	return ""
}

// radioURL accepts only web addresses: ffmpeg also opens local files,
// devices and odd protocols, and none of that should be reachable from a
// request.
func radioURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || len(raw) > 4096 {
		return "", errors.New("not a web address (http:// or https://)")
	}
	if strings.ContainsAny(raw, "\x00\r\n ") {
		return "", errors.New("bad characters in the address")
	}
	return raw, nil
}

// isYouTube: links that need yt-dlp to find the stream.
func isYouTube(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	h := strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	h = strings.TrimPrefix(h, "m.")
	return h == "youtube.com" || h == "youtu.be" || h == "music.youtube.com" || h == "youtube-nocookie.com"
}

// ytFormat: the lightest streams that still look and sound fine.
func ytFormat(video bool, q radioQuality) string {
	if video {
		return fmt.Sprintf("bestvideo[height<=?%d][fps<=?%d]+bestaudio/best[height<=?%d]/best", q.Height, max(q.FPS, 30), q.Height)
	}
	return "bestaudio/best"
}

// resolveYouTube asks yt-dlp for the title and the stream address(es):
// one (audio, or audio+video together) or two (video, then audio).
func resolveYouTube(ytdl, u string, video bool, q radioQuality) (string, []string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, ytdl, "--no-warnings", "-q", "--no-playlist",
		"--print", "title", "-g", "-f", ytFormat(video, q), "--", u).Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			return "", nil, errors.New(lastLine(string(ee.Stderr)))
		}
		return "", nil, err
	}
	return parseResolved(string(out))
}

func parseResolved(out string) (string, []string, error) {
	var title string
	var urls []string
	for i, l := range strings.Split(strings.TrimSpace(out), "\n") {
		l = strings.TrimSpace(l)
		if i == 0 {
			title = l
		} else if u, err := radioURL(l); err == nil {
			urls = append(urls, u)
		}
	}
	if len(urls) == 0 || len(urls) > 2 {
		return "", nil, errors.New("YouTube gave no playable stream")
	}
	return title, urls, nil
}

// radioItem: one entry of a YouTube playlist.
type radioItem struct {
	Title string `json:"title"`
	URL   string `json:"url"`
}

const radioListMax = 200

// listYouTube: the videos of a playlist link (titles and links only, nothing
// is downloaded).
func listYouTube(ytdl, u string) ([]radioItem, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, ytdl, "--no-warnings", "-q", "--flat-playlist", "--yes-playlist",
		"--playlist-end", fmt.Sprint(radioListMax), "--print", "%(title)s\t%(url)s", "--", u).Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			return nil, errors.New(lastLine(string(ee.Stderr)))
		}
		return nil, err
	}
	return parseList(string(out)), nil
}

func parseList(out string) []radioItem {
	var items []radioItem
	for _, l := range strings.Split(out, "\n") {
		title, link, ok := strings.Cut(strings.TrimSpace(l), "\t")
		u, err := radioURL(link)
		if !ok || err != nil || len(items) >= radioListMax {
			continue
		}
		items = append(items, radioItem{Title: strings.TrimSpace(title), URL: u})
	}
	return items
}

// expand: a YouTube playlist link becomes its videos.
func (r *radio) expand(raw string) ([]radioItem, error) {
	u, err := radioURL(raw)
	if err != nil {
		return nil, err
	}
	if !isYouTube(u) {
		return nil, errors.New("only YouTube playlists can be opened")
	}
	ytdl := r.find("yt-dlp")
	if ytdl == "" {
		return nil, errors.New("YouTube needs yt-dlp installed")
	}
	items, err := r.list(ytdl, u)
	if err == nil && len(items) == 0 {
		err = errors.New("that playlist has no videos")
	}
	return items, err
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// ffmpegArgs: decode the inputs, PCM to stdout and (video) 10 fps JPEGs of
// 384 px to videoOut. Two inputs = YouTube's separate video and audio.
// Everything is read at its own pace (-re): YouTube hands out whole
// segments and a radio sends a burst of several seconds on connect, which
// the game's small buffer would have to throw away.
func ffmpegArgs(inputs []string, video, youtube bool, q radioQuality, videoOut string) []string {
	a := []string{"-nostdin", "-hide_banner", "-nostats"}
	if youtube {
		a = append(a, "-loglevel", "warning")
	} else {
		a = append(a, "-loglevel", "verbose") // logs the "now playing" changes
	}
	for _, in := range inputs {
		a = append(a, "-re", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5", "-i", in)
	}
	aIn := "0:a:0"
	if len(inputs) == 2 {
		aIn = "1:a:0"
	}
	a = append(a, "-map", aIn, "-vn", "-ac", "2", "-ar", fmt.Sprint(radioRate), "-f", "f32le", "pipe:1")
	if video && videoOut != "" {
		a = append(a, "-map", "0:v:0", "-an", "-vf", fmt.Sprintf("fps=%d,scale=%d:-2:flags=fast_bilinear", q.FPS, q.Width),
			"-c:v", "mjpeg", "-q:v", fmt.Sprint(q.JPEG), "-f", "image2pipe", videoOut)
	}
	return a
}

// lazyConn: ffmpeg sends the video frames to a loopback port the bridge
// listens on (a pipe beyond stdout doesn't exist on Windows).
type lazyConn struct {
	ln net.Listener
	c  net.Conn
}

func (l *lazyConn) Read(p []byte) (int, error) {
	if l.c == nil {
		if t, ok := l.ln.(*net.TCPListener); ok {
			t.SetDeadline(time.Now().Add(60 * time.Second))
		}
		c, err := l.ln.Accept()
		l.ln.Close()
		if err != nil {
			return 0, err
		}
		l.c = c
	}
	return l.c.Read(p)
}

func (l *lazyConn) Close() error {
	l.ln.Close()
	if l.c != nil {
		return l.c.Close()
	}
	return nil
}

func startFFmpeg(name string, args []string, video bool) (radioProc, radioPipes, error) {
	var vid *lazyConn
	if video {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return nil, radioPipes{}, err
		}
		vid = &lazyConn{ln: ln}
		args = append(args[:len(args)-1], "tcp://"+ln.Addr().String())
	}
	cmd := exec.Command(name, args...)
	audio, err := cmd.StdoutPipe()
	if err != nil {
		return nil, radioPipes{}, err
	}
	logs, err := cmd.StderrPipe()
	if err != nil {
		return nil, radioPipes{}, err
	}
	if err := cmd.Start(); err != nil {
		if vid != nil {
			vid.Close()
		}
		return nil, radioPipes{}, err
	}
	p := radioPipes{audio: audio, logs: logs}
	if vid != nil {
		p.video = vid
	}
	return execProc{cmd}, p, nil
}

func (r *radio) play(raw string, video bool, quality string) error {
	u, err := radioURL(raw)
	if err != nil {
		return err
	}
	ff := r.find("ffmpeg")
	if ff == "" {
		return errors.New("ffmpeg is not installed")
	}
	yt := isYouTube(u)
	ytdl := r.find("yt-dlp")
	if yt && ytdl == "" {
		return errors.New("YouTube needs yt-dlp installed")
	}
	video = video && yt
	quality, q := qualityOf(quality)
	r.mu.Lock()
	r.killLocked()
	gen := r.gen
	r.url, r.video, r.quality, r.title, r.err, r.seen = u, video, quality, "", "", time.Now()
	r.mu.Unlock()
	go r.run(gen, ff, ytdl, u, yt, video, q)
	go r.watch(gen)
	log.Printf("radio: tuning in %s (video=%v)", u, video)
	return nil
}

// failed: the station gen couldn't play; says why unless it was replaced.
func (r *radio) failed(gen int, why string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.gen == gen {
		r.proc, r.url, r.err = nil, "", why
	}
}

func (r *radio) run(gen int, ff, ytdl, u string, yt, video bool, q radioQuality) {
	inputs, title := []string{u}, ""
	if yt {
		var err error
		if title, inputs, err = r.resolve(ytdl, u, video, q); err != nil {
			r.failed(gen, "YouTube: "+err.Error())
			return
		}
	}
	p, pipes, err := r.start(ff, ffmpegArgs(inputs, video, yt, q, "pipe:3"), video)
	if err != nil {
		r.failed(gen, "cannot start ffmpeg: "+err.Error())
		return
	}
	r.mu.Lock()
	if r.gen != gen {
		r.mu.Unlock()
		p.Kill()
		p.Wait()
		return
	}
	r.proc = p
	if title != "" {
		r.title = title
	}
	r.mu.Unlock()
	last := make(chan string, 1)
	go r.readLog(gen, pipes.logs, last)
	if pipes.video != nil {
		go r.pumpVideo(gen, pipes.video)
	}
	r.pumpAudio(gen, pipes.audio)
	werr := p.Wait()
	why := "the station stopped"
	if l := <-last; l != "" {
		why += ": " + l
	} else if werr != nil {
		why += ": " + werr.Error()
	}
	r.failed(gen, why)
}

func (r *radio) emit(gen int, msg []byte) {
	r.mu.Lock()
	l := r.lis
	ok := r.gen == gen
	r.mu.Unlock()
	if !ok || l == nil {
		return
	}
	select {
	case l.ch <- msg:
	default: // the game is behind: drop rather than pile up
	}
}

func (r *radio) pumpAudio(gen int, rd io.ReadCloser) {
	defer rd.Close()
	for {
		buf := make([]byte, 1+radioChunk)
		buf[0] = 'A'
		n, err := io.ReadFull(rd, buf[1:])
		if n >= 8 {
			r.emit(gen, buf[:1+n-n%8])
		}
		if err != nil {
			return
		}
	}
}

var jpegEnd = []byte{0xFF, 0xD9}

// pumpVideo splits ffmpeg's stream of JPEGs at their end markers (ffmpeg's
// frames carry no thumbnails, so the marker can't appear inside one).
func (r *radio) pumpVideo(gen int, rd io.ReadCloser) {
	defer rd.Close()
	var frame []byte
	chunk := make([]byte, 32<<10)
	for {
		n, err := rd.Read(chunk)
		frame = append(frame, chunk[:n]...)
		for {
			i := bytes.Index(frame, jpegEnd)
			if i < 0 {
				break
			}
			r.emit(gen, append([]byte{'V'}, frame[:i+2]...))
			frame = append(frame[:0], frame[i+2:]...)
		}
		if len(frame) > 2<<20 {
			frame = frame[:0] // not JPEG: never grow without bound
		}
		if err != nil {
			return
		}
	}
}

var (
	streamTitle = regexp.MustCompile(`StreamTitle\s*:\s*(.*\S)`)
	streamName  = regexp.MustCompile(`^icy-name\s*:\s*(.*\S)`)
)

// readLog: "now playing" updates, and the last error line (why it stopped).
func (r *radio) readLog(gen int, rd io.ReadCloser, last chan<- string) {
	defer rd.Close()
	sc := bufio.NewScanner(rd)
	sc.Buffer(make([]byte, 64<<10), 64<<10)
	var l string
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if m := streamTitle.FindStringSubmatch(line); m != nil {
			r.mu.Lock()
			if r.gen == gen {
				r.title = m[1]
			}
			r.mu.Unlock()
			continue
		}
		if m := streamName.FindStringSubmatch(line); m != nil {
			r.mu.Lock()
			if r.gen == gen {
				r.station = m[1]
			}
			r.mu.Unlock()
			continue
		}
		if low := strings.ToLower(line); strings.Contains(low, "error") || strings.Contains(low, "failed") {
			l = line
		}
	}
	last <- l
}

// touch: the game is still there.
func (r *radio) touch() {
	r.mu.Lock()
	r.seen = time.Now()
	r.mu.Unlock()
}

func (r *radio) watch(gen int) {
	t := time.NewTicker(r.tick)
	defer t.Stop()
	for range t.C {
		r.mu.Lock()
		if r.gen != gen {
			r.mu.Unlock()
			return
		}
		if r.lis == nil && time.Since(r.seen) > r.idle {
			r.killLocked()
			r.err = "the game stopped listening"
			r.mu.Unlock()
			log.Printf("radio: no word from the game for %s: stopped", r.idle)
			return
		}
		r.mu.Unlock()
	}
}

func (r *radio) killLocked() {
	r.gen++
	if r.proc != nil {
		r.proc.Kill()
	}
	r.proc, r.url, r.title, r.station = nil, "", "", ""
}

func (r *radio) stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.killLocked()
	r.err = ""
}

func (r *radio) playing() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.proc != nil
}

// listen makes a new listener the only one (an older one is told to go).
func (r *radio) listen() *radioListener {
	l := &radioListener{ch: make(chan []byte, 64), done: make(chan struct{})}
	r.mu.Lock()
	if r.lis != nil {
		close(r.lis.done)
	}
	r.lis = l
	r.mu.Unlock()
	return l
}

func (r *radio) unlisten(l *radioListener) {
	r.mu.Lock()
	if r.lis == l {
		r.lis = nil
		r.seen = time.Now()
	}
	r.mu.Unlock()
}

type radioStatus struct {
	Available bool   `json:"available"` // ffmpeg found
	YouTube   bool   `json:"youtube"`   // yt-dlp found
	Playing   bool   `json:"playing"`   // ffmpeg is decoding
	Tuning    bool   `json:"tuning"`    // a station is starting (yt-dlp, connecting)
	URL       string `json:"url"`
	Video     bool   `json:"video"`
	Title     string `json:"title"`
	Station   string `json:"station,omitempty"` // the stream's own name
	Quality   string `json:"quality,omitempty"`
	Error     string `json:"error,omitempty"`
}

func (r *radio) status() radioStatus {
	r.mu.Lock()
	st := radioStatus{Playing: r.proc != nil, Tuning: r.proc == nil && r.url != "", URL: r.url, Video: r.video, Title: r.title, Station: r.station, Error: r.err}
	if r.video {
		st.Quality = r.quality
	}
	r.mu.Unlock()
	st.Available = r.find("ffmpeg") != ""
	st.YouTube = r.find("yt-dlp") != ""
	return st
}

func (h *Hub) radioAllowed(w http.ResponseWriter, r *http.Request) bool {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if h.inCluster || h.userHeader != "" || !isLoopback(ip) {
		writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": "the radio plays only on a bridge running on this computer"})
		return false
	}
	music.touch()
	return true
}

// GET /api/radio: status. POST /api/radio {"action": "play"|"stop"|"expand",
// "url", "video", "quality" (low|medium|high)}; expand answers {"items": [{title, url}]}.
func (h *Hub) handleRadio(w http.ResponseWriter, r *http.Request) {
	if !h.radioAllowed(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, music.status())
		return
	case http.MethodPost:
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Action  string `json:"action"`
		URL     string `json:"url"`
		Video   bool   `json:"video"`
		Quality string `json:"quality"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad JSON"})
		return
	}
	var err error
	switch req.Action {
	case "play":
		err = music.play(req.URL, req.Video, req.Quality)
	case "expand":
		var items []radioItem
		if items, err = music.expand(req.URL); err == nil {
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "items": items})
			return
		}
	case "stop":
		music.stop()
	default:
		err = fmt.Errorf("unknown action %q", req.Action)
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// GET /api/radio/ws: the sound and the frames (see radioRate).
func (h *Hub) handleRadioWS(w http.ResponseWriter, r *http.Request) {
	if !h.radioAllowed(w, r) {
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true}) // origin checked in guard
	if err != nil {
		return
	}
	defer conn.CloseNow()
	l := music.listen()
	defer music.unlisten(l)
	ctx := conn.CloseRead(r.Context())
	for {
		select {
		case <-ctx.Done():
			return
		case <-l.done:
			conn.Close(websocket.StatusNormalClosure, "another listener")
			return
		case msg := <-l.ch:
			wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := conn.Write(wctx, websocket.MessageBinary, msg)
			cancel()
			if err != nil {
				return
			}
		}
	}
}
