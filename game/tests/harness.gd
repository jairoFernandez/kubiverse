extends SceneTree
## Shared base of the headless tests (extends "res://tests/harness.gd").
##
## - check() prints a FAIL line and counts it. Never use assert() here: a
##   failed assert stops in the debugger and headless Godot hangs forever.
## - finish() prints the summary and quits with a non-zero code on failures.
## - A watchdog quits with a failure if the test never reaches finish() (a
##   script error aborts the test function, and the main loop would otherwise
##   keep running with nobody calling quit()).

const WATCHDOG_FRAMES := 120

var fails := 0
var _done := false
var _frames := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		print("FAIL: " + msg)
		fails += 1


func finish(label: String) -> void:
	_done = true
	print("%s: %s" % [label, "OK" if fails == 0 else "%d FAILED" % fails])
	# Exit codes wrap at 256: never let 256 failures look like a pass.
	quit(mini(fails, 100))


func _process(_delta: float) -> bool:
	if _done:
		return false
	_frames += 1
	if _frames > WATCHDOG_FRAMES:
		print("FAIL: the test stopped before finishing (see the SCRIPT ERROR above)")
		_done = true
		quit(1 + mini(fails, 99))
	return false
