extends Node2D
## Draws the simulation and owns every effect: particles, rings, bolts, shake.

const Sim = preload("res://scripts/sim.gd")
const Layer = preload("res://scripts/layer.gd")

const C_PLAYER := Color(0.45, 0.95, 1.0)
const C_WHITE := Color(1, 1, 1)
const C_TYPE: Array[Color] = [
	Color(1.0, 0.28, 0.58),   # swarmer
	Color(1.0, 0.62, 0.22),   # gunner
	Color(1.0, 0.27, 0.25),   # charger
	Color(0.68, 0.45, 1.0),   # lancer
	Color(1.0, 0.88, 0.25),   # bomber
]
const C_BULLET := Color(1.0, 0.8, 0.45)
const CENTER := Vector2(640, 360)

var sim: Sim
var font: Font
var loc: RefCounted
var glow: Node2D
var top: Node2D
var blob: Texture2D
var show_hud_fx := true

var parts: Array = []        # [pos, vel, life, max, color, size, drag]
var rings: Array = []        # [pos, t, dur, r0, r1, color, width]
var ghosts: Array = []       # [pos, rot, shape, scale, t, dur, color]
var bolts: Array = []        # [a, b, t, dur, seed]
var texts: Array = []        # [pos, text, t, dur, color, size]
var shocks: Array = []       # [pos, t, dur, strength, speed]
var trauma := 0.0
var punch := 0.0
var chroma := 0.0
var flash := 0.0
var glitch := 0.0
var clock := 0.0
var rng := RandomNumberGenerator.new()
var hue := 0.55
var hue_goal := 0.55

var shapes := {}


func _ready() -> void:
	rng.randomize()
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	grad.add_point(0.35, Color(1, 1, 1, 0.32))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 128
	gt.height = 128
	blob = gt
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow = Layer.new()
	glow.material = add
	glow.show_behind_parent = true
	glow.fn = _draw_glow
	add_child(glow)
	top = Layer.new()
	top.material = add
	top.fn = _draw_top
	add_child(top)
	shapes["player"] = PackedVector2Array([Vector2(1.5, 0), Vector2(-0.9, 0.95), Vector2(-0.35, 0), Vector2(-0.9, -0.95)])
	shapes[Sim.SWARMER] = PackedVector2Array([Vector2(1.25, 0), Vector2(-0.85, 0.9), Vector2(-0.45, 0), Vector2(-0.85, -0.9)])
	shapes[Sim.GUNNER] = PackedVector2Array([Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)])
	shapes[Sim.CHARGER] = PackedVector2Array([Vector2(1.5, 0), Vector2(0.1, 0.95), Vector2(-1.1, 0.95), Vector2(-0.4, 0), Vector2(-1.1, -0.95), Vector2(0.1, -0.95)])
	var hexagon := PackedVector2Array()
	var octagon := PackedVector2Array()
	for i in 6:
		hexagon.append(Vector2.from_angle(i * TAU / 6.0))
	for i in 10:
		octagon.append(Vector2.from_angle(i * TAU / 10.0))
	shapes[Sim.LANCER] = hexagon
	shapes[Sim.BOMBER] = octagon


func reset() -> void:
	parts.clear()
	rings.clear()
	ghosts.clear()
	bolts.clear()
	texts.clear()
	shocks.clear()
	trauma = 0.0
	punch = 0.0
	chroma = 0.0
	flash = 0.0
	glitch = 0.0


# ---------------------------------------------------------------- effects

func burst(pos: Vector2, n: int, color: Color, speed: float, life: float, size: float = 2.2) -> void:
	if parts.size() > 900:
		n = n / 3
	for i in n:
		var v := Vector2.from_angle(rng.randf() * TAU) * speed * (0.25 + rng.randf() * 0.95)
		parts.append([pos, v, life * (0.5 + rng.randf() * 0.7), life, color, size * (0.6 + rng.randf() * 0.8), 3.0])


