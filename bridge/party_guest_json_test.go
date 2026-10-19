package main

import (
	"net/http"
	"testing"
)

// A guest's refusal is JSON ({ok:false, guest:true, error}) with 403, like
// every other error the game reads, never plain text.
func TestGuestRefusalIsJSON(t *testing.T) {
	_, srv := partyHub(t)
	guest := makeInvite(t, srv, "test")
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/kind"}, {"POST", "/api/kind"}, {"POST", "/api/action"},
		{"GET", "/api/party/invite"}, {"DELETE", "/api/party/invite"},
	} {
		req, _ := http.NewRequest(c.method, srv.URL+c.path, nil)
		req.Header.Set("X-Bridge-Token", guest)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if ct := res.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("guest %s %s: Content-Type %q, want application/json", c.method, c.path, ct)
		}
		code, out := do(t, c.method, srv.URL+c.path, guest, nil)
		if code != http.StatusForbidden || out["ok"] != false || out["guest"] != true {
			t.Errorf("guest %s %s: %d %v, want 403 {ok:false, guest:true}", c.method, c.path, code, out)
		}
		if e, _ := out["error"].(string); e == "" {
			t.Errorf("guest %s %s: no error message: %v", c.method, c.path, out)
		}
	}
}
