package main

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

// AI engines for Kubi. Everything runs on this machine:
//   ollama    an Ollama server the user already has (--llm-url, local by default)
//   llamacpp  the official llama.cpp server, downloaded on request from the
//             ggml-org GitHub releases (SHA256 checked) into ~/.kubecraft,
//             running on 127.0.0.1 with a GGUF model from the catalog below
//             (downloaded from Hugging Face, SHA256 pinned here).
// The game can pick the engine and model and start downloads, but it can
// not point the bridge at another server: only the --llm-url flag can.

type aiConfig struct {
	Provider    string  `json:"provider"`     // auto | ollama | llamacpp | off
	OllamaModel string  `json:"ollama_model"` // auto or an installed model
	LlamaModel  string  `json:"llama_model"`  // catalog id
	Length      string  `json:"length"`       // short | normal | long
	Temperature float64 `json:"temperature"`
}

type ggufModel struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Repo   string `json:"repo"`
	File   string `json:"file"`
	Size   int64  `json:"size"`
	SHA256 string `json:"-"`
	Desc   string `json:"desc"`
}

// Small instruct models that run on a laptop CPU/GPU, best first.
var ggufCatalog = []ggufModel{
	{"gemma3-4b", "Gemma 3 4B", "ggml-org/gemma-3-4b-it-GGUF", "gemma-3-4b-it-Q4_K_M.gguf", 2489757856,
		"882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863", "recommended: good answers, 8 GB RAM"},
	{"qwen2.5-3b", "Qwen 2.5 3B", "Qwen/Qwen2.5-3B-Instruct-GGUF", "qwen2.5-3b-instruct-q4_k_m.gguf", 2104932768,
		"626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d", "balanced, multilingual"},
	{"llama3.2-3b", "Llama 3.2 3B", "bartowski/Llama-3.2-3B-Instruct-GGUF", "Llama-3.2-3B-Instruct-Q4_K_M.gguf", 2019377696,
		"6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff", "fast, sometimes invents commands"},
	{"qwen2.5-1.5b", "Qwen 2.5 1.5B", "Qwen/Qwen2.5-1.5B-Instruct-GGUF", "qwen2.5-1.5b-instruct-q4_k_m.gguf", 1117320736,
		"6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e", "tiny and fast, basic answers"},
	{"gemma3-1b", "Gemma 3 1B", "ggml-org/gemma-3-1b-it-GGUF", "gemma-3-1b-it-Q4_K_M.gguf", 806058240,
		"8ccc5cd1f1b3602548715ae25a66ed73fd5dc68a210412eea643eb20eb75a135", "smallest, old machines"},
	{"qwen2.5-7b", "Qwen 2.5 7B", "bartowski/Qwen2.5-7B-Instruct-GGUF", "Qwen2.5-7B-Instruct-Q4_K_M.gguf", 4683074240,
		"65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423", "smarter, 16 GB RAM"},
	{"gemma3-12b", "Gemma 3 12B", "ggml-org/gemma-3-12b-it-GGUF", "gemma-3-12b-it-Q4_K_M.gguf", 7300574976,
		"7bb69bff3f48a7b642355d64a90e481182a7794707b3133890646b1efa778ff5", "best quality, 16+ GB RAM, slow"},
}

// Suggested Ollama models (pulled through the user's Ollama).
var ollamaCatalog = []map[string]string{
	{"name": "gemma3:4b", "size": "3.3 GB", "desc": "recommended"},
	{"name": "qwen2.5:3b", "size": "1.9 GB", "desc": "balanced, multilingual"},
	{"name": "llama3.2:3b", "size": "2.0 GB", "desc": "fast"},
	{"name": "qwen2.5:7b", "size": "4.7 GB", "desc": "smarter, 16 GB RAM"},
}

