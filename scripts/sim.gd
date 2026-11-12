extends RefCounted
## COUNTERSHIFT simulation. No nodes, no rendering: the view and the audio read `events`.
## The player has no weapon. SHIFT trades places with an enemy; a shifted enemy is
## EXPOSED and dies to anything its allies do.

const ARENA := Rect2(56, 92, 1168, 572)
enum { SWARMER, GUNNER, CHARGER, LANCER, BOMBER }
const BASE_SCORE: Array[int] = [40, 150, 200, 250, 120]
const RADIUS: Array[float] = [11.0, 16.0, 17.0, 18.0, 16.0]

const PLAYER_R := 9.0
const PLAYER_SPEED := 335.0
const FOCUS_SECONDS := 1.5      # real seconds of slow motion in a full gauge
const FOCUS_MIN_COST := 0.2
const FOCUS_SCALE := 0.1        # world speed while focusing
const EXPOSE_TIME := 2.4
const DAZE_TIME := 0.8
const NOVA_R := 62.0
const BLAST_R := 128.0
const CHAIN_WINDOW := 3.2
const MAX_HP := 3


class Enemy:
	var id := 0
	var type := 0
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var r := 12.0
	var spawn_t := 0.9
	var daze := 0.0
	var exposed := 0.0
	var state := 0
	var t := 0.0
	var cool := 0.0
	var dir := Vector2.RIGHT
	var alive := true
	var seed := 0.0
	var swap_time := -99.0
	var spread := false
	var locked := false     # cannot be shifted; only blasts reach it
	var die_t := -1.0
	var die_shift := false
	var age := 0.0


class Bullet:
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var owner := 0
	var birth := 0.0
	var alive := true


class Beam:
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	var t := 0.0
	var owner := 0


class Blast:
	var pos := Vector2.ZERO
	var t := 0.0
	var r := 0.0


var rng := RandomNumberGenerator.new()
var events: Array = []
var time := 0.0          # scaled world time
var real_time := 0.0
var ts := 1.0            # current time scale
var hitstop := 0.0

var p_pos := ARENA.get_center()
var p_vel := Vector2.ZERO
var p_face := Vector2.UP
var hp := MAX_HP
var inv := 0.0
var alive := true
var dead_t := 0.0

var focus := 1.0
var focusing := false
var focus_delay := 0.0
var focus_spent := 0.0
var cooldown := 0.0
var target: Enemy = null
var aim := Vector2.ZERO
var aim_cycle := 0
var prev_shift := false

var enemies: Array[Enemy] = []
var bullets: Array[Bullet] = []
var beams: Array[Beam] = []
var blasts: Array[Blast] = []
var next_id := 1

var wave := 0
var wave_time := 0.0
var intermission := 1.6
var groups: Array = []   # [{t: float, types: Array}]

var score := 0
var chain := 0
var chain_t := 0.0
var mult := 1
var kills := 0
var shift_kills := 0
var swaps := 0
var max_chain := 0
var best_burst := 0
var burst := 0
var burst_t := 0.0
var hits_taken := 0
var tutorial := false    # gentler opening for a first-time player


func _init(seed_value: int = 0, with_tutorial: bool = false) -> void:
	if seed_value == 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	tutorial = with_tutorial


func ev(kind: String, data: Dictionary = {}) -> void:
	data["k"] = kind
	events.append(data)


# ---------------------------------------------------------------- step

