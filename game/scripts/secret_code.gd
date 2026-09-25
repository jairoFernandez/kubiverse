class_name SecretCode
## The way down to KUBIVERSE: UNDERGROUND: ↑ ↑ ↓ ↓ ← → and then type START.
## Kept apart from the scene so the tests can feed it keys.

const SEQ := ["up", "up", "down", "down", "left", "right", "s", "t", "a", "r", "t"]
const ARROWS := 6        # after these, the letters are being typed
const IDLE := 4.0        # seconds without a right key before it forgets

var pos := 0
var _idle := 0.0


## The token a key stands for ("" for keys that aren't part of any code).
static func token(keycode: int) -> String:
	match keycode:
		KEY_UP: return "up"
		KEY_DOWN: return "down"
		KEY_LEFT: return "left"
		KEY_RIGHT: return "right"
	if keycode >= KEY_A and keycode <= KEY_Z:
		return char(keycode).to_lower()
	return ""


## Feeds one key; true when the whole code has just been entered.
func feed(tok: String) -> bool:
	if tok == "":
		return false
	_idle = 0.0
	if tok == SEQ[pos]:
		pos += 1
		if pos == SEQ.size():
			pos = 0
			return true
		return false
	# ↑ ↑ ↑ still leaves the last two ↑ as a good start.
	if tok == "up":
		pos = 2 if pos == 2 else 1
	else:
		pos = 0
	return false


## True once the arrows are in: the next keys are START being typed.
func armed() -> bool:
	return pos >= ARROWS


func typed() -> String:
	return "".join(SEQ.slice(ARROWS, maxi(pos, ARROWS))).to_upper()


func tick(delta: float) -> void:
	if pos == 0:
		return
	_idle += delta
	if _idle > IDLE:
		pos = 0