type download struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"` // llamacpp | gguf | ollama
	Label  string `json:"label"`
	Done   int64  `json:"done"`
	Total  int64  `json:"total"`
	Status string `json:"status"` // running | done | error
	Error  string `json:"error,omitempty"`
}

type aiState struct {
	mu        sync.Mutex
	dir       string // ~/.kubecraft
	cfg       aiConfig
	downloads map[string]*download
	// llama-server process
	llamaCmd   *exec.Cmd
	llamaURL   string
	llamaModel string
	llamaErr   string
	root       context.Context
}

var ai = &aiState{downloads: map[string]*download{}}

func (a *aiState) init(root context.Context, dir string) {
	a.root = root
	a.dir = dir
	a.cfg = aiConfig{Provider: "auto", OllamaModel: llm.Model, Length: "normal", Temperature: 0.2}
	if raw, err := os.ReadFile(filepath.Join(dir, "assistant.json")); err == nil {
		json.Unmarshal(raw, &a.cfg)
	}
	go func() {
		<-root.Done()
		a.stopLlama()
	}()
}

func (a *aiState) save() {
	raw, _ := json.MarshalIndent(a.cfg, "", "  ")
	os.MkdirAll(a.dir, 0o700)
	os.WriteFile(filepath.Join(a.dir, "assistant.json"), raw, 0o600)
}

func (a *aiState) cfgLength() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.cfg.Length
}

func (a *aiState) modelsDir() string { return filepath.Join(a.dir, "models") }
func (a *aiState) llamaDir() string  { return filepath.Join(a.dir, "llama.cpp") }

func catalogEntry(id string) *ggufModel {
	for i := range ggufCatalog {
		if ggufCatalog[i].ID == id {
			return &ggufCatalog[i]
		}
	}
	return nil
}

func (a *aiState) ggufPath(m *ggufModel) string { return filepath.Join(a.modelsDir(), m.File) }

func (a *aiState) ggufInstalled(m *ggufModel) bool {
	st, err := os.Stat(a.ggufPath(m))
	return err == nil && st.Size() == m.Size
}

// llamaBinary: llama-server on PATH, else the newest one we downloaded.
func (a *aiState) llamaBinary() (path, version string) {
	name := "llama-server"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	if p, err := exec.LookPath(name); err == nil {
		return p, "system"
	}
	entries, _ := os.ReadDir(a.llamaDir())
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() > entries[j].Name() })
	for _, e := range entries {
		var found string
		filepath.WalkDir(filepath.Join(a.llamaDir(), e.Name()), func(p string, d os.DirEntry, err error) error {
			if err == nil && !d.IsDir() && d.Name() == name && found == "" {
				found = p
			}
			return nil
		})
		if found != "" {
			return found, e.Name()
		}
	}
	return "", ""
}

// ------------------------------------------------------------------ status

func (h *Hub) handleAIStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, ai.status(r.Context()))
}

func (a *aiState) status(ctx context.Context) map[string]any {
	models, oerr := ollamaModels(ctx)
	a.mu.Lock()
	defer a.mu.Unlock()
	var olist []string
	for _, m := range models {
		if !strings.Contains(m, "embed") {
			olist = append(olist, m)
		}
	}
	bin, ver := a.llamaBinary()
	var gguf []map[string]any
	for i := range ggufCatalog {
		m := &ggufCatalog[i]
		gguf = append(gguf, map[string]any{"id": m.ID, "name": m.Name, "size": m.Size, "desc": m.Desc,
			"installed": a.ggufInstalled(m), "source": "huggingface.co/" + m.Repo})
	}
	dls := []download{}
	for _, d := range a.downloads {
		dls = append(dls, *d) // copies: the JSON is written after unlocking
	}
	sort.Slice(dls, func(i, j int) bool { return dls[i].ID < dls[j].ID })
	engine, model, why := a.resolve(olist, oerr == nil)
	st := map[string]any{
		"llm": engine != "", "engine": engine, "model": model, "why": why, "config": a.cfg,
		"ollama": map[string]any{"up": oerr == nil, "url": llm.URL, "models": olist, "catalog": ollamaCatalog},
		"llamacpp": map[string]any{"installed": bin != "", "version": ver, "running": a.llamaCmd != nil,
			"model": a.llamaModel, "error": a.llamaErr, "platform": llamaAssetSuffix()},
		"gguf": gguf, "downloads": dls,
	}
	return st
}