## inp: move(Vector2), shift(bool), aim_tap(bool), target(Enemy|null, bot only)
func step(real_dt: float, inp: Dictionary) -> void:
	real_dt = minf(real_dt, 0.05)
	real_time += real_dt
	var move: Vector2 = inp.get("move", Vector2.ZERO)
	var shift: bool = inp.get("shift", false)
	if move.length() > 1.0:
		move = move.normalized()

	if not alive:
		dead_t += real_dt
		ts = move_toward(ts, 0.25, real_dt * 3.0)
		_world(real_dt * ts, Vector2.ZERO)
		return

	# ---- focus / shift
	cooldown = maxf(0.0, cooldown - real_dt)
	var pressed := shift and not prev_shift
	var released := prev_shift and not shift
	prev_shift = shift
	if pressed and not focusing:
		if focus >= FOCUS_MIN_COST and cooldown <= 0.0 and _targetable_count() > 0:
			focusing = true
			focus_spent = 0.0
			aim = move
			aim_cycle = 0
			target = inp.get("target", null)
			if target == null:
				target = pick_target(aim, 0)
			ev("focus_in")
		else:
			ev("empty")
	if focusing:
		var forced: Enemy = inp.get("target", null)
		if forced != null:
			target = forced
		elif move != Vector2.ZERO:
			if inp.get("aim_tap", false) and aim != Vector2.ZERO and move.dot(aim) > 0.92:
				aim_cycle += 1
			elif move.dot(aim) < 0.92:
				aim_cycle = 0
			aim = move
			target = pick_target(aim, aim_cycle)
		if target != null and (not target.alive or target.spawn_t > 0.0):
			target = pick_target(aim, 0)
		var cost := real_dt / FOCUS_SECONDS
		focus -= cost
		focus_spent += cost
		if released or not shift or focus <= 0.0:
			if focus_spent < FOCUS_MIN_COST:
				focus -= FOCUS_MIN_COST - focus_spent
			focus = maxf(focus, 0.0)
			focusing = false
			focus_delay = 0.35
			ev("focus_out")
			if target != null and target.alive:
				_swap(target)
			target = null
	else:
		focus_delay -= real_dt
		if focus_delay <= 0.0:
			focus = minf(1.0, focus + real_dt * 0.24)

	ts = move_toward(ts, FOCUS_SCALE if focusing else 1.0, real_dt * (14.0 if focusing else 7.0))
	if hitstop > 0.0:
		hitstop -= real_dt
		return
	_world(real_dt * ts, move)


func _world(dt: float, move: Vector2) -> void:
	time += dt
	if alive:
		_player(dt, move)
		_waves(dt)
	if chain > 0:
		chain_t -= dt
		if chain_t <= 0.0:
			chain = 0
			mult = 1
			ev("chain_end")
	if burst > 0:
		burst_t -= dt
		if burst_t <= 0.0:
			if burst >= 3:
				ev("burst", {"n": burst, "pos": p_pos})
			burst = 0
	_enemies(dt)
	_bullets(dt)
	_beams(dt)
	_blasts(dt)
	_pending(dt)
	var i := enemies.size() - 1
	while i >= 0:
		if not enemies[i].alive:
			enemies.remove_at(i)
		i -= 1
	i = bullets.size() - 1
	while i >= 0:
		if not bullets[i].alive:
			bullets.remove_at(i)
		i -= 1


func _player(dt: float, move: Vector2) -> void:
	inv = maxf(0.0, inv - dt)
	if not focusing:
		var want := move * PLAYER_SPEED
		p_vel = p_vel.move_toward(want, 3400.0 * dt)
		if move != Vector2.ZERO:
			p_face = move
	p_pos += p_vel * dt
	var c := p_pos.clamp(ARENA.position + Vector2(PLAYER_R, PLAYER_R), ARENA.end - Vector2(PLAYER_R, PLAYER_R))
	if c.x != p_pos.x:
		p_vel.x = 0.0
	if c.y != p_pos.y:
		p_vel.y = 0.0
	p_pos = c


# ---------------------------------------------------------------- targeting

func _targetable_count() -> int:
	var n := 0
	for e in enemies:
		if e.alive and e.spawn_t <= 0.0 and not e.locked:
			n += 1
	return n


func pick_target(dir: Vector2, cycle: int) -> Enemy:
	var list: Array[Enemy] = []
	for e in enemies:
		if e.alive and e.spawn_t <= 0.0 and not e.locked:
			list.append(e)
	if list.is_empty():
		return null
	var origin := p_pos
	if dir == Vector2.ZERO:
		list.sort_custom(func(a: Enemy, b: Enemy) -> bool: return a.pos.distance_squared_to(origin) < b.pos.distance_squared_to(origin))
		return list[cycle % list.size()]
	for cone in [0.42, 0.85, 1.6]:
		var inside: Array[Enemy] = []
		for e in list:
			if absf(dir.angle_to(e.pos - origin)) <= cone:
				inside.append(e)
		if not inside.is_empty():
			inside.sort_custom(func(a: Enemy, b: Enemy) -> bool: return a.pos.distance_squared_to(origin) < b.pos.distance_squared_to(origin))
			return inside[cycle % inside.size()]
	list.sort_custom(func(a: Enemy, b: Enemy) -> bool: return absf(dir.angle_to(a.pos - origin)) < absf(dir.angle_to(b.pos - origin)))
	return list[0]


