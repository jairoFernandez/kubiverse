package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"path"
	"strings"
	"sync"
	"time"
)

// webHandler serves the Godot web build. The big files (the .wasm is ~40 MB)
// are gzip-compressed once in memory, which makes phones load ~4x faster.
// Clients always revalidate (no-cache) but get 304 when nothing changed.
func webHandler(dir string) http.Handler {
	fs := http.FileServer(http.Dir(dir))
	root := http.Dir(dir)
	var mu sync.Mutex
	cache := map[string]gzEntry{}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		name := path.Clean("/" + r.URL.Path)
		if name == "/" {
			name = "/index.html"
		}
		ext := path.Ext(name)
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") || !compressible[ext] {
			fs.ServeHTTP(w, r)
			return
		}
		f, err := root.Open(name)
		if err != nil {
			fs.ServeHTTP(w, r)
			return
		}
		st, err := f.Stat()
		if err != nil || st.IsDir() {
			f.Close()
			fs.ServeHTTP(w, r)
			return
		}
		mu.Lock()
		e, ok := cache[name]
		mu.Unlock()
		if !ok || !e.mod.Equal(st.ModTime()) || e.size != st.Size() {
			var buf bytes.Buffer
			zw, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
			_, err = io.Copy(zw, f)
			zw.Close()
			if err != nil {
				f.Close()
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			e = gzEntry{data: buf.Bytes(), mod: st.ModTime(), size: st.Size()}
			mu.Lock()
			cache[name] = e
			mu.Unlock()
		}
		f.Close()
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Vary", "Accept-Encoding")
		w.Header().Set("Content-Type", contentTypes[ext])
		http.ServeContent(w, r, name, e.mod, bytes.NewReader(e.data))
	})
}

type gzEntry struct {
	data []byte
	mod  time.Time
	size int64
}

var compressible = map[string]bool{".wasm": true, ".js": true, ".pck": true, ".html": true}

var contentTypes = map[string]string{
	".wasm": "application/wasm", ".js": "text/javascript; charset=utf-8",
	".pck": "application/octet-stream", ".html": "text/html; charset=utf-8",
}