// resolve picks the engine+model to use now. Caller holds a.mu.
func (a *aiState) resolve(ollamaModels []string, ollamaUp bool) (engine, model, why string) {
	useOllama := func() (string, string, string) {
		if llm.Disabled || llm.URL == "" {
			return "", "", "Ollama disabled on this bridge"
		}
		if !ollamaUp {
			return "", "", "Ollama is not running (ollama serve)"
		}
		m := pickModel(ollamaModels, a.cfg.OllamaModel)
		if m == "" {
			return "", "", "no suitable model in Ollama"
		}
		return "ollama", m, ""
	}
	useLlama := func() (string, string, string) {
		bin, _ := a.llamaBinary()
		if bin == "" {
			return "", "", "llama.cpp is not installed"
		}
		m := catalogEntry(a.cfg.LlamaModel)
		if m == nil || !a.ggufInstalled(m) {
			for i := range ggufCatalog { // any downloaded model will do
				if a.ggufInstalled(&ggufCatalog[i]) {
					return "llamacpp", ggufCatalog[i].ID, ""
				}
			}
			return "", "", "no model downloaded for llama.cpp"
		}
		return "llamacpp", m.ID, ""
	}
	switch a.cfg.Provider {
	case "off":
		return "", "", "AI turned off"
	case "ollama":
		return useOllama()
	case "llamacpp":
		return useLlama()
	}
	if e, m, _ := useOllama(); e != "" {
		return e, m, ""
	}
	if e, m, _ := useLlama(); e != "" {
		return e, m, ""
	}
	return "", "", "no AI engine yet: install Ollama or download llama.cpp + a model in Kubi's settings"
}

// ------------------------------------------------------------------ config

var ollamaName = regexp.MustCompile(`^[a-zA-Z0-9._:/-]{1,80}$`)