func ring(pos: Vector2, r0: float, r1: float, dur: float, color: Color, width: float = 3.0) -> void:
	rings.append([pos, 0.0, dur, r0, r1, color, width])


func shock(pos: Vector2, strength: float, dur: float = 0.55, speed: float = 0.9) -> void:
	shocks.append([pos, 0.0, dur, strength, speed])
	if shocks.size() > 6:
		shocks.pop_front()


func say(pos: Vector2, text: String, color: Color, size: int = 20, dur: float = 0.9) -> void:
	pos.x = clampf(pos.x, 110, 1170)
	pos.y = clampf(pos.y, 130, 650)
	texts.append([pos, text, 0.0, dur, color, size])


func shake(a: float) -> void:
	trauma = minf(1.0, trauma + a)


func consume(events: Array) -> void:
	for e in events:
		match e["k"]:
			"swap":
				var a: Vector2 = e["a"]
				var b: Vector2 = e["b"]
				bolts.append([a, b, 0.0, 0.28, rng.randf() * 100.0])
				ring(b, 10, 70, 0.3, C_PLAYER, 4.0)
				ring(a, 10, 90, 0.4, C_WHITE, 3.0)
				ghosts.append([a, sim.p_face.angle(), "player", 11.0, 0.0, 0.4, C_PLAYER])
				ghosts.append([b, 0.0, e["type"], Sim.RADIUS[e["type"]], 0.0, 0.4, C_TYPE[e["type"]]])
				var n := int(clampf(a.distance_to(b) / 22.0, 6, 40))
				for i in n:
					var p := a.lerp(b, float(i) / n)
					parts.append([p, Vector2.from_angle(rng.randf() * TAU) * 60.0, 0.35, 0.35, C_PLAYER, 2.0, 2.0])
				burst(b, 14, C_PLAYER, 260, 0.35)
				shock(a, 0.8)
				shock(b, 0.8)
				shake(0.22)
				chroma = maxf(chroma, 0.012)
				glitch = maxf(glitch, 0.5)
			"kill":
				var pos: Vector2 = e["pos"]
				var col: Color = C_TYPE[e["type"]]
				burst(pos, 26 if e["pts"] > 0 else 10, col, 330, 0.6)
				burst(pos, 8, C_WHITE, 180, 0.4, 3.0)
				ring(pos, 6, 46, 0.3, col, 4.0)
				if e["pts"] > 0:
					shake(0.14 + (0.1 if e["shift"] else 0.0))
					punch = maxf(punch, 0.012 + minf(0.02, e["chain"] * 0.001))
					var label := "+%d" % e["pts"]
					if e["shift"]:
						say(pos + Vector2(0, -22), loc.t("shift_kill"), C_WHITE, 15, 0.8)
						say(pos, label, C_PLAYER, 24, 0.9)
						chroma = maxf(chroma, 0.008)
					else:
						say(pos, label, col.lerp(C_WHITE, 0.4), 17, 0.7)
			"nova":
				ring(e["pos"], 12, Sim.NOVA_R, 0.26, Color(0.8, 0.95, 1.0), 5.0)
				shock(e["pos"], 0.45, 0.4, 0.7)
			"explode":
				var p2: Vector2 = e["pos"]
				ring(p2, 20, e["r"], 0.22, C_TYPE[Sim.BOMBER], 9.0)
				ring(p2, 10, e["r"] * 1.25, 0.5, C_WHITE, 3.0)
				burst(p2, 60, C_TYPE[Sim.BOMBER], 520, 0.8, 3.0)
				burst(p2, 20, C_WHITE, 300, 0.5, 3.5)
				shock(p2, 1.6, 0.7, 1.1)
				shake(0.55)
				chroma = maxf(chroma, 0.014)
			"hurt":
				flash = 1.0
				shake(0.85)
				glitch = 1.0
				chroma = maxf(chroma, 0.03)
				ring(e["pos"], 10, 230, 0.45, Color(1, 0.3, 0.35), 6.0)
				burst(e["pos"], 40, Color(1, 0.35, 0.4), 420, 0.7, 3.0)
				shock(e["pos"], 1.8, 0.8, 1.2)
			"dead":
				flash = 1.0
				shake(1.0)
				glitch = 1.0
				chroma = 0.04
				for i in 3:
					ring(e["pos"], 10, 200 + i * 160, 0.5 + i * 0.25, C_PLAYER if i != 1 else C_WHITE, 7.0 - i * 2)
				burst(e["pos"], 140, C_PLAYER, 620, 1.4, 3.2)
				burst(e["pos"], 60, C_WHITE, 380, 1.0, 3.5)
				shock(e["pos"], 2.2, 1.2, 1.3)
			"spawn":
				ring(e["pos"], 60, 8, 0.9, C_TYPE[e["type"]], 2.0)
			"arrive":
				burst(e["pos"], 6, C_TYPE[e["type"]], 120, 0.3)
			"shot":
				burst(e["pos"], 4, C_BULLET, 110, 0.2)
			"spark":
				burst(e["pos"], 4, C_BULLET, 130, 0.25)
			"dash":
				ring(e["pos"], 8, 50, 0.25, C_TYPE[Sim.CHARGER], 3.0)
			"thud":
				burst(e["pos"], 22, C_TYPE[Sim.CHARGER], 380, 0.5)
				shake(0.3)
				shock(e["pos"], 0.7, 0.4, 0.8)
			"laser":
				shake(0.3)
				chroma = maxf(chroma, 0.01)
				var a2: Vector2 = e["a"]
				var b2: Vector2 = e["b"]
				var n2 := int(a2.distance_to(b2) / 26.0)
				for i in n2:
					var p3 := a2.lerp(b2, float(i) / maxf(n2, 1))
					parts.append([p3, Vector2.from_angle(rng.randf() * TAU) * 90.0, 0.45, 0.45, C_TYPE[Sim.LANCER], 2.2, 2.0])
			"bite":
				burst(e["pos"], 8, C_TYPE[Sim.SWARMER], 200, 0.3)
			"burst":
				say(sim.p_pos + Vector2(0, -52), loc.t("burst") % e["n"], Color(1, 0.95, 0.5), 30, 1.3)
				punch = maxf(punch, 0.04)
			"heal":
				ring(e["pos"], 60, 14, 0.5, Color(0.5, 1, 0.7), 4.0)
				say(e["pos"] + Vector2(0, -40), loc.t("repair"), Color(0.5, 1, 0.7), 20, 1.4)
			"wave":
				hue_goal = fposmod(0.55 + (e["wave"] - 1) * 0.085, 1.0)
				shock(CENTER, 1.0, 1.0, 1.4)


