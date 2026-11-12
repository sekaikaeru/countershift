extends SceneTree
## Replay check: record seeded games key by key, replay them, and try to cheat.
## Usage: godot --headless --path . -s tools/replay_test.gd

const Sim = preload("res://scripts/sim.gd")
const Bot = preload("res://scripts/bot.gd")
const Replay = preload("res://scripts/replay.gd")
const SelfTest = preload("res://scripts/selftest.gd")

var total := 0
var failed := 0


func expect(what: String, ok: bool) -> void:
	total += 1
	if not ok:
		failed += 1
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])


func record(seed_value: int, skill: float, tutorial: bool) -> Array:
	var r: Dictionary = SelfTest.record_run(seed_value, skill, tutorial)
	var sim := Sim.new(1, false)
	sim.score = r["score"]
	sim.wave = r["wave"]
	sim.kills = r["kills"]
	sim.real_time = r["time_ms"] / 1000.0
	return [r["raw"], sim]


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	Replay.fingerprint = SelfTest.fingerprint()
	var fp_ms := Time.get_ticks_msec() - t0
	expect("the fingerprint is stable (%d, %d ms)" % [Replay.fingerprint, fp_ms], SelfTest.fingerprint() == Replay.fingerprint)
	var sizes := []
	for g in 6:
		var got := record(4000 + g, 1.0 if g < 3 else 0.4, g % 2 == 0)
		var raw: PackedByteArray = got[0]
		var sim: Sim = got[1]
		var res: Dictionary = Replay.simulate(raw)
		expect("seed %d: replay gives the same run (score %d, wave %d, %d frames)" % [4000 + g, sim.score, sim.wave, raw.decode_u32(12)],
			res.get("ok", false) and res["score"] == sim.score and res["wave"] == sim.wave and res["kills"] == sim.kills)
		var wire := Replay.to_wire(raw)
		expect("  it survives the trip over the wire", Replay.from_wire(wire) == raw)
		sizes.append("%.0f s -> %d KB sent" % [sim.real_time, wire.length() / 1024])
		if g == 0:
			# cheats: every one must end in a different score or an invalid replay
			var cut := raw.slice(0, raw.size() - Replay.FRAME * 300)
			cut.encode_u32(12, (cut.size() - Replay.HEADER) / Replay.FRAME)
			expect("  cut short before the end: refused", Replay.simulate(cut).get("ok", true) == false)
			var longer := raw.duplicate()
			for i in 50:
				Replay.add(longer, 1.0 / 60.0, {})
			expect("  frames added after the end: refused", Replay.simulate(longer).get("ok", true) == false)
			var other := raw.duplicate()
			other.encode_u32(8, 4999)
			var r2: Dictionary = Replay.simulate(other)
			expect("  another seed: a different run", not r2.get("ok", false) or r2["score"] != sim.score)
			var changed := 0
			for k in 8:
				var edit := raw.duplicate()
				var frame := 600 + k * 431
				var o := Replay.HEADER + frame * Replay.FRAME + 8
				edit.encode_u8(o, edit.decode_u8(o) ^ 16)      # press or release shift on one frame
				var r3: Dictionary = Replay.simulate(edit)
				if not r3.get("ok", false) or r3["score"] != sim.score:
					changed += 1
			expect("  one changed key press changes the result (%d of 8 edits)" % changed, changed >= 6)
			var bad := raw.duplicate()
			bad.encode_u16(16, Replay.BUILD + 1)
			expect("  another build: refused", Replay.simulate(bad).get("reason", "") == "build")
			bad = raw.duplicate()
			bad.encode_u8(6, 1 if Replay.platform_id() != 1 else 2)
			expect("  another platform: refused", Replay.simulate(bad).get("reason", "") == "platform")
			expect("  rubbish: refused", Replay.simulate(PackedByteArray([1, 2, 3])).get("ok", true) == false)
			bad = raw.duplicate()
			bad.encode_u32(20, Replay.fingerprint ^ 1)
			expect("  another fingerprint: refused", Replay.simulate(bad).get("reason", "") == "fingerprint")
			bad = raw.duplicate()
			bad.encode_u32(24, raw.decode_u32(24) - 5000)
			expect("  play time claimed 5 s shorter: refused", Replay.simulate(bad).get("reason", "") == "duration_mismatch")
			bad = raw.duplicate()
			bad.encode_double(Replay.HEADER + 100 * Replay.FRAME, -0.5)
			expect("  a negative frame time: refused", Replay.simulate(bad).get("reason", "") == "bad_frame")
			bad = raw.duplicate()
			bad.encode_u8(Replay.HEADER + 100 * Replay.FRAME + 8, 0xff)
			expect("  an impossible key byte: refused", Replay.simulate(bad).get("reason", "") == "bad_frame")
	print("replay sizes: ", ", ".join(sizes))
	print("replay test: %d checks, %d failed" % [total, failed])
	quit(1 if failed > 0 else 0)
