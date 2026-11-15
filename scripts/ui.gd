extends Control
## All screens and the HUD, drawn by hand so every line can animate.

const Sim = preload("res://scripts/sim.gd")

const CYAN := Color(0.45, 0.95, 1.0)
const WHITE := Color(1, 1, 1)
const DIMC := Color(0.62, 0.7, 0.85)
const PINK := Color(1.0, 0.28, 0.58)
const GOLD := Color(1.0, 0.9, 0.45)
const INK := Color(0.02, 0.03, 0.06)

var main: Node
var view: Node2D
var font: Font
var wide: FontVariation
var record := false           # tools: collect text rectangles
var rects: Array = []
var clock := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	wide = FontVariation.new()
	wide.base_font = font
	wide.spacing_glyph = 5


func _process(delta: float) -> void:
	clock += delta
	queue_redraw()


## align: 0 left, 1 centre, 2 right. Returns the width.
func txt(text: String, pos: Vector2, size: int, color: Color, align: int = 0, spaced: bool = false, outline: int = 0) -> float:
	var f: Font = wide if spaced else font
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var x := pos.x
	if align == 1:
		x -= w / 2.0
	elif align == 2:
		x -= w
	if outline > 0:
		draw_string_outline(f, Vector2(x, pos.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Color(INK, color.a * 0.9))
	draw_string(f, Vector2(x, pos.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
	if record:
		rects.append([Rect2(x, pos.y - size, w, size * 1.3), text])
	return w


func para(text: String, pos: Vector2, width: float, size: int, color: Color, center: bool = false) -> void:
	var al := HORIZONTAL_ALIGNMENT_CENTER if center else HORIZONTAL_ALIGNMENT_LEFT
	draw_multiline_string(font, pos, text, al, width, size, -1, color)
	if record:
		var sz := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, size)
		rects.append([Rect2(pos.x, pos.y - size, width, sz.y), text])


func T(key: String) -> String:
	return main.loc.t(key)


func _draw() -> void:
	rects.clear()
	match main.state:
		main.S.BOOT: _boot()
		main.S.TITLE: _title()
		main.S.HOWTO: _howto()
		main.S.PLAY:
			_hud()
		main.S.PAUSE:
			_hud()
			_pause()
		main.S.RESULT:
			_result()
		main.S.RANKING:
			_ranking()
	if main.name_open:
		_name_modal()


# ---------------------------------------------------------------- boot

func _boot() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color(INK, 1.0))
	_logo(Vector2(640, 330), 84, 0.0)
	txt(T("loading"), Vector2(640, 420), 16, DIMC, 1, true)
	var w := 320.0
	draw_rect(Rect2(640 - w / 2, 440, w, 4), Color(DIMC, 0.25))
	draw_rect(Rect2(640 - w / 2, 440, w * main.boot_p, 4), CYAN)


func _logo(c: Vector2, size: int, t: float) -> void:
	var a := "COUNTER"
	var b := "SHIFT"
	var wa := wide.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var wb := wide.get_string_size(b, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var gap := size * 0.08
	var x0 := c.x - (wa + wb + gap) / 2.0
	# every few seconds the two halves trade places, then trade back
	var cyc := fposmod(t, 6.0)
	var k := 0.0
	if cyc > 3.4 and cyc <= 3.75:
		k = (cyc - 3.4) / 0.35
	elif cyc > 3.75 and cyc <= 5.0:
		k = 1.0
	elif cyc > 5.0 and cyc <= 5.35:
		k = 1.0 - (cyc - 5.0) / 0.35
	k = k * k * (3.0 - 2.0 * k)
	var arc := sin(k * PI) * size * 0.5
	var ax := lerpf(x0, x0 + wb + gap, k)
	var bx := lerpf(x0 + wa + gap, x0, k)
	var moving := k > 0.001 and k < 0.999
	var split := 3.0 + (9.0 if moving else 0.0) + sin(t * 2.0) * 1.0
	var cols_a := [Color(1, 0.2, 0.4, 0.75), Color(0.3, 0.9, 1.0, 0.75), WHITE]
	var cols_b := [Color(1, 0.2, 0.4, 0.75), Color(0.3, 0.9, 1.0, 0.75), CYAN]
	var offs := [-split, split, 0.0]
	for pass_i in 3:
		var off := Vector2(offs[pass_i], 0)
		draw_string(wide, Vector2(ax, c.y - arc) + off, a, HORIZONTAL_ALIGNMENT_LEFT, -1, size, cols_a[pass_i])
		draw_string(wide, Vector2(bx, c.y + arc) + off, b, HORIZONTAL_ALIGNMENT_LEFT, -1, size, cols_b[pass_i])
	if record:
		rects.append([Rect2(x0, c.y - size, wa + wb + gap, size * 1.3), "logo"])


# ---------------------------------------------------------------- title

func _menu(items: Array, idx: int, top: float, gap: float, size: int) -> void:
	for i in items.size():
		var y := top + i * gap
		var sel := i == idx
		var col := CYAN if sel else DIMC
		var s: String = items[i]
		var w := txt(s, Vector2(640, y), size, col, 1, false, 6)
		if sel:
			var bob := sin(clock * 6.0) * 3.0
			view._poly(self, "player", Vector2(640 - w / 2 - 30 - bob, y - size * 0.34), 0.0, 9.0, Color(CYAN, 0.25), CYAN, 2.0)
			view._poly(self, "player", Vector2(640 + w / 2 + 30 + bob, y - size * 0.34), PI, 9.0, Color(CYAN, 0.25), CYAN, 2.0)


func _title() -> void:
	var t: float = main.state_t
	var fade := clampf(t * 1.5, 0.0, 1.0)
	draw_rect(Rect2(0, 0, 1280, 720), Color(INK, 0.38))
	draw_rect(Rect2(0, 150, 1280, 430), Color(INK, 0.5))
	draw_line(Vector2(0, 150), Vector2(1280, 150), Color(CYAN, 0.35), 1.5)
	draw_line(Vector2(0, 580), Vector2(1280, 580), Color(CYAN, 0.35), 1.5)
	_logo(Vector2(640, 268), 98, t)
	txt(T("tagline"), Vector2(640, 318), 21, Color(WHITE, fade), 1, true)
	var vol := ""
	for i in 10:
		vol += "■" if i < int(round(main.volume * 10.0)) else "□"
	var items := [T("menu_start"), T("menu_how"), T("menu_rank"), "%s   %s" % [T("menu_lang"), main.loc.LANG_NAMES[main.loc.lang]], "%s   %s" % [T("menu_vol"), vol]]
	if main.can_fullscreen:
		items.append("%s   %s" % [T("menu_full"), T("on") if main.is_fullscreen() else T("off")])
	_menu(items, main.menu_idx, 372, 38, 24)
	txt(T("nav"), Vector2(640, 622), 15, DIMC, 1)
	if main.best > 0:
		txt("%s  %s" % [T("best"), _num(main.best)], Vector2(64, 686), 18, GOLD, 0, true)
	txt("v1.0", Vector2(1216, 686), 14, Color(DIMC, 0.6), 2)
	if fposmod(clock, 1.6) < 1.1:
		txt(T("demo"), Vector2(1216, 60), 15, Color(DIMC, 0.9), 2, true)


static func _num(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


# ---------------------------------------------------------------- how to play

func _howto() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color(INK, 0.86))
	txt(T("how_title"), Vector2(640, 70), 34, CYAN, 1, true)
	var cw := 278.0
	for i in 4:
		var x := 64.0 + i * (cw + 14.0)
		var r := Rect2(x, 100, cw, 262)
		draw_rect(r, Color(0.06, 0.09, 0.16, 0.95))
		draw_rect(r, Color(CYAN, 0.35), false, 1.5)
		txt(str(i + 1), Vector2(x + 14, 132), 20, Color(CYAN, 0.7))
		var c := Vector2(x + cw / 2.0, 172)
		_diagram(i, c)
		txt(T("how%d_h" % (i + 1)), Vector2(x + cw / 2.0, 258), 22, WHITE, 1, true)
		para(T("how%d_b" % (i + 1)), Vector2(x + 14, 288), cw - 28, 15, DIMC, true)
	var ew := 236.0
	for i in 5:
		var x := 50.0 + i * ew
		var c := Vector2(x + 30, 426)
		var col: Color = view.C_TYPE[i]
		view._poly(self, i, c, -PI / 2.0 if i != 1 else PI / 4.0, 15.0, Color(col.r * 0.16, col.g * 0.16, col.b * 0.2), col, 2.4)
		txt(T("en%d" % i), Vector2(x + 58, 432), 17, col)
		para(T("en%d_b" % i), Vector2(x + 12, 472), ew - 24, 14, DIMC)
	draw_line(Vector2(64, 392), Vector2(1216, 392), Color(CYAN, 0.25), 1.0)
	draw_line(Vector2(64, 560), Vector2(1216, 560), Color(CYAN, 0.25), 1.0)
	txt(T("how_note"), Vector2(640, 606), 16, WHITE, 1)
	txt(T("how_back"), Vector2(640, 668), 16, CYAN if fposmod(clock, 1.2) < 0.8 else DIMC, 1)


func _diagram(i: int, c: Vector2) -> void:
	var t := clock
	var en: Color = view.C_TYPE[1]
	match i:
		0:
			var d: Vector2 = [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP][int(t * 1.2) % 4]
			var p := c + d * 26.0 * fposmod(t * 1.2, 1.0)
			view._poly(self, "player", p, d.angle(), 12.0, Color(0.05, 0.2, 0.25), CYAN, 2.5)
			for k in 4:
				var v := Vector2.from_angle(k * PI / 2.0)
				draw_line(c + v * 50.0, c + v * 62.0, Color(DIMC, 0.6), 2.0)
		1:
			var a := c + Vector2(-80, 14)
			var b := c + Vector2(78, -18)
			view._poly(self, "player", a, 0.0, 12.0, Color(0.05, 0.2, 0.25), CYAN, 2.5)
			view._poly(self, 1, b, PI / 4.0, 14.0, Color(en.r * 0.16, en.g * 0.16, en.b * 0.2), en, 2.4)
			view._dashed(self, a, b, CYAN, 2.0, 8.0, -t * 60.0)
			draw_arc(b, 26.0 + sin(t * 8.0) * 2.0, 0, TAU, 24, CYAN, 2.0, true)
			draw_arc(a, 22.0, -PI / 2.0, -PI / 2.0 + TAU * (1.0 - fposmod(t * 0.4, 1.0)), 24, CYAN, 2.5, true)
		2:
			var k := fposmod(t * 0.7, 1.0)
			var sw := k > 0.5
			var a := c + Vector2(-80, 14)
			var b := c + Vector2(78, -18)
			view._poly(self, "player", b if sw else a, 0.0, 12.0, Color(0.05, 0.2, 0.25), CYAN, 2.5)
			var fill := Color(1, 1, 1, 0.85) if sw else Color(en.r * 0.16, en.g * 0.16, en.b * 0.2)
			view._poly(self, 1, a if sw else b, PI / 4.0, 14.0, fill, WHITE if sw else en, 2.4)
			if sw and k < 0.75:
				var u := (k - 0.5) / 0.25
				draw_line(a, b, Color(CYAN, 1.0 - u), 4.0 * (1.0 - u), true)
				draw_arc(a, 10 + u * 34.0, 0, TAU, 24, Color(WHITE, 1.0 - u), 2.0, true)
				draw_arc(b, 10 + u * 34.0, 0, TAU, 24, Color(CYAN, 1.0 - u), 2.0, true)
		3:
			var k := fposmod(t * 0.6, 1.0)
			var mid := c + Vector2(0, 4)
			var pk: Color = view.C_TYPE[0]
			if k < 0.7:
				view._poly(self, 1, mid, PI / 4.0, 14.0, Color(1, 1, 1, 0.85), WHITE, 2.6)
				draw_arc(mid, 26.0, -PI / 2.0, -PI / 2.0 + TAU * (1.0 - k / 0.7), 24, WHITE, 2.0, true)
				for s in 3:
					var ang := s * TAU / 3.0 + 0.4
					var from := mid + Vector2.from_angle(ang) * 92.0
					var p := from.lerp(mid, k / 0.7)
					view._poly(self, 0, p, (mid - from).angle(), 9.0, Color(pk.r * 0.16, pk.g * 0.16, pk.b * 0.2), pk, 2.0)
			else:
				var u := (k - 0.7) / 0.3
				draw_arc(mid, 12.0 + u * 70.0, 0, TAU, 32, Color(0.8, 0.95, 1.0, 1.0 - u), 5.0 * (1.0 - u), true)
				for s in 10:
					var v := Vector2.from_angle(s * TAU / 10.0 + 0.2)
					draw_line(mid + v * (10.0 + u * 60.0), mid + v * (22.0 + u * 78.0), Color(pk if s % 2 == 0 else WHITE, 1.0 - u), 2.5)


# ---------------------------------------------------------------- hud

func _hud() -> void:
	var sim: Sim = main.sim
	if sim == null:
		return
	txt(T("score"), Vector2(64, 30), 14, DIMC, 0, true)
	var pop: float = main.score_pop
	txt(_num(main.shown_score), Vector2(64, 74), 38 + int(pop * 8.0), WHITE.lerp(CYAN, pop), 0, true)
	if main.best > 0:
		txt("%s  %s" % [T("best"), _num(maxi(main.best, sim.score))], Vector2(64, 30) + Vector2(110, 0), 14, Color(GOLD, 0.85), 0, true)
	txt(T("wave"), Vector2(1216, 30), 14, DIMC, 2, true)
	txt(str(maxi(sim.wave, 1)), Vector2(1216, 74), 38, WHITE, 2, true)
	for i in Sim.MAX_HP:
		var c := Vector2(1040 + i * 34, 56)
		var on := i < sim.hp
		var col := CYAN if on else Color(DIMC, 0.35)
		if on and sim.hp == 1:
			col = Color(1, 0.35, 0.4).lerp(WHITE, 0.5 + 0.5 * sin(clock * 10.0))
		view._poly(self, "player", c, -PI / 2.0, 11.0, Color(col, 0.3 if on else 0.0), col, 2.2)
	if sim.mult > 1 or sim.chain > 0:
		var k := clampf(sim.chain_t / Sim.CHAIN_WINDOW, 0.0, 1.0)
		var mc := GOLD.lerp(PINK, clampf((sim.mult - 1) / 8.0, 0.0, 1.0))
		txt("×%d" % sim.mult, Vector2(640, 62), 40 + int(main.mult_pop * 14.0), mc, 1)
		draw_rect(Rect2(560, 72, 160, 4), Color(DIMC, 0.25))
		draw_rect(Rect2(640 - 80 * k, 72, 160 * k, 4), mc)
		txt("%s %d" % [T("chain"), sim.chain], Vector2(640, 22), 13, DIMC, 1, true)
	# banner
	if main.banner_t > 0.0:
		var u: float = 1.0 - main.banner_t / main.banner_dur
		var alpha := clampf(minf(u * 8.0, (1.0 - u) * 3.0), 0.0, 1.0)
		var size := int(main.banner_size * (1.0 + maxf(0.0, 0.15 - u) * 2.0))
		txt(main.banner, Vector2(640, 250), size, Color(main.banner_col, alpha), 1, true, 10)
		var lw := 260.0 * clampf(u * 4.0, 0.0, 1.0)
		draw_line(Vector2(640 - lw, 270), Vector2(640 + lw, 270), Color(main.banner_col, alpha * 0.7), 2.0)
	# hint
	if main.hint != "":
		var s := T(main.hint)
		var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 21).x
		var a := clampf(main.hint_t * 3.0, 0.0, 1.0)
		draw_rect(Rect2(640 - w / 2 - 22, 672, w + 44, 40), Color(INK, 0.85 * a))
		draw_rect(Rect2(640 - w / 2 - 22, 672, w + 44, 40), Color(CYAN, 0.6 * a), false, 1.5)
		txt(s, Vector2(640, 700), 21, Color(WHITE, a), 1)


# ---------------------------------------------------------------- pause

func _pause() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color(INK, 0.72))
	txt(T("paused"), Vector2(640, 270), 54, WHITE, 1, true)
	_menu([T("resume"), T("retry"), T("to_title")], main.menu_idx, 360, 50, 28)
	txt(T("how_note"), Vector2(640, 600), 15, DIMC, 1)