func (h *Hub) handleAIConfig(w http.ResponseWriter, r *http.Request) {
	var c aiConfig
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&c); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	switch c.Provider {
	case "auto", "ollama", "llamacpp", "off":
	default:
		c.Provider = "auto"
	}
	if c.OllamaModel == "" {
		c.OllamaModel = "auto"
	}
	if c.OllamaModel != "auto" && (!ollamaName.MatchString(c.OllamaModel) || strings.Contains(c.OllamaModel, "cloud")) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "cloud models are not allowed: cluster data must stay on this machine"})
		return
	}
	if c.LlamaModel != "" && catalogEntry(c.LlamaModel) == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "unknown model"})
		return
	}
	switch c.Length {
	case "short", "normal", "long":
	default:
		c.Length = "normal"
	}
	c.Temperature = min(max(c.Temperature, 0), 1.2)
	ai.mu.Lock()
	changed := c.LlamaModel != ai.cfg.LlamaModel || c.Provider != ai.cfg.Provider
	ai.cfg = c
	ai.save()
	ai.mu.Unlock()
	if changed {
		ai.stopLlama() // restarts with the new model on the next question
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ------------------------------------------------------------------ chat

type chatMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// chat sends messages to the configured engine. Returns the answer and model.
func (a *aiState) chat(ctx context.Context, msgs []chatMsg) (string, string, error) {
	models, oerr := ollamaModels(ctx)
	a.mu.Lock()
	engine, model, why := a.resolve(models, oerr == nil)
	cfg := a.cfg
	a.mu.Unlock()
	maxTokens := map[string]int{"short": 220, "normal": 450, "long": 900}[cfg.Length]
	switch engine {
	case "ollama":
		ans, err := ollamaChat(ctx, model, msgs, cfg.Temperature, maxTokens)
		return ans, model, err
	case "llamacpp":
		url, err := a.ensureLlama(ctx, model)
		if err != nil {
			return "", model, err
		}
		ans, err := openAIChat(ctx, url, msgs, cfg.Temperature, maxTokens)
		return ans, model, err
	}
	return "", "", errors.New(why)
}

var thinkRe = regexp.MustCompile(`(?s)<think>.*?</think>`)

func ollamaModels(ctx context.Context) ([]string, error) {
	if llm.Disabled || llm.URL == "" {
		return nil, errors.New("disabled")
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(llm.URL, "/")+"/api/tags", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var tags struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&tags); err != nil {
		return nil, err
	}
	var out []string
	for _, m := range tags.Models {
		out = append(out, m.Name)
	}
	return out, nil
}

func ollamaChat(ctx context.Context, model string, msgs []chatMsg, temp float64, maxTokens int) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"model": model, "stream": false, "think": false, "messages": msgs,
		"options": map[string]any{"temperature": temp, "num_ctx": 8192, "num_predict": maxTokens},
	})
	raw, err := postJSON(ctx, strings.TrimSuffix(llm.URL, "/")+"/api/chat", body)
	if err != nil {
		return "", fmt.Errorf("Ollama: %v", err)
	}
	var out struct {
		Message chatMsg `json:"message"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", fmt.Errorf("Ollama: bad response: %v", err)
	}
	return strings.TrimSpace(thinkRe.ReplaceAllString(out.Message.Content, "")), nil
}

func openAIChat(ctx context.Context, base string, msgs []chatMsg, temp float64, maxTokens int) (string, error) {
	body, _ := json.Marshal(map[string]any{"messages": msgs, "temperature": temp, "max_tokens": maxTokens, "stream": false})
	raw, err := postJSON(ctx, base+"/v1/chat/completions", body)
	if err != nil {
		return "", fmt.Errorf("llama.cpp: %v", err)
	}
	var out struct {
		Choices []struct {
			Message chatMsg `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Choices) == 0 {
		return "", fmt.Errorf("llama.cpp: bad response: %s", clip(string(raw), 200))
	}
	return strings.TrimSpace(thinkRe.ReplaceAllString(out.Choices[0].Message.Content, "")), nil
}

func postJSON(ctx context.Context, url string, body []byte) ([]byte, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d: %s", res.StatusCode, clip(string(raw), 300))
	}
	return raw, nil
}

// ------------------------------------------------------------------ llama-server