func _swap(e: Enemy) -> void:
	var a := p_pos
	var b := e.pos
	p_pos = b
	e.pos = a
	e.vel = Vector2.ZERO
	e.daze = DAZE_TIME
	e.exposed = EXPOSE_TIME
	e.swap_time = time
	match e.type:
		CHARGER:
			e.state = 0
			e.cool = 1.0
		LANCER:
			e.state = 0
			e.cool = 1.6
		GUNNER:
			e.cool = maxf(e.cool, 1.0)
	inv = maxf(inv, 0.16)
	cooldown = 0.2
	hitstop = 0.05
	swaps += 1
	ev("swap", {"a": a, "b": b, "type": e.type, "id": e.id})


# ---------------------------------------------------------------- damage

func _hurt(from: Vector2) -> void:
	if inv > 0.0 or not alive:
		return
	hp -= 1
	hits_taken += 1
	inv = 1.6
	hitstop = 0.12
	chain = 0
	mult = 1
	for b in bullets:
		if b.pos.distance_to(p_pos) < 230.0:
			b.alive = false
	for e in enemies:
		if e.alive and e.spawn_t <= 0.0 and e.pos.distance_to(p_pos) < 170.0:
			e.daze = maxf(e.daze, 0.9)
			e.vel = (e.pos - p_pos).normalized() * 260.0
			if e.type == CHARGER and e.state != 0:
				e.state = 0
				e.cool = 1.2
	if hp <= 0:
		alive = false
		focusing = false
		target = null
		ev("dead", {"pos": p_pos})
	else:
		ev("hurt", {"pos": p_pos, "from": from})


func _kill(e: Enemy, by_shift: bool, scored: bool = true) -> void:
	if not e.alive:
		return
	e.alive = false
	var pts := 0
	if scored:
		kills += 1
		chain += 1
		chain_t = CHAIN_WINDOW
		max_chain = maxi(max_chain, chain)
		mult = mini(9, 1 + chain / 4)
		burst += 1
		burst_t = 0.45
		best_burst = maxi(best_burst, burst)
		pts = BASE_SCORE[e.type] * mult * (2 if by_shift else 1)
		score += pts
		if by_shift:
			shift_kills += 1
		focus = minf(1.0, focus + 0.025)
	ev("kill", {"pos": e.pos, "type": e.type, "pts": pts, "shift": by_shift, "chain": chain, "mult": mult})
	if e.type == BOMBER:
		var bl := Blast.new()
		bl.pos = e.pos
		bl.t = 0.16 if scored else 0.0
		bl.r = BLAST_R
		blasts.append(bl)
		ev("fuse_pop", {"pos": e.pos})
	elif scored:
		ev("nova", {"pos": e.pos})
		for o in enemies:
			if o.alive and o.spawn_t <= 0.0 and o.die_t < 0.0:
				var d := o.pos.distance_to(e.pos)
				if d < NOVA_R + o.r:
					o.die_t = 0.07 + d * 0.0006
					o.die_shift = false
		for b in bullets:
			if b.pos.distance_to(e.pos) < NOVA_R:
				b.alive = false


func _pending(dt: float) -> void:
	for e in enemies:
		if e.alive and e.die_t >= 0.0:
			e.die_t -= dt
			if e.die_t < 0.0:
				_kill(e, e.die_shift)


