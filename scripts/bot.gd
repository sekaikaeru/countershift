extends RefCounted
## Autoplayer: drives the title-screen demo and the headless tests through the same
## input the player uses (move + shift), so anything it does a person can do.

const Sim = preload("res://scripts/sim.gd")

var skill := 1.0          # 0..1: how often it notices a chance
var rng := RandomNumberGenerator.new()
var hold := 0             # frames left holding shift
var pick: Sim.Enemy = null
var think := 0.0
var wander := Vector2.ZERO
var wander_t := 0.0


func _init(seed_value: int = 1, skill_value: float = 1.0) -> void:
	rng.seed = seed_value
	skill = skill_value


## How dangerous is standing at `pos` for the next `horizon` seconds (0 = safe).
static func danger(sim: Sim, pos: Vector2, horizon: float, ignore: Sim.Enemy = null) -> float:
	var d := 0.0
	for b in sim.bullets:
		if not b.alive:
			continue
		var rel := pos - b.pos
		var sp2 := b.vel.length_squared()
		var t := clampf(rel.dot(b.vel) / maxf(sp2, 1.0), 0.0, horizon)
		if (b.pos + b.vel * t).distance_to(pos) < 26.0:
			d += 1.0
	for e in sim.enemies:
		if not e.alive or e == ignore or e.spawn_t > 0.0:
			continue
		var dist := e.pos.distance_to(pos)
		match e.type:
			Sim.SWARMER:
				if e.daze <= 0.0 and dist < 58.0:
					d += 0.8
			Sim.CHARGER:
				if e.state == 1 or e.state == 2:
					var end := Sim.ray_to_wall(e.pos, e.dir)
					if Sim.seg_dist(pos, e.pos, end) < 34.0:
						d += 1.5
			Sim.LANCER:
				if (e.state == 1 and e.t < 0.75) or e.state == 2:
					var end2 := Sim.ray_to_wall(e.pos, e.dir)
					if Sim.seg_dist(pos, e.pos, end2) < 30.0:
						d += 1.5
			Sim.BOMBER:
				if e.state == 1 and dist < Sim.BLAST_R + 12.0:
					d += 1.5
				elif dist < 100.0:
					d += 0.4
	for bl in sim.blasts:
		if bl.pos.distance_to(pos) < bl.r + 10.0:
			d += 2.0
	return d


func decide(sim: Sim, dt: float) -> Dictionary:
	var out := {"move": Vector2.ZERO, "shift": false, "target": null}
	if not sim.alive:
		return out
	# finish a shift in progress: hold for a few frames, then release
	if hold > 0:
		hold -= 1
		out["shift"] = hold > 0
		out["target"] = pick if (pick != null and pick.alive) else null
		return out

	var here := danger(sim, sim.p_pos, 0.55)
	think -= dt
	if think <= 0.0 and sim.cooldown <= 0.0 and sim.focus > 0.25:
		think = lerpf(0.5, 0.06, skill)
		var best: Sim.Enemy = null
		var best_v := 0.35
		var pack := 0
		for e in sim.enemies:
			if e.alive and e.type == Sim.SWARMER and e.spawn_t <= 0.0 and e.pos.distance_to(sim.p_pos) < 105.0:
				pack += 1
		var lethal := here + pack * 0.5
		if lethal > 0.4:
			for e in sim.enemies:
				if not e.alive or e.spawn_t > 0.0 or e.locked:
					continue
				var there := danger(sim, e.pos, 0.6, e)
				if there > 0.3:
					continue
				var v := lethal + 0.2
				if e.type != Sim.SWARMER:
					v += 0.5
				if e.pos.distance_to(sim.p_pos) < 150.0:
					v -= 0.6
				v += rng.randf() * 0.2
				if v > best_v:
					best_v = v
					best = e
		if best != null and rng.randf() < 0.35 + skill * 0.65:
			pick = best
			hold = 4
			out["shift"] = true
			out["target"] = best
			return out

	# movement: slide away from threats, stay off the walls
	var mv := Vector2.ZERO
	for e in sim.enemies:
		if not e.alive or e.spawn_t > 0.0:
			continue
		var away := sim.p_pos - e.pos
		var dist := maxf(away.length(), 1.0)
		match e.type:
			Sim.SWARMER:
				if dist < 200.0:
					mv += away / dist * (200.0 - dist) / 200.0 * 1.6
			Sim.BOMBER:
				if dist < 230.0:
					mv += away / dist * (230.0 - dist) / 230.0 * 2.2
			Sim.CHARGER, Sim.LANCER:
				if e.state == 1 or e.state == 2:
					var end := Sim.ray_to_wall(e.pos, e.dir)
					if Sim.seg_dist(sim.p_pos, e.pos, end) < 70.0:
						var side := e.dir.orthogonal()
						if side.dot(away) < 0.0:
							side = -side
						mv += side * 3.0
	for b in sim.bullets:
		var rel := sim.p_pos - b.pos
		var t := rel.dot(b.vel) / maxf(b.vel.length_squared(), 1.0)
		if t > 0.0 and t < 0.9:
			var miss := sim.p_pos - (b.pos + b.vel * t)
			if miss.length() < 48.0:
				var side2 := b.vel.normalized().orthogonal()
				if side2.dot(miss) < 0.0:
					side2 = -side2
				mv += side2 * 2.4
	var c := Sim.ARENA.get_center()
	var off := (sim.p_pos - c) / (Sim.ARENA.size * 0.5)
	if absf(off.x) > 0.72:
		mv.x -= signf(off.x) * (absf(off.x) - 0.72) * 9.0
	if absf(off.y) > 0.66:
		mv.y -= signf(off.y) * (absf(off.y) - 0.66) * 9.0
	wander_t -= dt
	if wander_t <= 0.0:
		wander_t = 0.6 + rng.randf()
		wander = Vector2.from_angle(rng.randf() * TAU) * 0.5
	mv += wander
	if mv.length() > 0.15:
		out["move"] = mv.normalized()
	return out