func _process(delta: float) -> void:
	if sim == null:
		return
	clock += delta
	var fx_dt := delta * lerpf(sim.ts, 1.0, 0.25)
	trauma = maxf(0.0, trauma - delta * 1.7)
	punch = lerpf(punch, 0.0, minf(1.0, delta * 9.0))
	chroma = lerpf(chroma, 0.0, minf(1.0, delta * 6.0))
	flash = maxf(0.0, flash - delta * 2.4)
	glitch = maxf(0.0, glitch - delta * 3.5)
	var dh := fposmod(hue_goal - hue + 0.5, 1.0) - 0.5
	hue = fposmod(hue + dh * minf(1.0, delta * 1.5), 1.0)

	var i := parts.size() - 1
	while i >= 0:
		var p: Array = parts[i]
		p[2] -= fx_dt
		if p[2] <= 0.0:
			parts[i] = parts[-1]
			parts.pop_back()
		else:
			p[0] += p[1] * fx_dt
			p[1] *= maxf(0.0, 1.0 - p[6] * fx_dt)
		i -= 1
	_age(rings, 1, 2, fx_dt)
	_age(ghosts, 4, 5, fx_dt)
	_age(bolts, 2, 3, delta)
	_age(texts, 2, 3, delta)
	_age(shocks, 1, 2, delta)
	# chargers leave a trail
	for e in sim.enemies:
		if e.alive and e.type == Sim.CHARGER and e.state == 2 and sim.ts > 0.0:
			if rng.randf() < 0.7:
				ghosts.append([e.pos, e.dir.angle(), Sim.CHARGER, e.r, 0.0, 0.22, C_TYPE[Sim.CHARGER]])
	if sim.alive and sim.p_vel.length() > 120.0 and rng.randf() < 0.5:
		parts.append([sim.p_pos - sim.p_face * 8.0, -sim.p_vel * 0.15 + Vector2.from_angle(rng.randf() * TAU) * 20.0, 0.3, 0.3, C_PLAYER, 1.8, 2.0])

	var sh := trauma * trauma
	var off := Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * sh * 16.0
	var lean := (CENTER - sim.p_pos) * 0.035
	var z := 1.0 + punch + (0.02 if sim.focusing else 0.0)
	scale = Vector2(z, z)
	position = CENTER - CENTER * z + off + lean
	queue_redraw()
	glow.queue_redraw()
	top.queue_redraw()


