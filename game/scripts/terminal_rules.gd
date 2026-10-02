class_name TerminalRules
extends RefCounted
## What the bridge's terminal refuses (bridge/kubectl.go): shell syntax,
## interactive or long-running verbs and flags. Those commands only get COPY.
const TERMINAL_BLOCKED_VERBS := ["exec", "edit", "attach", "debug", "port-forward", "proxy", "cp", "config", "plugin"]
const TERMINAL_BLOCKED_FLAGS := ["-i", "-t", "-it", "-ti", "--stdin", "--tty", "-w", "--watch", "--watch-only",
	"-f", "--follow", "--filename", "-k", "--kustomize", "-R", "--recursive"]


## True if the in-game terminal can run this kubectl line (<placeholders> are fine).
static func can_run(cmd: String) -> bool:
	for ch in ["|", ";", "&", "`", "$"]:
		if cmd.contains(ch):
			return false
	var verb := ""
	var skip := false  # the value of -n/--namespace comes before the verb
	for a in cmd.trim_prefix("kubectl ").split(" ", false):
		var flag: String = a.get_slice("=", 0)
		if flag in TERMINAL_BLOCKED_FLAGS:
			return false
		if skip:
			skip = false
		elif a in ["-n", "--namespace"]:
			skip = true
		elif verb == "" and not a.begins_with("-"):
			verb = a
	return verb != "" and not verb in TERMINAL_BLOCKED_VERBS
