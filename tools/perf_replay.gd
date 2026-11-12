extends SceneTree
## Cost of recording a run: time per recorded frame, and the time to pack a long run for sending.
## Usage: godot --headless --path . -s tools/perf_replay.gd

const Replay = preload("res://scripts/replay.gd")


func _init() -> void:
	var raw := Replay.begin(123, false)
	var inp := {"move": Vector2(1, 0), "shift": true, "aim_tap": false}
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var frames := 60 * 60 * 30
	var worst := 0
	var t0 := Time.get_ticks_usec()
	for i in frames:
		var a := Time.get_ticks_usec()
		Replay.add(raw, 1.0 / 60.0 + rng.randf() * 0.002, inp)
		worst = maxi(worst, Time.get_ticks_usec() - a)
	var total := Time.get_ticks_usec() - t0
	var t1 := Time.get_ticks_msec()
	var wire := Replay.to_wire(raw)
	print("recording 30 min at 60 fps: %.2f microseconds per frame on average, worst frame %d microseconds" % [float(total) / frames, worst])
	print("packing it for sending: %d ms, %d KB raw -> %d KB sent (limit 1855 KB)" % [Time.get_ticks_msec() - t1, raw.size() / 1024, wire.length() / 1024])
	quit()