func _age(list: Array, ti: int, di: int, dt: float) -> void:
	var i := list.size() - 1
	while i >= 0:
		list[i][ti] += dt
		if list[i][ti] >= list[i][di]:
			list.remove_at(i)
		i -= 1


func shader_points(count: int) -> Dictionary:
	# newest shocks, as uv + radius, for the background and the screen pass
	var pts: Array[Vector3] = []
	var strength: Array[float] = []
	var from := maxi(0, shocks.size() - count)
	for k in count:
		var idx := from + k
		if idx < shocks.size():
			var s: Array = shocks[idx]
			var u: float = s[1] / s[2]
			pts.append(Vector3(s[0].x / 1280.0, s[0].y / 720.0, u * s[4]))
			strength.append(s[3] * (1.0 - u) * (1.0 - u))
		else:
			pts.append(Vector3.ZERO)
			strength.append(0.0)
	return {"pts": pts, "str": strength}


# ---------------------------------------------------------------- drawing

func _poly(ci: CanvasItem, key: Variant, pos: Vector2, rot: float, size: float, fill: Color, line: Color, width: float) -> void:
	var xf := Transform2D(rot, Vector2(size, size), 0.0, pos)
	var pts: PackedVector2Array = xf * shapes[key]
	if fill.a > 0.0:
		ci.draw_colored_polygon(pts, fill)
	pts.append(pts[0])
	ci.draw_polyline(pts, line, width, true)


func _blob(ci: CanvasItem, pos: Vector2, radius: float, color: Color) -> void:
	ci.draw_texture_rect(blob, Rect2(pos - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0)), false, color)


func _dashed(ci: CanvasItem, a: Vector2, b: Vector2, color: Color, width: float, dash: float, phase: float) -> void:
	var dist := a.distance_to(b)
	if dist < 1.0:
		return
	var d := (b - a) / dist
	var x := -fposmod(phase, dash * 2.0)
	while x < dist:
		var s := maxf(x, 0.0)
		var e := minf(x + dash, dist)
		if e > s:
			ci.draw_line(a + d * s, a + d * e, color, width, true)
		x += dash * 2.0


