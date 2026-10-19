extends "res://tests/harness.gd"
## Headless checks of KUBIVERSE: UNDERGROUND as a 3D room (a cabinet per
## minigame) and of a cabinet's screen coming to the front and going back:
##   godot --headless --path game --script res://tests/test_arcade.gd


## Stands in for the player: Underground freezes it while a screen is in front.
class FakePlayer extends Node:
	var frozen := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame  # underground.gd and world.gd use autoloads: load them once they exist
	var AH: GDScript = load("res://scripts/arcade_hall.gd")
	var UG: GDScript = load("res://scripts/underground.gd")
	_layout(AH, UG)
	_reach(AH)
	_games(AH, UG)
	await _room(AH, UG)
	await _front(UG)
	await _code(UG)
	finish("arcade tests")


## A row of cabinets along the back wall: inside the room, apart enough to
## walk between them, and a free spot in front of each to stand and play.
func _layout(AH: GDScript, UG: GDScript) -> void:
	var n: int = UG.GAMES.size()
	var spots: Array = AH.layout(n)
	check(spots.size() == n, "one spot per game (%d)" % spots.size())
	var sum := 0.0
	for p in spots:
		sum += p.x
	check(absf(sum) < 0.01, "the row is centered (sum x %.2f)" % sum)
	var room: Rect2 = AH.ROOM
	for i in n:
		var foot: Rect2 = AH.footprint(spots[i])
		check(room.encloses(foot), "cabinet %d inside the room: %s" % [i, foot])
		var f: Vector3 = AH.front_of(spots[i])
		check(room.has_point(Vector2(f.x, f.z)), "the spot in front of cabinet %d is on the floor" % i)
		check(not foot.grow(0.3).has_point(Vector2(f.x, f.z)), "you can stand in front of cabinet %d (not inside it)" % i)
		if i > 0:
			var gap: float = foot.position.x - AH.footprint(spots[i - 1]).end.x
			check(gap >= 1.0, "room to walk between cabinets %d and %d (%.2f)" % [i - 1, i, gap])


## Which cabinet E plays: the one whose front spot is closest, within reach.
func _reach(AH: GDScript) -> void:
	var cabs: Array = AH.layout(3)
	for i in 3:
		check(AH.machine_near(cabs, AH.front_of(cabs[i])) == i, "standing in front of cabinet %d plays it" % i)
	var between: Vector3 = AH.front_of(cabs[0]).lerp(AH.front_of(cabs[1]), 0.6)
	check(AH.machine_near(cabs, between) == 1, "between two cabinets: the closer one")
	check(AH.machine_near(cabs, AH.SPAWN + Vector3(0, 0, 4)) == -1, "far from all of them: none")
	check(AH.machine_near(cabs, AH.front_of(cabs[2]) + Vector3(AH.REACH + 0.1, 0, 0)) == -1, "just out of reach: none")
	check(AH.machine_near([], Vector3.ZERO) == -1, "no cabinets: none")


func _games(AH: GDScript, UG: GDScript) -> void:
	check(AH.game("snake").title == "OOM SNAKE", "a game by its id")
	check(AH.game("nope").is_empty(), "an unknown id: {}")
	check(not AH.playable("soon"), "the last cabinet is out of order")
	var ids := []
	for g in UG.GAMES:
		ids.append(g.id)
	for id in UG.PLAYABLE:
		check(id in ids and AH.playable(id), "%s has a cabinet and can be played" % id)


## The room is a World level: it is built without a cluster, has a cabinet
## (an entity you can click) per game, an E spot in front of each and the
## elevator back to where you came from.
func _room(AH: GDScript, UG: GDScript) -> void:
	var WS: GDScript = load("res://scripts/world.gd")
	var world: Node3D = WS.new()
	root.add_child(world)
	world.arcade_exit = "ns:shop"
	world.set_level("arcade")
	await process_frame
	check(world.level == "arcade" and world.level_title().contains("UNDERGROUND"), "level arcade: %s" % world.level_title())
	check(world.cabinets.size() == UG.GAMES.size(), "a cabinet per game (%d)" % world.cabinets.size())
	var exits: Array = world.doors.filter(func(d): return d.to == "ns:shop")
	check(exits.size() == 1, "the elevator goes back up to where you came from")
	check(world.can_stand(world.spawn), "you arrive on the floor")
	for g in UG.GAMES:
		var cab: Node3D = world.cabinets.get(g.id)
		check(cab != null and cab.kind == "cabinet" and world.find_entity("cabinet", g.id) == cab, "%s: cabinet entity" % g.id)
		if cab == null:
			continue
		check(cab in world.all_entities(), "%s can be hovered and clicked" % g.id)
		check(not world.can_stand(cab.position), "%s is solid" % g.id)
		var f: Vector3 = AH.front_of(cab.position)
		check(world.can_stand(f), "%s: you can stand in front" % g.id)
		check(world.door_near(f, AH.REACH).get("to", "") == "arcade:" + g.id, "%s: E there plays it" % g.id)
	# Between whack and snake, nearer snake: E plays snake, not the first door in the list.
	var near_snake: Vector3 = AH.front_of(world.cabinets.whack.position).lerp(AH.front_of(world.cabinets.snake.position), 0.7)
	check(world.door_near(near_snake, AH.REACH).get("to", "") == "arcade:snake", "the closest cabinet wins")
	var labels: Array = world.labels(AH.front_of(world.cabinets.snake.position))
	check(labels.any(func(l): return l.text == "PLAY [E]"), "in front of one: PLAY [E]")
	check(labels.any(func(l): return l.text == "OOM SNAKE"), "cabinets are labelled with their game")
	var cab_soon: Node3D = world.cabinets.soon
	check(cab_soon.label_sub() == "OUT OF ORDER", "the out of order cabinet says so")
	# Cabinets walk with E, not by stepping on their spot like a door.
	world.set_level("plant")
	check(world.cabinets.is_empty(), "leaving the room drops its cabinets")
	world.queue_free()
	await process_frame