// ensureLlama starts llama-server with the model (or reuses it) and returns its URL.
func (a *aiState) ensureLlama(ctx context.Context, id string) (string, error) {
	a.mu.Lock()
	if a.llamaCmd != nil && a.llamaModel == id {
		url := a.llamaURL
		a.mu.Unlock()
		return url, a.waitLlama(ctx, url)
	}
	a.mu.Unlock()
	a.stopLlama()
	m := catalogEntry(id)
	bin, _ := a.llamaBinary()
	if m == nil || bin == "" {
		return "", errors.New("llama.cpp or the model is missing")
	}
	port, err := freePort()
	if err != nil {
		return "", err
	}
	url := fmt.Sprintf("http://127.0.0.1:%d", port)
	cmd := exec.CommandContext(a.root, bin, "-m", a.ggufPath(m), "--host", "127.0.0.1", "--port", fmt.Sprint(port),
		"-c", "8192", "-ngl", "999")
	cmd.Dir = filepath.Dir(bin)
	logf, _ := os.OpenFile(filepath.Join(a.dir, "llama-server.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("cannot start llama-server: %v", err)
	}
	log.Printf("assistant: llama-server %s on %s (model %s)", bin, url, m.File)
	a.mu.Lock()
	a.llamaCmd, a.llamaURL, a.llamaModel, a.llamaErr = cmd, url, id, ""
	a.mu.Unlock()
	go func() {
		err := cmd.Wait()
		if logf != nil {
			logf.Close()
		}
		a.mu.Lock()
		if a.llamaCmd == cmd {
			a.llamaCmd = nil
			if err != nil {
				a.llamaErr = "llama-server stopped: " + err.Error() + " (see ~/.kubecraft/llama-server.log)"
			}
		}
		a.mu.Unlock()
	}()
	return url, a.waitLlama(ctx, url)
}

// waitLlama waits until the model is loaded (/health = 200).
func (a *aiState) waitLlama(ctx context.Context, url string) error {
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url+"/health", nil)
		if res, err := http.DefaultClient.Do(req); err == nil {
			res.Body.Close()
			if res.StatusCode == http.StatusOK {
				return nil
			}
		}
		a.mu.Lock()
		dead := a.llamaCmd == nil
		msg := a.llamaErr
		a.mu.Unlock()
		if dead {
			return errors.New(msg)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return errors.New("llama-server is taking too long to load the model")
}

func (a *aiState) stopLlama() {
	a.mu.Lock()
	cmd := a.llamaCmd
	a.llamaCmd = nil
	a.llamaModel = ""
	a.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		cmd.Process.Kill()
	}
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// ------------------------------------------------------------------ downloads

type downloadRequest struct {
	Kind string `json:"kind"` // llamacpp | gguf | ollama
	ID   string `json:"id"`
}

func (h *Hub) handleAIDownload(w http.ResponseWriter, r *http.Request) {
	var req downloadRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	var job func(d *download) error
	d := &download{Kind: req.Kind, Status: "running"}
	switch req.Kind {
	case "llamacpp":
		d.ID, d.Label = "llamacpp", "llama.cpp"
		job = ai.installLlama
	case "gguf":
		m := catalogEntry(req.ID)
		if m == nil {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "unknown model"})
			return
		}
		d.ID, d.Label, d.Total = "gguf:"+m.ID, m.Name, m.Size
		job = func(d *download) error { return ai.downloadGGUF(d, m) }
	case "ollama":
		if !ollamaName.MatchString(req.ID) || strings.Contains(req.ID, "cloud") {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "invalid model name"})
			return
		}
		d.ID, d.Label = "ollama:"+req.ID, req.ID
		job = func(d *download) error { return ollamaPull(ai.root, d, req.ID) }
	default:
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "unknown kind"})
		return
	}
	ai.mu.Lock()
	if old := ai.downloads[d.ID]; old != nil && old.Status == "running" {
		ai.mu.Unlock()
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "already downloading"})
		return
	}
	ai.downloads[d.ID] = d
	ai.mu.Unlock()
	go func() {
		err := job(d)
		ai.mu.Lock()
		if err != nil {
			d.Status, d.Error = "error", err.Error()
			log.Printf("assistant: download %s failed: %v", d.ID, err)
		} else {
			d.Status = "done"
			d.Done = d.Total
			log.Printf("assistant: download %s done", d.ID)
		}
		ai.mu.Unlock()
	}()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *Hub) handleAIDeleteModel(w http.ResponseWriter, r *http.Request) {
	m := catalogEntry(r.URL.Query().Get("id"))
	if m == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "unknown model"})
		return
	}
	ai.mu.Lock()
	using := ai.llamaModel == m.ID
	ai.mu.Unlock()
	if using {
		ai.stopLlama()
	}
	err := os.Remove(ai.ggufPath(m))
	if err != nil && !os.IsNotExist(err) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// progressWriter counts bytes into a download (under ai.mu).
type progressWriter struct{ d *download }

func (p progressWriter) Write(b []byte) (int, error) {
	ai.mu.Lock()
	p.d.Done += int64(len(b))
	ai.mu.Unlock()
	return len(b), nil
}