func _draw() -> void:
	if sim == null:
		return
	var A := Sim.ARENA
	var border := Color.from_hsv(hue, 0.55, 1.0)
	draw_rect(A, Color(border, 0.75), false, 2.0)
	for c in [A.position, Vector2(A.end.x, A.position.y), A.end, Vector2(A.position.x, A.end.y)]:
		var sx := 1.0 if c.x < 640 else -1.0
		var sy := 1.0 if c.y < 360 else -1.0
		draw_line(c, c + Vector2(34 * sx, 0), border, 5.0)
		draw_line(c, c + Vector2(0, 34 * sy), border, 5.0)

	# ---- warnings
	for e in sim.enemies:
		if not e.alive or e.spawn_t > 0.0:
			continue
		match e.type:
			Sim.CHARGER:
				if e.state == 1:
					var k := 1.0 - e.t / 0.85
					var end := Sim.ray_to_wall(e.pos, e.dir)
					var locked := e.t <= 0.3
					var col := Color(1, 0.3, 0.3, 0.25 + k * 0.5) if not locked else Color(1, 0.75, 0.7, 0.9)
					draw_line(e.pos, end, Color(col, col.a * 0.25), 34.0)
					_dashed(self, e.pos, end, col, 3.0, 16.0, -clock * 120.0)
			Sim.LANCER:
				if e.state == 1:
					var k2 := 1.0 - e.t / 1.35
					var end2 := Sim.ray_to_wall(e.pos, e.dir)
					var locked2 := e.t <= 0.4
					if locked2:
						draw_line(e.pos, end2, Color(1, 0.9, 1, 0.5 + 0.5 * sin(clock * 60.0)), 3.0, true)
						draw_line(e.pos, end2, Color(0.7, 0.45, 1, 0.22), 22.0)
					else:
						draw_line(e.pos, end2, Color(0.75, 0.5, 1, 0.2 + k2 * 0.5), 1.5, true)
			Sim.BOMBER:
				if e.state == 1:
					var k3 := 1.0 - e.t / 1.05
					draw_circle(e.pos, Sim.BLAST_R, Color(1, 0.85, 0.2, 0.05 + 0.1 * k3))
					draw_arc(e.pos, Sim.BLAST_R, 0, TAU, 64, Color(1, 0.85, 0.2, 0.7), 2.0, true)
					draw_arc(e.pos, Sim.BLAST_R * k3, 0, TAU, 48, Color(1, 0.5, 0.2, 0.9), 2.5, true)
	for bl in sim.blasts:
		draw_circle(bl.pos, bl.r, Color(1, 0.9, 0.5, 0.25))

	# ---- beams
	for bm in sim.beams:
		var w := 26.0 * (bm.t / 0.26)
		draw_line(bm.a, bm.b, Color(0.7, 0.45, 1.0, 0.8), w + 10.0)
		draw_line(bm.a, bm.b, Color(1, 1, 1), maxf(w * 0.5, 2.0))

	# ---- afterimages
	for g in ghosts:
		var u: float = g[4] / g[5]
		_poly(self, g[2], g[0], g[1], g[3] * (1.0 + u * 0.5), Color(0, 0, 0, 0), Color(g[6], (1.0 - u) * 0.7), 2.0)

	# ---- enemies
	for e in sim.enemies:
		if not e.alive:
			continue
		var col: Color = C_TYPE[e.type]
		if e.spawn_t > 0.0:
			var k := clampf(1.0 - e.spawn_t / 0.9, 0.0, 1.0)
			_poly(self, e.type, e.pos, clock * 3.0, e.r * (2.2 - k * 1.2), Color(0, 0, 0, 0), Color(col, 0.2 + k * 0.5), 1.5)
			continue
		var rot := e.dir.angle()
		if e.type == Sim.GUNNER or e.type == Sim.LANCER:
			rot = e.dir.angle() if e.type == Sim.GUNNER else clock * 0.6 + e.seed * 6.0
		if e.type == Sim.BOMBER:
			rot = clock * 1.5 + e.seed * 6.0
		var pos := e.pos
		if e.daze > 0.0:
			pos += Vector2(sin(clock * 70.0 + e.seed * 9.0), cos(clock * 63.0)) * 1.8
		var line := col
		var fill := Color(col.r * 0.16, col.g * 0.16, col.b * 0.2, 0.92)
		var width := 2.6
		var exposed := e.exposed > 0.0
		if exposed:
			var blink := 0.75 + 0.25 * sin(clock * 34.0)
			line = C_WHITE
			fill = Color(blink, blink, blink, 0.85)
			width = 3.2
		if e.type == Sim.GUNNER and e.cool < 0.3 and e.daze <= 0.0:
			fill = Color(1, 0.8, 0.5, 0.9)
		if e.type == Sim.CHARGER and e.state == 3:
			line = col.darkened(0.35)
		_poly(self, e.type, pos, rot, e.r, fill, line, width)
		match e.type:
			Sim.GUNNER:
				draw_line(pos + e.dir * 4.0, pos + e.dir * (e.r + 9.0), line, 4.0, true)
			Sim.LANCER:
				var charge := 0.0
				if e.state == 1:
					charge = 1.0 - e.t / 1.35
				draw_circle(pos, 4.0 + charge * 5.0, line.lerp(C_WHITE, charge))
				draw_line(pos, pos + e.dir * (e.r + 6.0), line, 2.5, true)
			Sim.BOMBER:
				var pulse := 0.5 + 0.5 * sin(clock * (7.0 if e.state == 0 else 30.0))
				draw_circle(pos, 4.0 + pulse * 3.5, Color(1, 0.55 + pulse * 0.4, 0.3) if not exposed else Color(1, 0.4, 0.2))
			Sim.CHARGER:
				if e.state == 3:
					for s in 3:
						var a := clock * 5.0 + s * TAU / 3.0
						draw_circle(pos + Vector2(cos(a) * 16.0, sin(a) * 7.0 - 20.0), 2.2, Color(1, 1, 0.6))
		if e.locked:
			var q := e.r + 9.0
			for sx in [-1.0, 1.0]:
				for sy in [-1.0, 1.0]:
					var corner := pos + Vector2(q * sx, q * sy)
					draw_line(corner, corner - Vector2(8.0 * sx, 0), Color(col, 0.9), 2.5)
					draw_line(corner, corner - Vector2(0, 8.0 * sy), Color(col, 0.9), 2.5)
		if exposed:
			var frac := e.exposed / Sim.EXPOSE_TIME
			draw_arc(pos, e.r + 10.0, -PI / 2.0, -PI / 2.0 + TAU * frac, 32, Color(1, 1, 1, 0.9), 2.5, true)
			for s in 4:
				var a := clock * 4.0 + s * PI / 2.0
				var v := Vector2.from_angle(a)
				draw_line(pos + v * (e.r + 15.0), pos + v * (e.r + 22.0), Color(1, 1, 1, 0.8), 2.0, true)

	# ---- bullets
	for b in sim.bullets:
		var d := b.vel.normalized()
		draw_line(b.pos - d * 12.0, b.pos, Color(C_BULLET, 0.55), 3.0, true)
		draw_circle(b.pos, 4.5, C_BULLET)
		draw_circle(b.pos, 2.2, C_WHITE)

	# ---- focus: link, reticle, preview of the trade
	if sim.focusing and sim.target != null and sim.target.alive:
		var tg := sim.target
		_dashed(self, sim.p_pos, tg.pos, Color(C_PLAYER, 0.95), 2.5, 9.0, -clock * 90.0)
		var rr := tg.r + 13.0 + sin(clock * 16.0) * 2.0
		for s in 4:
			var a := s * PI / 2.0 + PI / 4.0 + clock * 1.2
			draw_arc(tg.pos, rr, a - 0.42, a + 0.42, 10, C_PLAYER, 3.5, true)
		_poly(self, "player", tg.pos, sim.p_face.angle(), 9.0, Color(0, 0, 0, 0), Color(C_PLAYER, 0.55 + 0.3 * sin(clock * 20.0)), 1.6)
		_poly(self, tg.type, sim.p_pos + Vector2(0, 0), tg.dir.angle(), tg.r * 1.35, Color(0, 0, 0, 0), Color(1, 1, 1, 0.35), 1.4)

	# ---- player
	if sim.alive:
		var vis := sim.inv <= 0.2 or fposmod(clock * 14.0, 1.0) < 0.6
		if vis:
			_poly(self, "player", sim.p_pos, sim.p_face.angle(), 11.0, Color(0.05, 0.2, 0.25, 0.95), C_PLAYER, 2.8)
			draw_circle(sim.p_pos, 2.6, C_WHITE)
		if sim.focus < 0.999 or sim.focusing:
			var low := sim.focus < Sim.FOCUS_MIN_COST * 2.0
			var gc := Color(1, 0.35, 0.4) if low else C_PLAYER
			draw_arc(sim.p_pos, 24.0, 0, TAU, 40, Color(gc, 0.18), 3.0, true)
			if sim.focus > 0.01:
				draw_arc(sim.p_pos, 24.0, -PI / 2.0, -PI / 2.0 + TAU * sim.focus, 40, Color(gc, 0.95), 3.0, true)

	# ---- rings
	for r in rings:
		var u: float = r[1] / r[2]
		var eased := 1.0 - (1.0 - u) * (1.0 - u)
		draw_arc(r[0], lerpf(r[3], r[4], eased), 0, TAU, 48, Color(r[5], 1.0 - u), maxf(r[6] * (1.0 - u), 0.6), true)

	# ---- floating text
	if font != null:
		for t in texts:
			var u: float = t[2] / t[3]
			var pop := 1.0 + maxf(0.0, 0.12 - u) * 4.0
			var size := int(t[5] * pop)
			var pos2: Vector2 = t[0] + Vector2(0, -38.0 * (1.0 - (1.0 - u) * (1.0 - u)))
			var w := font.get_string_size(t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			var alpha := clampf((1.0 - u) * 3.0, 0.0, 1.0)
			draw_string_outline(font, pos2 - Vector2(w / 2.0, 0), t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5, Color(0.02, 0.03, 0.06, alpha * 0.85))
			draw_string(font, pos2 - Vector2(w / 2.0, 0), t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(t[4], alpha))


func _draw_glow(ci: CanvasItem) -> void:
	if sim == null:
		return
	for e in sim.enemies:
		if not e.alive or e.spawn_t > 0.0:
			continue
		var c: Color = C_TYPE[e.type]
		if e.exposed > 0.0:
			_blob(ci, e.pos, e.r * 4.2, Color(1, 1, 1, 0.3))
		else:
			_blob(ci, e.pos, e.r * 3.4, Color(c, 0.32))
	for b in sim.bullets:
		_blob(ci, b.pos, 18.0, Color(C_BULLET, 0.5))
	if sim.alive:
		_blob(ci, sim.p_pos, 46.0 + (20.0 if sim.focusing else 0.0), Color(C_PLAYER, 0.5))
	for bm in sim.beams:
		var n := int(bm.a.distance_to(bm.b) / 40.0)
		for i in n + 1:
			_blob(ci, bm.a.lerp(bm.b, float(i) / maxf(n, 1)), 46.0, Color(0.7, 0.45, 1.0, 0.4))


func _draw_top(ci: CanvasItem) -> void:
	if sim == null:
		return
	for p in parts:
		var k: float = p[2] / p[3]
		var c := Color(p[4], k)
		var tail: Vector2 = p[0] - p[1] * 0.035
		ci.draw_line(tail, p[0], c, p[5] * (0.4 + k * 0.6), true)
	for b in bolts:
		var u: float = b[2] / b[3]
		var a: Vector2 = b[0]
		var e: Vector2 = b[1]
		var n := int(clampf(a.distance_to(e) / 34.0, 3, 28))
		var side := (e - a).normalized().orthogonal()
		for pass_i in 2:
			var pts := PackedVector2Array()
			for i in n + 1:
				var f := float(i) / n
				var jitter := sin(f * 37.0 + b[4] + pass_i * 5.0 + floorf(u * 6.0) * 13.0) * 13.0 * sin(PI * f)
				pts.append(a.lerp(e, f) + side * jitter)
			ci.draw_polyline(pts, Color(C_PLAYER if pass_i == 0 else C_WHITE, (1.0 - u)), (6.0 if pass_i == 0 else 2.5) * (1.0 - u * 0.6), true)
	for r in rings:
		var u2: float = r[1] / r[2]
		_blob(ci, r[0], lerpf(r[3], r[4], u2) * 1.3, Color(r[5], (1.0 - u2) * 0.16))
