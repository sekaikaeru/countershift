extends RefCounted
## Behaviour fingerprint: seeded bot games, hashed step by step.
## The lines must stay identical after any change that is not meant to touch gameplay,
## and they show whether two platforms compute the game bit for bit alike.

const Sim = preload("res://scripts/sim.gd")
const Bot = preload("res://scripts/bot.gd")


static func golden_line(skill: float, g: int) -> String:
	var sim := Sim.new(1000 + g, g % 2 == 1)
	var bot := Bot.new(77 + g, skill)
	var h := 17
	var steps := 0
	while sim.dead_t < 0.5 and steps < 60 * 60 * 6:
		# three frame lengths, so the fingerprint covers uneven frame times too
		var dt: float = [1.0 / 60.0, 1.0 / 144.0, 0.031][steps % 3] if g >= 4 else 1.0 / 60.0
		sim.step(dt, bot.decide(sim, dt))
		sim.events.clear()
		steps += 1
		if steps % 20 == 0:
			var acc := sim.p_pos
			for e in sim.enemies:
				acc += e.pos * (e.id % 7 + 1)
			for b in sim.bullets:
				acc += b.pos
			h = hash([h, acc, sim.score, sim.hp, sim.wave, sim.chain, sim.enemies.size(), sim.bullets.size(), sim.focus, sim.time])
	return "skill %.1f seed %d: steps %d score %d wave %d kills %d swaps %d hp %d hash %d" % [skill, 1000 + g, steps, sim.score, sim.wave, sim.kills, sim.swaps, sim.hp, h]


## How this build computes the game, as one number. It drives the simulation with scripted keys
## (no bot, no global random numbers) through slow motion, swaps, chains and uneven frame times.
## Two builds that give the same number replay each other's runs identically; the verifier only
## takes replays recorded with its own fingerprint. Cost: about 2,400 simulation steps once at start-up.
static func fingerprint() -> int:
	var sim := Sim.new(424242, false)
	sim.prev_shift = true
	var lcg := 1234567
	var held := 0
	var dirs := [Vector2.RIGHT, Vector2(1, 1), Vector2.DOWN, Vector2(-1, 1), Vector2.LEFT, Vector2(-1, -1), Vector2.UP, Vector2(1, -1), Vector2.ZERO]
	var mv := Vector2.ZERO
	var h := 5381
	for i in 2400:
		lcg = (lcg * 1103515245 + 12345) & 0x7fffffff
		if i % 17 == 0:
			mv = dirs[(lcg >> 8) % dirs.size()].normalized()
		if held > 0:
			held -= 1
		elif (lcg >> 4) % 40 == 0:
			held = 6 + (lcg >> 12) % 14
		var dt: float = [1.0 / 60.0, 1.0 / 120.0, 0.0213, 1.0 / 144.0, 0.07][(lcg >> 16) % 5]
		sim.step(dt, {"move": mv, "shift": held > 0, "aim_tap": (lcg >> 20) % 31 == 0})
		sim.events.clear()
		if not sim.alive:
			sim = Sim.new(424242 + i, true)
			sim.prev_shift = true
		if i % 25 == 0:
			var acc := sim.p_pos
			for e in sim.enemies:
				acc += e.pos * float(e.id % 5 + 1)
			for b in sim.bullets:
				acc += b.pos
			h = hash([h, acc, sim.score, sim.hp, sim.wave, sim.focus, sim.time, sim.enemies.size()])
	return h & 0xffffffff


## Records one bot-played run exactly the way main.gd records a ranked run (keys only,
## uneven frame times, hitches). Used by the replay tests and the cross-browser check.
static func record_run(seed_value: int, skill: float, tutorial: bool) -> Dictionary:
	var Replay = load("res://scripts/replay.gd")
	var sim := Sim.new(seed_value, tutorial)
	sim.prev_shift = true
	var bot := Bot.new(seed_value + 5, skill)
	var raw: PackedByteArray = Replay.begin(seed_value, tutorial)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var guard := 0
	while sim.dead_t <= Replay.END_DEAD_T and guard < 60 * 60 * 30:
		guard += 1
		var dt := 1.0 / 60.0 + rng.randf_range(-0.004, 0.004)
		if rng.randf() < 0.01:
			dt = rng.randf_range(0.03, 0.12)       # a hitch; longer than the clamp
		var inp: Dictionary = Replay.unpack_input(Replay.pack_input(bot.decide(sim, dt)))
		Replay.add(raw, dt, inp)
		sim.step(dt, inp)
		sim.events.clear()
	Replay.close(raw, sim)
	return {"raw": raw, "score": sim.score, "wave": sim.wave, "kills": sim.kills, "time_ms": int(sim.real_time * 1000.0)}
