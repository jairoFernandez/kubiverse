package main

import (
	"strings"
	"testing"
)

// Kubi must know what the game terminal refuses, or it suggests commands
// that fail there (e.g. kubectl exec with a backtick subcommand).
func TestAssistantPromptKnowsTerminalLimits(t *testing.T) {
	for _, v := range []string{"exec", "edit", "attach", "debug", "port-forward", "proxy", "cp"} {
		if _, ok := blockedVerbs[v]; !ok {
			t.Errorf("%s is not blocked in the terminal any more: update Kubi's prompt", v)
		}
		if !strings.Contains(assistantSystem, v) {
			t.Errorf("Kubi's prompt doesn't say the terminal can't run kubectl %s", v)
		}
	}
	for _, s := range []string{"backticks", "$(...)", "pipes", "ONE plain kubectl command"} {
		if !strings.Contains(assistantSystem, s) {
			t.Errorf("Kubi's prompt doesn't mention %q", s)
		}
	}
	if _, err := splitArgs("exec -it `kubectl get pod -o name` -- sh"); err == nil {
		t.Error("a backtick subcommand must be refused")
	}
}