func _blasts(dt: float) -> void:
	var i := blasts.size() - 1
	while i >= 0:
		var bl := blasts[i]
		bl.t -= dt
		if bl.t <= 0.0:
			blasts.remove_at(i)
			ev("explode", {"pos": bl.pos, "r": bl.r})
			for e in enemies:
				if e.alive and e.spawn_t <= 0.0 and e.die_t < 0.0 and e.pos.distance_to(bl.pos) < bl.r + e.r:
					e.die_t = 0.03 + e.pos.distance_to(bl.pos) * 0.0005
					e.die_shift = e.exposed > 0.0
			for b in bullets:
				if b.pos.distance_to(bl.pos) < bl.r:
					b.alive = false
			if alive and p_pos.distance_to(bl.pos) < bl.r - 6.0:
				_hurt(bl.pos)
		i -= 1


# ---------------------------------------------------------------- enemies

func _enemies(dt: float) -> void:
	var n := enemies.size()
	for i in n:
		var a := enemies[i]
		if not a.alive or a.spawn_t > 0.0:
			continue
		for j in range(i + 1, n):
			var b := enemies[j]
			if not b.alive or b.spawn_t > 0.0:
				continue
			var d := b.pos - a.pos
			var need := a.r + b.r + 10.0
			var l2 := d.length_squared()
			if l2 < need * need and l2 > 0.01:
				var l := sqrt(l2)
				var push := d / l * (need - l) * 0.5
				var sa := 0.0 if (a.type == CHARGER and a.state == 2) or a.daze > 0.0 else 1.0
				var sb := 0.0 if (b.type == CHARGER and b.state == 2) or b.daze > 0.0 else 1.0
				a.pos -= push * sa * minf(1.0, dt * 10.0)
				b.pos += push * sb * minf(1.0, dt * 10.0)
	for e in enemies:
		if not e.alive:
			continue
		if e.spawn_t > 0.0:
			e.spawn_t -= dt
			if e.spawn_t <= 0.0:
				ev("arrive", {"pos": e.pos, "type": e.type})
			continue
		e.age += dt
		e.exposed = maxf(0.0, e.exposed - dt)
		if e.type == BOMBER and e.state == 1:
			e.t -= dt
			if e.t <= 0.0:
				_kill(e, false, false)
				continue
		if e.daze > 0.0:
			e.daze -= dt
			e.vel *= pow(0.02, dt)
			e.pos += e.vel * dt
			_clamp(e)
			continue
		match e.type:
			SWARMER: _swarmer(e, dt)
			GUNNER: _gunner(e, dt)
			CHARGER: _charger(e, dt)
			LANCER: _lancer(e, dt)
			BOMBER: _bomber(e, dt)
		if e.alive:
			e.pos += e.vel * dt
			if not (e.type == CHARGER and e.state == 2):
				_clamp(e)


func _clamp(e: Enemy) -> void:
	e.pos = e.pos.clamp(ARENA.position + Vector2(e.r, e.r), ARENA.end - Vector2(e.r, e.r))


func _to_player(e: Enemy) -> Vector2:
	var d := p_pos - e.pos
	return d.normalized() if d.length_squared() > 0.01 else Vector2.RIGHT


func _speed_up() -> float:
	return 1.0 + minf(0.45, wave * 0.025)


func _swarmer(e: Enemy, dt: float) -> void:
	var d := _to_player(e)
	var weave := d.orthogonal() * sin(time * 3.1 + e.seed * 6.28) * 0.45
	var want := (d + weave).normalized() * 128.0 * _speed_up()
	e.vel = e.vel.lerp(want, minf(1.0, dt * 4.5))
	if e.vel.length_squared() > 1.0:
		e.dir = e.vel.normalized()
	if alive and inv <= 0.0 and e.pos.distance_to(p_pos) < e.r + PLAYER_R - 2.0:
		_hurt(e.pos)
		_kill(e, false, false)
		return
	for o in enemies:
		if o != e and o.alive and o.exposed > 0.0 and o.spawn_t <= 0.0 and o.die_t < 0.0:
			if o.pos.distance_to(e.pos) < o.r + e.r + 4.0:
				ev("bite", {"pos": o.pos})
				_kill(o, true)