# ---------------------------------------------------------------- result

func _result() -> void:
	var r: Dictionary = main.result
	var t: float = main.state_t
	var a := clampf((t - 0.9) * 1.6, 0.0, 1.0)
	draw_rect(Rect2(0, 0, 1280, 720), Color(INK, 0.8 * a))
	if a <= 0.0:
		return
	txt(T("over"), Vector2(640, 118), 50, Color(WHITE, a), 1, true)
	draw_line(Vector2(640 - 300 * a, 140), Vector2(640 + 300 * a, 140), Color(CYAN, 0.6), 2.0)
	var k := clampf((t - 1.4) / 1.3, 0.0, 1.0)
	k = 1.0 - pow(1.0 - k, 3.0)
	var shown := int(r["score"] * k)
	txt(T("score"), Vector2(380, 196), 16, DIMC, 1, true)
	txt(_num(shown), Vector2(380, 276), 76, WHITE if k < 1.0 else CYAN, 1, true)
	if r["record"] and k >= 1.0:
		if fposmod(clock, 0.7) < 0.5:
			txt("★ %s ★" % T("new_record"), Vector2(380, 318), 22, GOLD, 1, true)
	else:
		txt("%s  %s" % [T("best"), _num(r["best"])], Vector2(380, 318), 18, Color(GOLD, 0.9), 1, true)
	var rows := [
		["r_wave", str(r["wave"])],
		["r_time", "%d:%02d" % [int(r["time"]) / 60, int(r["time"]) % 60]],
		["r_kills", str(r["kills"])],
		["r_shift", str(r["shift_kills"])],
		["r_chain", str(r["max_chain"])],
		["r_burst", str(r["best_burst"])],
	]
	for i in rows.size():
		var ra := clampf((t - 1.6 - i * 0.12) * 4.0, 0.0, 1.0)
		var y := 380.0 + i * 36.0
		txt(T(rows[i][0]), Vector2(210 - (1.0 - ra) * 20.0, y), 18, Color(DIMC, ra))
		txt(rows[i][1], Vector2(550, y), 22, Color(WHITE, ra), 2, true)
		draw_line(Vector2(210, y + 10), Vector2(550, y + 10), Color(DIMC, 0.18 * ra), 1.0)
	# rank
	var rk := clampf((t - 2.9) * 3.0, 0.0, 1.0)
	if rk > 0.0:
		var rc: Color = [DIMC, Color(0.6, 0.9, 0.7), CYAN, PINK, GOLD][r["rank_i"]]
		var c := Vector2(900, 360)
		var size := int(190 * (1.0 + (1.0 - rk) * 1.2))
		draw_arc(c, 150.0, 0, TAU, 64, Color(rc, 0.5 * rk), 3.0, true)
		draw_arc(c, 164.0, clock * 0.6, clock * 0.6 + PI * 1.2, 48, Color(rc, 0.8 * rk), 2.0, true)
		txt(T("rank"), Vector2(900, 236), 16, Color(DIMC, rk), 1, true)
		var fw := font.get_string_size(r["rank"], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		draw_string(font, Vector2(900 - fw / 2.0 + 4, 360 + size * 0.36 + 4), r["rank"], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(rc.darkened(0.6), rk))
		draw_string(font, Vector2(900 - fw / 2.0, 360 + size * 0.36), r["rank"], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(rc, rk))
		if r["next"] > 0:
			txt("NEXT  %s" % _num(r["next"]), Vector2(900, 548), 15, Color(DIMC, rk), 1, true)
	if t > 3.0:
		_online_strip(clampf((t - 3.0) * 3.0, 0.0, 1.0))
	if t > 3.2:
		txt(T("tip%d" % r["tip"]), Vector2(640, 648), 16, Color(WHITE, 0.85), 1)
		txt(T("r_nav"), Vector2(640, 692), 16, CYAN if fposmod(clock, 1.2) < 0.8 else DIMC, 1, true)


# ---------------------------------------------------------------- online

func _spinner(c: Vector2, radius: float, col: Color) -> void:
	draw_arc(c, radius, 0, TAU, 24, Color(col, 0.2), 2.5, true)
	draw_arc(c, radius, clock * 6.0, clock * 6.0 + PI * 0.7, 12, col, 2.5, true)


func _why(reason: String) -> String:
	match reason:
		"too_fast", "too_slow", "run_not_started", "run_unknown":
			return T("why_timing")
		"score_mismatch", "replay_invalid", "seed_mismatch", "duration_mismatch", "replay_duration", "replay_frame_rate":
			return T("why_mismatch")
		"build_mismatch", "replay_format":
			return T("why_build")
		"unverifiable":
			return T("why_env")
		"rate_limited":
			return T("why_rate")
		"bad_name":
			return T("why_name")
		"replay_too_large":
			return T("why_long")
	return T("why_other")


## One line under the result: what happened to this run online.
func _online_strip(a: float) -> void:
	var o: Node = main.online
	var st: String = o.sub.get("state", "none")
	if st == "none":
		return
	var text := ""
	var col := DIMC
	var busy := false
	match st:
		"unranked":
			text = T("on_offline")
		"need_name":
			text = T("on_need_name")
			col = CYAN if fposmod(clock, 1.0) < 0.7 else WHITE
		"sending":
			text = T("on_sending")
			busy = true
		"verifying":
			text = T("on_verifying") % o.sub.get("rank", 0)
			busy = true
		"queued":
			text = T("on_queued")
		"verified":
			text = "%s     %s" % [T("on_verified") % o.sub.get("rank", 0), T("on_newbest")]
			col = GOLD
		"not_best":
			text = T("on_notbest") % _num(o.best_score)
		"error":
			text = T("on_error")
			col = Color(1, 0.5, 0.55)
		"rejected":
			text = T("on_rejected") % _why(o.sub.get("reason", ""))
			col = Color(1, 0.5, 0.55)
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x + (34.0 if busy else 0.0)
	var r := Rect2(640 - w / 2 - 20, 588, w + 40, 34)
	draw_rect(r, Color(0.05, 0.08, 0.15, 0.9 * a))
	draw_rect(r, Color(col, 0.55 * a), false, 1.5)
	if st == "verified":
		var glow := 0.5 + 0.5 * sin(clock * 5.0)
		draw_rect(r.grow(3.0), Color(GOLD, 0.25 * glow * a), false, 2.0)
	if busy:
		_spinner(Vector2(640 - w / 2 + 6, 605), 8.0, CYAN)
	txt(text, Vector2(640 + (17.0 if busy else 0.0), 611), 17, Color(col, a), 1)


func _date(ms: int) -> String:
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	var d := Time.get_datetime_dict_from_unix_time(int(ms / 1000) + bias * 60)
	return "%04d/%02d/%02d" % [d["year"], d["month"], d["day"]]


func _ranking() -> void:
	var o: Node = main.online
	var t: float = main.state_t
	draw_rect(Rect2(0, 0, 1280, 720), Color(INK, 0.88))
	txt(T("rk_title"), Vector2(640, 64), 34, CYAN, 1, true)
	draw_line(Vector2(64, 86), Vector2(1216, 86), Color(CYAN, 0.3), 1.0)

	# ---- table
	var left := 64.0
	var right := 872.0
	var top := 144.0
	var row_h := 38.0
	var rows_vis := 12
	txt(T("rk_rank"), Vector2(left + 66, 122), 13, DIMC, 2, true)
	txt(T("rk_name"), Vector2(left + 100, 122), 13, DIMC, 0, true)
	txt(T("score"), Vector2(left + 560, 122), 13, DIMC, 2, true)
	txt(T("wave"), Vector2(left + 660, 122), 13, DIMC, 2, true)
	txt(T("rk_date"), Vector2(right - 12, 122), 13, DIMC, 2, true)
	draw_line(Vector2(left, 132), Vector2(right, 132), Color(DIMC, 0.3), 1.0)
	var bottom := top + rows_vis * row_h
	if o.board_state == "ok" or not o.board.is_empty():
		var age: float = Time.get_ticks_msec() / 1000.0 - o.board_loaded_at
		for i in o.board.size():
			var y: float = top + (i - main.rank_scroll) * row_h
			if y < top - row_h * 0.6 or y > bottom - row_h * 0.4:
				continue
			var e: Dictionary = o.board[i]
			var edge := clampf(minf((y - (top - row_h * 0.6)) / (row_h * 0.6), (bottom - row_h * 0.4 - y) / (row_h * 0.6)), 0.0, 1.0)
			var a := edge * clampf((age - i * 0.018) * 5.0, 0.0, 1.0)
			var slide := (1.0 - clampf((age - i * 0.018) * 5.0, 0.0, 1.0)) * 24.0
			var base_y := y + 26.0
			var rank: int = e["rank"]
			var rc := WHITE
			if rank == 1:
				rc = GOLD
			elif rank == 2:
				rc = CYAN
			elif rank == 3:
				rc = PINK
			if e["me"]:
				draw_rect(Rect2(left, y + 2, right - left, row_h - 4), Color(CYAN, 0.13 * a))
				draw_rect(Rect2(left, y + 2, 4, row_h - 4), Color(CYAN, a))
				view._poly(self, "player", Vector2(left + 18, y + row_h / 2.0), 0.0, 7.0, Color(CYAN, 0.3 * a), Color(CYAN, a), 1.8)
			elif rank <= 3:
				draw_rect(Rect2(left, y + 2, right - left, row_h - 4), Color(rc, 0.06 * a))
			txt(str(rank), Vector2(left + 66 + slide, base_y), 20 if rank > 3 else 22, Color(rc, a), 2)
			txt(e["name"], Vector2(left + 100 + slide, base_y), 19, Color(WHITE if not e["me"] else CYAN, a))
			txt(_num(e["score"]), Vector2(left + 560 + slide, base_y), 20, Color(rc if rank <= 3 else WHITE, a), 2)
			txt(str(e["wave"]), Vector2(left + 660 + slide, base_y), 18, Color(DIMC, a), 2)
			txt(_date(e["at"]), Vector2(right - 12, base_y), 14, Color(DIMC, a * 0.9), 2)
			draw_line(Vector2(left, y + row_h), Vector2(right, y + row_h), Color(DIMC, 0.1 * a), 1.0)
		if o.board.size() > rows_vis:
			var track := Rect2(right + 8, top, 3, bottom - top)
			draw_rect(track, Color(DIMC, 0.15))
			var frac: float = float(rows_vis) / float(o.board.size())
			var pos: float = main.rank_scroll / maxf(1.0, o.board.size() - rows_vis)
			draw_rect(Rect2(track.position.x, top + (track.size.y * (1.0 - frac)) * pos, 3, track.size.y * frac), CYAN)
	var mid := Vector2((left + right) / 2.0, 360)
	if not o.enabled:
		txt(T("rk_off"), mid, 19, DIMC, 1)
	elif o.board_state == "loading" and o.board.is_empty():
		_spinner(mid + Vector2(0, -44), 18.0, CYAN)
		txt(T("rk_loading"), mid, 16, DIMC, 1, true)
	elif o.board_state == "error" and o.board.is_empty():
		txt(T("rk_error"), mid, 19, Color(1, 0.5, 0.55), 1)
		txt(T("rk_retry"), mid + Vector2(0, 40), 17, CYAN if fposmod(clock, 1.2) < 0.8 else DIMC, 1, true)
	elif o.board_state == "ok" and o.board.is_empty():
		txt(T("rk_empty"), mid, 19, DIMC, 1)

	# ---- your record
	var card := Rect2(912, 104, 304, 496)
	draw_rect(card, Color(0.05, 0.08, 0.15, 0.95))
	draw_rect(card, Color(CYAN, 0.35), false, 1.5)
	var cx := card.position.x + card.size.x / 2.0
	txt(T("rk_you"), Vector2(cx, 138), 14, DIMC, 1, true)
	var nm: String = o.player_name
	txt(nm if nm != "" else T("rk_noname"), Vector2(cx, 182), 24, CYAN if nm != "" else Color(DIMC, 0.7), 1)
	draw_line(Vector2(card.position.x + 24, 204), Vector2(card.end.x - 24, 204), Color(CYAN, 0.25), 1.0)
	if not o.me.is_empty():
		var rank: int = o.me["rank"]
		txt(T("rk_world"), Vector2(cx, 240), 14, DIMC, 1, true)
		var pulse := 1.0 + maxf(0.0, 0.25 - t) * 1.2
		txt("#%d" % rank, Vector2(cx, 318), int(64 * pulse), GOLD if rank <= 3 else WHITE, 1)
		txt(T("rk_of") % _num(o.board_total), Vector2(cx, 350), 15, DIMC, 1)
		if rank > 100:
			txt(T("rk_out"), Vector2(cx, 378), 13, Color(PINK, 0.9), 1, true)
		txt(T("rk_best"), Vector2(cx, 424), 14, DIMC, 1, true)
		txt(_num(o.me["score"]), Vector2(cx, 468), 34, CYAN, 1)
		txt("%s %d      %s" % [T("wave"), o.me["wave"], _date(o.me["at"])], Vector2(cx, 500), 14, DIMC, 1)
	elif o.enabled:
		para(T("rk_none"), Vector2(card.position.x + 24, 300), card.size.x - 48, 16, DIMC, true)
	if o.pending > 0:
		_spinner(Vector2(card.position.x + 34, 548), 7.0, GOLD)
		para(T("rk_pending"), Vector2(card.position.x + 52, 553), card.size.x - 70, 13, GOLD)
	# ---- status
	if o.board_state == "loading" and not o.board.is_empty():
		_spinner(Vector2(left + 10, 626), 7.0, CYAN)
		txt(T("rk_loading"), Vector2(left + 28, 631), 13, DIMC, 0, true)
	elif o.board_state == "error" and not o.board.is_empty():
		txt("%s   %s" % [T("rk_error"), T("rk_retry")], Vector2(left, 631), 14, Color(1, 0.5, 0.55))
	elif o.board_state == "ok":
		txt(T("rk_updated") % o.board_time, Vector2(left, 631), 13, Color(DIMC, 0.8), 0, true)
	draw_line(Vector2(64, 650), Vector2(1216, 650), Color(CYAN, 0.25), 1.0)
	txt(T("rk_nav"), Vector2(640, 686), 14, CYAN, 1)


func _name_modal() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color(INK, 0.8))
	# touch (Web): the HTML field brings its own OK and cancel buttons; they take the place of the
	# "ENTER / ESC" line, and the window is taller so that they sit clear of the notes above them
	var tb: bool = main.loc.touch and main.web_name != null
	var panel := Rect2(360, 226, 560, 336 if tb else 276)
	draw_rect(panel, Color(0.05, 0.08, 0.15, 0.98))
	draw_rect(panel, Color(CYAN, 0.6), false, 2.0)
	txt(T("name_title"), Vector2(640, 284), 26, WHITE, 1, true)
	if main.name_error != "":
		var red := Color(1, 0.45, 0.5)
		var shake: float = sin(clock * 60.0) * 6.0 * clampf(main.name_error_t / 0.6, 0.0, 1.0)
		draw_rect(main.name_edit.get_rect().grow(3.0), red, false, 2.5)
		txt(T("name_bad_" + main.name_error), Vector2(640 + shake, 404), 16, red, 1)
	else:
		txt(T("name_rule"), Vector2(640, 404), 14, DIMC, 1)
	txt(T("name_privacy"), Vector2(640, 432), 13, Color(DIMC, 0.85), 1)
	if not tb:
		txt(T("name_nav"), Vector2(640, 474), 15, CYAN, 1, true)
	if record:
		rects.append([main.name_edit.get_global_rect(), "name field"])
