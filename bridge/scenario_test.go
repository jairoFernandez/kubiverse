package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestScenarioGuards(t *testing.T) {
	if _, err := scenarios.ReadFile("scenarios/complex.yaml"); err != nil {
		t.Fatalf("complex scenario not embedded: %v", err)
	}
	cases := []struct {
		readOnly bool
		body     string
		code     int
	}{
		{true, `{"name":"complex"}`, http.StatusForbidden},
		{false, `{"name":"../main.go"}`, http.StatusNotFound},
		{false, `{"name":""}`, http.StatusNotFound},
		{false, `not json`, http.StatusBadRequest},
	}
	for _, c := range cases {
		b := &Bridge{readOnly: c.readOnly}
		rec := httptest.NewRecorder()
		b.handleScenario(rec, httptest.NewRequest("POST", "/api/scenario", strings.NewReader(c.body)))
		if rec.Code != c.code {
			t.Errorf("readOnly=%v body=%s: got %d, want %d (%s)", c.readOnly, c.body, rec.Code, c.code, rec.Body.String())
		}
	}
}