func _gunner(e: Enemy, dt: float) -> void:
	var d := _to_player(e)
	var dist := e.pos.distance_to(p_pos)
	var radial := clampf((dist - 310.0) / 120.0, -1.0, 1.0)
	var side := 1.0 if e.seed > 0.5 else -1.0
	var want := (d * radial + d.orthogonal() * side * 0.7) * 85.0
	e.vel = e.vel.lerp(want, minf(1.0, dt * 3.0))
	e.dir = d
	e.cool -= dt
	if e.cool <= 0.0:
		e.cool = maxf(1.5, 2.6 - wave * 0.05) + rng.randf() * 0.7
		var sp := 240.0 * _speed_up()
		var angles := [0.0]
		if e.spread:
			angles = [-0.26, 0.0, 0.26]
		for a in angles:
			var b := Bullet.new()
			b.vel = d.rotated(a) * sp
			b.pos = e.pos + d * (e.r + 4.0)
			b.owner = e.id
			b.birth = time
			bullets.append(b)
		ev("shot", {"pos": e.pos})


func _charger(e: Enemy, dt: float) -> void:
	match e.state:
		0:
			var d := _to_player(e)
			e.dir = d
			var dist := e.pos.distance_to(p_pos)
			e.vel = e.vel.lerp(d * (95.0 if dist > 240.0 else 0.0), minf(1.0, dt * 3.0))
			e.cool -= dt
			if e.cool <= 0.0 and dist < 460.0 and alive:
				e.state = 1
				e.t = 0.85
				ev("charge_up", {"pos": e.pos})
		1:
			e.vel = e.vel.lerp(Vector2.ZERO, minf(1.0, dt * 8.0))
			if e.t > 0.3:
				e.dir = _to_player(e)
			e.t -= dt
			if e.t <= 0.0:
				e.state = 2
				e.vel = e.dir * 1000.0
				ev("dash", {"pos": e.pos})
		2:
			e.vel = e.dir * 1000.0
			if alive and e.pos.distance_to(p_pos) < e.r + PLAYER_R + 2.0:
				_hurt(e.pos)
			for o in enemies:
				if o != e and o.alive and o.exposed > 0.0 and o.spawn_t <= 0.0 and o.die_t < 0.0:
					if o.pos.distance_to(e.pos) < o.r + e.r + 6.0:
						_kill(o, true)
			var nx := e.pos + e.vel * dt
			var inner := ARENA.grow(-e.r)
			if not inner.has_point(nx):
				e.pos = nx.clamp(inner.position, inner.end)
				e.vel = Vector2.ZERO
				e.state = 3
				e.t = 1.1
				ev("thud", {"pos": e.pos, "dir": e.dir})
		3:
			e.vel = Vector2.ZERO
			e.t -= dt
			if e.t <= 0.0:
				e.state = 0
				e.cool = 0.9 + rng.randf() * 0.8


func _lancer(e: Enemy, dt: float) -> void:
	match e.state:
		0:
			var d := _to_player(e)
			var dist := e.pos.distance_to(p_pos)
			var radial := clampf((dist - 380.0) / 150.0, -1.0, 1.0)
			e.vel = e.vel.lerp(d * radial * 60.0, minf(1.0, dt * 2.0))
			e.dir = e.dir.slerp(d, minf(1.0, dt * 3.0)).normalized()
			e.cool -= dt
			if e.cool <= 0.0 and alive:
				e.state = 1
				e.t = 1.35
				ev("laser_charge", {"pos": e.pos})
		1:
			e.vel = e.vel.lerp(Vector2.ZERO, minf(1.0, dt * 6.0))
			if e.t > 0.4:
				var ang := e.dir.angle_to(_to_player(e))
				e.dir = e.dir.rotated(clampf(ang, -1.5 * dt, 1.5 * dt))
			e.t -= dt
			if e.t <= 0.0:
				e.state = 2
				e.t = 0.26
				var bm := Beam.new()
				bm.a = e.pos + e.dir * e.r
				bm.b = ray_to_wall(e.pos, e.dir)
				bm.t = 0.26
				bm.owner = e.id
				beams.append(bm)
				ev("laser", {"a": bm.a, "b": bm.b})
		2:
			e.vel = Vector2.ZERO
			e.t -= dt
			if e.t <= 0.0:
				e.state = 0
				e.cool = 2.6 + rng.randf() * 1.2


