package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHandleVersion(t *testing.T) {
	old := version
	version = "1.2.3"
	defer func() { version = old }()
	rec := httptest.NewRecorder()
	handleVersion(rec, httptest.NewRequest(http.MethodGet, "/api/version", nil))
	var got map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || got["version"] != "1.2.3" {
		t.Fatalf("version = %v (%v)", got, err)
	}
}
