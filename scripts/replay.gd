extends RefCounted
## Input replay of one run: the seed plus, for every frame, the frame time and the keys.
## Replaying it through the simulation gives the same run again on any build that computes
## the game identically. Native and Web builds round floating point differently, so a replay
## also carries the platform and a fingerprint of how this build computes the game
## (selftest.gd); a verifier only takes replays whose fingerprint equals its own.
##
## Layout (format 2, little endian):
##   0 "CSR1"  4 u8 format=2  5 u8 flags (1 = tutorial opening)  6 u8 platform  7 u8 0
##   8 u32 seed  12 u32 frames  16 u16 build  18 u16 0  20 u32 fingerprint  24 u32 duration ms
##   28.. per frame: f64 frame time, u8 input (x+1 | (y+1)<<2 | shift<<4 | tap<<5)

const Sim = preload("res://scripts/sim.gd")

const BUILD := 3             # bump whenever gameplay code changes; must match server/src/api.js
const FORMAT := 2
const MAGIC := 0x31525343
const HEADER := 28
const FRAME := 9
const END_DEAD_T := 1.7      # main.gd leaves the run once sim.dead_t passes this
const MAX_FRAMES := 1200000

## How this build computes the game (set once at start-up by main.gd).
static var fingerprint := 0


static func platform_id() -> int:
	if OS.has_feature("web"):
		return 1
	var arch := Engine.get_architecture_name()
	match OS.get_name():
		"macOS":
			return 2 if arch == "arm64" else 3
		"Windows":
			return 4 if arch == "x86_64" else 0
		"Linux":
			return 5 if arch == "x86_64" else 0
	return 0


static func begin(seed_value: int, tutorial: bool) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(HEADER)
	b.encode_u32(0, MAGIC)
	b.encode_u8(4, FORMAT)
	b.encode_u8(5, 1 if tutorial else 0)
	b.encode_u8(6, platform_id())
	b.encode_u32(8, seed_value)
	b.encode_u16(16, BUILD)
	b.encode_u32(20, fingerprint)
	return b


## Writes the play time (the sum of the frame times the game used) before sending.
static func close(b: PackedByteArray, sim: Sim) -> void:
	b.encode_u32(24, int(sim.real_time * 1000.0))


static func pack_input(inp: Dictionary) -> int:
	var mv: Vector2 = inp.get("move", Vector2.ZERO)
	var x := 1 + (1 if mv.x > 0.0 else (-1 if mv.x < 0.0 else 0))
	var y := 1 + (1 if mv.y > 0.0 else (-1 if mv.y < 0.0 else 0))
	return x | (y << 2) | ((1 if inp.get("shift", false) else 0) << 4) | ((1 if inp.get("aim_tap", false) else 0) << 5)


static func unpack_input(b: int) -> Dictionary:
	# built exactly as main.gd builds it from the keys
	var mv := Vector2((b & 3) - 1, ((b >> 2) & 3) - 1)
	return {"move": mv.normalized(), "shift": (b & 16) != 0, "aim_tap": (b & 32) != 0}


static func add(b: PackedByteArray, dt: float, inp: Dictionary) -> void:
	var n := b.size()
	b.resize(n + FRAME)
	b.encode_double(n, dt)
	b.encode_u8(n + 8, pack_input(inp))
	b.encode_u32(12, (n + FRAME - HEADER) / FRAME)


static func to_wire(b: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(b.compress(FileAccess.COMPRESSION_GZIP))


static func from_wire(text: String) -> PackedByteArray:
	var z := Marshalls.base64_to_raw(text)
	if z.is_empty():
		return PackedByteArray()
	return z.decompress_dynamic(HEADER + MAX_FRAMES * FRAME, FileAccess.COMPRESSION_GZIP)


## Starts a replay. Returns {"error": String} or a job for advance().
static func open(raw: PackedByteArray) -> Dictionary:
	if raw.size() < HEADER + FRAME or raw.decode_u32(0) != MAGIC or raw.decode_u8(4) != FORMAT:
		return {"error": "format"}
	var frames := raw.decode_u32(12)
	if frames > MAX_FRAMES or raw.size() != HEADER + frames * FRAME:
		return {"error": "length"}
	if raw.decode_u16(16) != BUILD:
		return {"error": "build"}
	if raw.decode_u8(6) != platform_id():
		return {"error": "platform"}
	if raw.decode_u32(20) != fingerprint:
		return {"error": "fingerprint"}
	var seed_value := raw.decode_u32(8)
	if seed_value == 0:
		return {"error": "seed"}
	var sim := Sim.new(seed_value, raw.decode_u8(5) == 1)
	sim.prev_shift = true          # as main.gd does at the start of a run
	return {"sim": sim, "raw": raw, "frames": frames, "i": 0, "early_end": false, "bad": ""}


## Runs up to max_steps frames. Returns true when the replay is finished.
static func advance(job: Dictionary, max_steps: int) -> bool:
	var sim: Sim = job["sim"]
	var raw: PackedByteArray = job["raw"]
	var i: int = job["i"]
	var frames: int = job["frames"]
	var stop := mini(frames, i + max_steps)
	while i < stop:
		if sim.dead_t > END_DEAD_T:
			job["early_end"] = true      # frames after the run was over: not a real recording
			i = frames
			break
		var o := HEADER + i * FRAME
		var dt := raw.decode_double(o)
		var b := raw.decode_u8(o + 8)
		if not (dt > 0.0 and dt <= 1.0) or (b & 3) > 2 or ((b >> 2) & 3) > 2 or (b >> 6) != 0:
			job["bad"] = "frame"         # a frame the game can never record
			i = frames
			break
		sim.step(dt, unpack_input(b))
		sim.events.clear()
		i += 1
	job["i"] = i
	return i >= frames


static func result(job: Dictionary) -> Dictionary:
	var sim: Sim = job["sim"]
	var raw: PackedByteArray = job["raw"]
	if job["bad"] != "":
		return {"ok": false, "reason": "bad_frame"}
	if job["early_end"]:
		return {"ok": false, "reason": "frames_after_end"}
	if sim.alive or sim.dead_t <= END_DEAD_T:
		return {"ok": false, "reason": "run_not_finished"}
	var time_ms := int(sim.real_time * 1000.0)
	if time_ms != raw.decode_u32(24):
		return {"ok": false, "reason": "duration_mismatch"}
	return {"ok": true, "score": sim.score, "wave": sim.wave, "kills": sim.kills, "time_ms": time_ms}


static func simulate(raw: PackedByteArray) -> Dictionary:
	var job := open(raw)
	if job.has("error"):
		return {"ok": false, "reason": job["error"]}
	while not advance(job, 100000):
		pass
	return result(job)
