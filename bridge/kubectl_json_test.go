package main

import (
	"encoding/json"
	"testing"
)

// The in-game terminal's SYNC NOW sends a JSON patch in single quotes: it
// must reach kubectl as valid JSON (double quotes kept).
func TestSplitArgsKeepsQuotedJSON(t *testing.T) {
	args, err := splitArgs(`-n argocd patch application shop --type merge -p '{"operation":{"sync":{}}}'`)
	if err != nil {
		t.Fatal(err)
	}
	last := args[len(args)-1]
	var v map[string]any
	if err := json.Unmarshal([]byte(last), &v); err != nil {
		t.Fatalf("patch %q is not JSON: %v", last, err)
	}
	if _, ok := v["operation"]; !ok {
		t.Errorf("patch lost its keys: %q", last)
	}
	// Unquoted, a shell (and this splitter) eats the double quotes: that was the bug.
	bare, _ := splitArgs(`-p {"operation":{"sync":{}}}`)
	if json.Valid([]byte(bare[len(bare)-1])) {
		t.Errorf("unquoted JSON should not survive splitting: %q", bare[len(bare)-1])
	}
}