var hfBase = "https://huggingface.co"

// downloadGGUF fetches a catalog model and checks its pinned SHA256.
func (a *aiState) downloadGGUF(d *download, m *ggufModel) error {
	if err := os.MkdirAll(a.modelsDir(), 0o700); err != nil {
		return err
	}
	final := a.ggufPath(m)
	tmp := final + ".part"
	url := fmt.Sprintf("%s/%s/resolve/main/%s", hfBase, m.Repo, m.File)
	if err := fetchVerified(a.root, url, tmp, m.SHA256, m.Size, d); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, final)
}

// fetchVerified downloads url to path, checking size and SHA256 on the fly.
func fetchVerified(ctx context.Context, url, path, sum string, size int64, d *download) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	req.Header.Set("User-Agent", "kubecraft-bridge")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d from %s", res.StatusCode, url)
	}
	if size > 0 && res.ContentLength > 0 && res.ContentLength != size {
		return fmt.Errorf("unexpected size %d (want %d)", res.ContentLength, size)
	}
	ai.mu.Lock()
	if d.Total == 0 {
		d.Total = res.ContentLength
	}
	ai.mu.Unlock()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	h := sha256.New()
	limit := size
	if limit <= 0 {
		limit = 1 << 34
	}
	n, err := io.Copy(io.MultiWriter(f, h, progressWriter{d}), io.LimitReader(res.Body, limit+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if size > 0 && n != size {
		return fmt.Errorf("incomplete download: %d of %d bytes", n, size)
	}
	if got := hex.EncodeToString(h.Sum(nil)); !strings.EqualFold(got, sum) {
		return fmt.Errorf("SHA256 mismatch: got %s, want %s (file discarded)", got, sum)
	}
	return nil
}

var githubAPI = "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15"

var llamaReleasePrefix = "https://github.com/ggml-org/llama.cpp/releases/download/"

func llamaAssetSuffix() string {
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "darwin/arm64":
		return "bin-macos-arm64.tar.gz"
	case "darwin/amd64":
		return "bin-macos-x64.tar.gz"
	case "linux/amd64":
		return "bin-ubuntu-x64.tar.gz"
	case "linux/arm64":
		return "bin-ubuntu-arm64.tar.gz"
	case "windows/amd64":
		return "bin-win-cpu-x64.zip"
	case "windows/arm64":
		return "bin-win-cpu-arm64.zip"
	}
	return ""
}