## E brings the screen to the front (the camera's zoom first when it knows
## where the cabinet is); ESC brings you back to the room.
func _front(UG: GDScript) -> void:
	var ug: CanvasLayer = UG.new()
	var me := FakePlayer.new()
	ug.player = me
	root.add_child(ug)
	root.add_child(me)
	await process_frame
	var left := [0]
	ug.left_machine.connect(func(): left[0] += 1)
	check(not ug.is_open(), "closed at first")
	check(not ug.play("soon"), "the out of order cabinet can't be played")
	check(not ug.is_open() and not me.frozen, "and nothing comes to the front")
	check(ug.play("snake"), "snake plays")
	check(ug.is_open() and ug.state() == "play" and ug.playing_id() == "snake", "its screen is in front, playing (%s)" % ug.state())
	check(_script_of(ug._game) == "arcade_snake.gd", "the snake game runs")
	check(me.frozen, "the player stands still meanwhile")
	ug.key(KEY_ESCAPE)
	check(not ug.is_open() and ug.state() == "" and ug.playing_id() == "", "ESC: back to the room")
	check(not me.frozen and left[0] == 1, "the player walks again (left signals: %d)" % left[0])
	# From where it stood on the window: a short zoom, then the game.
	check(ug.play("whack", Rect2(700, 300, 40, 48)), "whack plays")
	check(ug.state() == "zoom", "it first comes to the front (%s)" % ug.state())
	ug.tick(UG.ZOOM_T * 0.5)
	check(ug.state() == "zoom", "still zooming halfway")
	ug.tick(UG.ZOOM_T)
	check(ug.state() == "play" and _script_of(ug._game) == "arcade_whack.gd", "then the game")
	# Round over (no new high score, so nothing is saved): ENTER again, ESC to the room.
	ug._game.score = 0
	ug.game_over("TIME'S UP", "test")
	check(ug.state() == "over", "round over")
	ug.key(KEY_ENTER)
	check(ug.state() == "over", "ENTER right away doesn't restart (a key still held)")
	ug.tick(0.6)
	ug.key(KEY_ENTER)
	check(ug.state() == "play" and ug.playing_id() == "whack", "ENTER: the same game again")
	ug.game_over("TIME'S UP", "test")
	ug.key(KEY_ESCAPE)
	check(not ug.is_open() and left[0] == 2, "ESC after the round: back to the room")
	# ESC while it is still zooming in.
	ug.play("laser", Rect2(10, 10, 20, 20))
	ug.key(KEY_ESCAPE)
	check(not ug.is_open() and not me.frozen and left[0] == 3, "ESC during the zoom: back to the room")
	ug.leave()
	check(left[0] == 3, "leaving twice signals once")
	ug.queue_free()
	me.queue_free()
	await process_frame


## The code on the surface takes you down (once); down in the room it does nothing.
func _code(UG: GDScript) -> void:
	var ug: CanvasLayer = UG.new()
	var me := FakePlayer.new()
	ug.player = me
	root.add_child(ug)
	root.add_child(me)
	await process_frame
	var entered := [0]
	ug.entered.connect(func(): entered[0] += 1)
	var seq := [KEY_UP, KEY_UP, KEY_DOWN, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_S, KEY_T, KEY_A, KEY_R, KEY_T]
	ug.in_room = true
	for k in seq:
		ug._listen(_key_event(k))
	check(entered[0] == 0 and not ug.is_open(), "in the room the code does nothing")
	ug.in_room = false
	for k in seq:
		ug._listen(_key_event(k))
	check(entered[0] == 1, "on the surface it takes you down")
	check(ug.is_open() and ug.state() == "descend" and me.frozen, "riding the elevator down")
	ug.tick(UG.DESCEND_T + 0.1)
	check(not ug.is_open() and ug.state() == "" and not me.frozen, "then you walk in the room")
	ug.go_down(false)
	check(entered[0] == 2 and not ug.is_open(), "straight down (dev captures): no ride")
	ug.queue_free()
	me.queue_free()
	await process_frame


## The file of a game's script (the arcade classes can't be named here: they
## use autoloads, which don't exist yet when this test compiles).
func _script_of(o: Object) -> String:
	return o.get_script().resource_path.get_file() if o else ""


func _key_event(k: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.pressed = true
	return ev