func _bomber(e: Enemy, dt: float) -> void:
	var d := _to_player(e)
	e.dir = d
	if e.state == 0:
		e.vel = e.vel.lerp(d * 105.0 * _speed_up(), minf(1.0, dt * 3.0))
		if alive and e.pos.distance_to(p_pos) < 92.0:
			e.state = 1
			e.t = 1.05
			ev("fuse", {"pos": e.pos})
	else:
		e.vel = e.vel.lerp(Vector2.ZERO, minf(1.0, dt * 6.0))


static func ray_to_wall(from: Vector2, dir: Vector2) -> Vector2:
	var best := 4000.0
	if dir.x > 0.0001:
		best = minf(best, (ARENA.end.x - from.x) / dir.x)
	elif dir.x < -0.0001:
		best = minf(best, (ARENA.position.x - from.x) / dir.x)
	if dir.y > 0.0001:
		best = minf(best, (ARENA.end.y - from.y) / dir.y)
	elif dir.y < -0.0001:
		best = minf(best, (ARENA.position.y - from.y) / dir.y)
	return from + dir * maxf(best, 0.0)


static func seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _bullets(dt: float) -> void:
	for b in bullets:
		if not b.alive:
			continue
		b.pos += b.vel * dt
		if not ARENA.has_point(b.pos):
			b.alive = false
			ev("spark", {"pos": b.pos})
			continue
		if alive and inv <= 0.0 and b.pos.distance_to(p_pos) < PLAYER_R + 4.0:
			b.alive = false
			_hurt(b.pos - b.vel * 0.05)
			continue
		for e in enemies:
			if e.alive and e.exposed > 0.0 and e.spawn_t <= 0.0 and e.die_t < 0.0:
				if e.id == b.owner and b.birth > e.swap_time:
					continue
				if b.pos.distance_to(e.pos) < e.r + 5.0:
					b.alive = false
					_kill(e, true)
					break


func _beams(dt: float) -> void:
	var i := beams.size() - 1
	while i >= 0:
		var bm := beams[i]
		bm.t -= dt
		if alive and seg_dist(p_pos, bm.a, bm.b) < PLAYER_R + 7.0:
			_hurt(bm.a)
		for e in enemies:
			if e.alive and e.id != bm.owner and e.exposed > 0.0 and e.spawn_t <= 0.0 and e.die_t < 0.0:
				if seg_dist(e.pos, bm.a, bm.b) < e.r + 8.0:
					_kill(e, true)
		if bm.t <= 0.0:
			beams.remove_at(i)
		i -= 1


# ---------------------------------------------------------------- waves

func alive_count() -> int:
	var n := 0
	for e in enemies:
		if e.alive:
			n += 1
	return n


func _waves(dt: float) -> void:
	if intermission > 0.0:
		intermission -= dt
		if intermission <= 0.0:
			_start_wave()
		return
	wave_time += dt
	var i := 0
	while i < groups.size():
		var g: Dictionary = groups[i]
		g["t"] -= dt
		if g["t"] <= 0.0 or (alive_count() == 0 and i == 0):
			_spawn_group(g["types"])
			groups.remove_at(i)
		else:
			i += 1
	if groups.is_empty():
		var left := alive_count()
		if left == 0:
			ev("wave_clear", {"wave": wave})
			intermission = 1.5
		elif (left <= 3 and wave_time > 5.0) or wave_time > 18.0:
			intermission = 0.8


func _start_wave() -> void:
	wave += 1
	wave_time = 0.0
	if wave > 1 and wave % 5 == 1 and hp < MAX_HP:
		hp += 1
		ev("heal", {"pos": p_pos})
	ev("wave", {"wave": wave})
	groups = _compose(wave)


