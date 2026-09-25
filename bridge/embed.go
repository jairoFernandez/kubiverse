package main

import (
	"embed"
	"io/fs"
)

// webdist holds the Godot web export when the bridge is built with
// `make bridge-bundle` (it copies build/web here first). Then a single
// binary serves the game at / without --web. A plain `go build` embeds only
// the placeholder, and the bridge serves no web build unless --web is given.
//
//go:embed all:webdist
var webdist embed.FS

// embeddedWeb returns the bundled web build, or nil if this binary has none.
func embeddedWeb() fs.FS {
	sub, err := fs.Sub(webdist, "webdist")
	if err != nil {
		return nil
	}
	if _, err := fs.Stat(sub, "index.html"); err != nil {
		return nil
	}
	return sub
}