// installLlama downloads the newest official llama.cpp build for this
// platform from GitHub, checks the SHA256 GitHub publishes for it and unpacks it.
func (a *aiState) installLlama(d *download) error {
	suffix := llamaAssetSuffix()
	if suffix == "" {
		return fmt.Errorf("no official llama.cpp build for %s/%s: install it yourself", runtime.GOOS, runtime.GOARCH)
	}
	req, _ := http.NewRequestWithContext(a.root, http.MethodGet, githubAPI, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	var rels []struct {
		Tag    string `json:"tag_name"`
		Assets []struct {
			Name   string `json:"name"`
			URL    string `json:"browser_download_url"`
			Size   int64  `json:"size"`
			Digest string `json:"digest"`
		} `json:"assets"`
	}
	err = json.NewDecoder(io.LimitReader(res.Body, 8<<20)).Decode(&rels)
	res.Body.Close()
	if err != nil {
		return fmt.Errorf("GitHub API: %v", err)
	}
	for _, rel := range rels {
		if !regexp.MustCompile(`^b\d+$`).MatchString(rel.Tag) {
			continue
		}
		for _, as := range rel.Assets {
			if as.Name != "llama-"+rel.Tag+"-"+suffix {
				continue
			}
			if !strings.HasPrefix(as.URL, llamaReleasePrefix) || !strings.HasPrefix(as.Digest, "sha256:") {
				return errors.New("unexpected release asset (no official URL or digest)")
			}
			ai.mu.Lock()
			d.Label = "llama.cpp " + rel.Tag
			d.Total = as.Size
			ai.mu.Unlock()
			tmp := filepath.Join(a.dir, as.Name+".part")
			os.MkdirAll(a.dir, 0o700)
			if err := fetchVerified(a.root, as.URL, tmp, strings.TrimPrefix(as.Digest, "sha256:"), as.Size, d); err != nil {
				os.Remove(tmp)
				return err
			}
			defer os.Remove(tmp)
			dest := filepath.Join(a.llamaDir(), rel.Tag)
			os.RemoveAll(dest)
			if strings.HasSuffix(as.Name, ".zip") {
				err = unzipSafe(tmp, dest)
			} else {
				err = untarSafe(tmp, dest)
			}
			if err != nil {
				os.RemoveAll(dest)
				return fmt.Errorf("unpack: %v", err)
			}
			if bin, _ := a.llamaBinary(); bin == "" {
				return errors.New("llama-server not found in the release archive")
			}
			return nil
		}
	}
	return fmt.Errorf("no llama.cpp release with %s found", suffix)
}

// inside reports whether target stays within dir (no "../" escapes).
func inside(dir, target string) bool {
	rel, err := filepath.Rel(dir, target)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

func untarSafe(archive, dest string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		target := filepath.Join(dest, filepath.FromSlash(hd.Name))
		if !inside(dest, target) {
			return fmt.Errorf("unsafe path %q", hd.Name)
		}
		switch hd.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := writeFile(target, tr, os.FileMode(hd.Mode)&0o755|0o600); err != nil {
				return err
			}
		case tar.TypeSymlink:
			// Shared libraries are often symlinked (libfoo.dylib -> libfoo.1.dylib).
			if filepath.IsAbs(hd.Linkname) || !inside(dest, filepath.Join(filepath.Dir(target), hd.Linkname)) {
				return fmt.Errorf("unsafe link %q -> %q", hd.Name, hd.Linkname)
			}
			os.MkdirAll(filepath.Dir(target), 0o755)
			if err := os.Symlink(hd.Linkname, target); err != nil {
				return err
			}
		}
	}
}

func unzipSafe(archive, dest string) error {
	zr, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer zr.Close()
	for _, zf := range zr.File {
		target := filepath.Join(dest, filepath.FromSlash(zf.Name))
		if !inside(dest, target) {
			return fmt.Errorf("unsafe path %q", zf.Name)
		}
		if zf.FileInfo().IsDir() {
			os.MkdirAll(target, 0o755)
			continue
		}
		if zf.Mode()&os.ModeSymlink != 0 {
			continue
		}
		rc, err := zf.Open()
		if err != nil {
			return err
		}
		err = writeFile(target, rc, 0o755)
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func writeFile(path string, r io.Reader, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, io.LimitReader(r, 1<<30))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// ollamaPull asks the user's Ollama to download a model, tracking progress.
func ollamaPull(ctx context.Context, d *download, name string) error {
	body, _ := json.Marshal(map[string]any{"model": name, "stream": true})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(llm.URL, "/")+"/api/pull", bytes.NewReader(body))
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("Ollama not reachable: %v", err)
	}
	defer res.Body.Close()
	sc := bufio.NewScanner(res.Body)
	for sc.Scan() {
		var ev struct {
			Status    string `json:"status"`
			Total     int64  `json:"total"`
			Completed int64  `json:"completed"`
			Error     string `json:"error"`
		}
		if json.Unmarshal(sc.Bytes(), &ev) != nil {
			continue
		}
		if ev.Error != "" {
			return errors.New(ev.Error)
		}
		ai.mu.Lock()
		if ev.Total > 0 {
			d.Total, d.Done = ev.Total, ev.Completed
		}
		ai.mu.Unlock()
		if ev.Status == "success" {
			return nil
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return errors.New("pull ended without success")
}