func _compose(w: int) -> Array:
	if w == 1:
		if tutorial:
			return [{"t": 0.0, "types": [SWARMER, SWARMER, SWARMER, SWARMER]}, {"t": 0.6, "types": [GUNNER]}]
		return [{"t": 0.0, "types": [SWARMER, SWARMER, SWARMER, SWARMER, SWARMER]}, {"t": 0.6, "types": [GUNNER, GUNNER]}]
	if w == 2:
		return [{"t": 0.0, "types": [GUNNER, GUNNER, CHARGER]}, {"t": 2.5, "types": [SWARMER, SWARMER, SWARMER, SWARMER, SWARMER, SWARMER]}]
	if w == 3:
		return [{"t": 0.0, "types": [BOMBER, BOMBER, GUNNER, GUNNER]}, {"t": 3.0, "types": [SWARMER, SWARMER, SWARMER, SWARMER, SWARMER, SWARMER]}, {"t": 6.0, "types": [CHARGER]}]
	var budget := 8.0 + w * 3.0
	var caps := {GUNNER: 2 + w / 3, CHARGER: 1 + w / 3, LANCER: (1 + w / 5) if w >= 4 else 0, BOMBER: 1 + w / 4}
	var cost := {GUNNER: 2.0, CHARGER: 3.0, LANCER: 3.5, BOMBER: 2.5}
	var specials: Array = []
	var counts := {GUNNER: 0, CHARGER: 0, LANCER: 0, BOMBER: 0}
	if w == 4:
		specials.append(LANCER)
		counts[LANCER] = 1
		budget -= 3.5
	var spend := budget * 0.62
	var guard := 0
	while spend > 1.9 and guard < 60:
		guard += 1
		var ty: int = [GUNNER, GUNNER, CHARGER, LANCER, BOMBER][rng.randi() % 5]
		if counts[ty] >= caps[ty] or cost[ty] > spend + 0.6:
			continue
		counts[ty] += 1
		specials.append(ty)
		spend -= cost[ty]
	var swarm := mini(30, int(budget * 0.38 + spend) + 3)
	var out: Array = []
	var parts := 2 if w < 7 else 3
	for p in parts:
		var types: Array = []
		for k in range(p, specials.size(), parts):
			types.append(specials[k])
		out.append({"t": p * 4.5, "types": types})
		var pack: Array = []
		for k in swarm / parts:
			pack.append(SWARMER)
		out.append({"t": p * 4.5 + 1.8, "types": pack})
	return out


func _spawn_group(types: Array) -> void:
	if types.is_empty():
		return
	var swarm_anchor := Vector2.ZERO
	var has_anchor := false
	for ty in types:
		if alive_count() >= 44:
			break
		var e := Enemy.new()
		e.id = next_id
		next_id += 1
		e.type = ty
		e.r = RADIUS[ty]
		e.seed = rng.randf()
		e.spawn_t = 0.9 + rng.randf() * 0.25
		if ty == SWARMER:
			if not has_anchor:
				swarm_anchor = _far_point(330.0, true)
				has_anchor = true
			e.pos = swarm_anchor + Vector2(rng.randf_range(-70, 70), rng.randf_range(-70, 70))
			_clamp(e)
		else:
			e.pos = _far_point(280.0, false)
		if ty != SWARMER and wave >= 6:
			e.locked = rng.randf() < minf(0.45, (wave - 5) * 0.07)
		match ty:
			GUNNER:
				e.cool = 1.2 + rng.randf() * 1.4
				e.spread = wave >= 6 and rng.randf() < minf(0.6, (wave - 5) * 0.12)
			CHARGER:
				e.cool = 0.8 + rng.randf()
			LANCER:
				e.cool = 1.0 + rng.randf() * 1.5
				e.dir = _to_player(e)
		enemies.append(e)
		ev("spawn", {"pos": e.pos, "type": ty})


func _far_point(min_d: float, edge: bool) -> Vector2:
	var best := ARENA.get_center()
	var best_d := -1.0
	for i in 14:
		var p := Vector2(rng.randf_range(ARENA.position.x + 40, ARENA.end.x - 40), rng.randf_range(ARENA.position.y + 40, ARENA.end.y - 40))
		if edge:
			match rng.randi() % 4:
				0: p.x = ARENA.position.x + 70
				1: p.x = ARENA.end.x - 70
				2: p.y = ARENA.position.y + 70
				3: p.y = ARENA.end.y - 70
		var d := p.distance_to(p_pos)
		for e in enemies:
			if e.alive and e.type != SWARMER:
				d = minf(d, e.pos.distance_to(p) * 2.5)
		if d >= min_d:
			return p
		if d > best_d:
			best_d = d
			best = p
	return best
