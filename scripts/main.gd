extends Node
## Flow: boot (synthesize sound) -> title (bot demo behind) -> play -> result.

const Sim = preload("res://scripts/sim.gd")
const Bot = preload("res://scripts/bot.gd")
const View = preload("res://scripts/view.gd")
const Ui = preload("res://scripts/ui.gd")
const Loc = preload("res://scripts/loc.gd")
const AudioKit = preload("res://scripts/audio.gd")
const SelfTest = preload("res://scripts/selftest.gd")
const Online = preload("res://scripts/online.gd")
const Replay = preload("res://scripts/replay.gd")
const ApiConfig = preload("res://scripts/api_config.gd")

enum S { BOOT, TITLE, HOWTO, PLAY, PAUSE, RESULT, RANKING }
const SAVE_PATH := "user://countershift.cfg"
const RANKS := ["D", "C", "B", "A", "S"]
const RANK_AT := [0, 6000, 20000, 50000, 110000]

var state: int = S.BOOT
var state_t := 0.0
var boot_p := 0.0
var sim: Sim
var bot: Bot
var view: Node2D
var ui: Control
var loc := Loc.new()
var audio: Node
var online: Node
var rec := PackedByteArray()      # input replay of the current ranked run
var rec_on := false
var name_edit: LineEdit
var name_open := false
const NAME_BAR_Y := 452.0     # top of the HTML OK / cancel buttons of the name window (touch), in game units
var name_error_t := 0.0
var name_error := ""          # why the last name was refused: "", empty, long, chars
var name_ready := false       # the field has taken the focus after opening
var name_asked := false
var rank_from: int = S.TITLE
var rank_scroll := 0.0
var rank_goal := 0.0
var last_online := ""
var name_debug_last := ""
var web_name: Node = null     # Web: the name is typed into a real HTML input (scripts/web_name.gd)
var diag: Control = null       # temporary diagnostic overlay (development builds, ?diag=1)
var touch: Control = null      # touch controls: fingers become the same key presses a keyboard sends (scripts/touch.gd)
var last_board := "idle"
var bg_mat: ShaderMaterial
var post_mat: ShaderMaterial

var menu_idx := 0
var volume := 0.8
var best := 0
var plays := 0
var learned := 0
var can_fullscreen := true
var result := {}
var shown_score := 0
var score_pop := 0.0
var mult_pop := 0.0
var last_mult := 1
var banner := ""
var banner_t := 0.0
var banner_dur := 1.6
var banner_size := 64
var banner_col := Color(1, 1, 1)
var hint := ""
var hint_t := 0.0
var hint4_left := 6.0
var aim_tap := false
var focus_vis := 0.0
var dim_vis := 0.0
var clock := 0.0

# test hooks (command line: -- --auto=game --lang=ja ; web: ?auto=game&lang=ja)
var auto := ""
var auto_freeze := -1.0
var autoplay := false
var opts := {}
var shot_t := 1.0
var shot_n := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_read_opts()
	_load()
	if opts.has("lang"):
		loc.set_lang(opts["lang"])
	var font: Font = load("res://fonts/NotoSansJP-Bold.otf")

	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -10
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_mat = ShaderMaterial.new()
	bg_mat.shader = load("res://shaders/bg.gdshader")
	var A := Sim.ARENA
	bg_mat.set_shader_parameter("arena", Vector4(A.position.x / 1280.0, A.position.y / 720.0, A.size.x / 1280.0, A.size.y / 720.0))
	bg.material = bg_mat
	bg_layer.add_child(bg)

	view = View.new()
	view.font = font
	view.loc = loc
	add_child(view)

	var post_layer := CanvasLayer.new()
	post_layer.layer = 5
	add_child(post_layer)
	var post := ColorRect.new()
	post.set_anchors_preset(Control.PRESET_FULL_RECT)
	post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_mat = ShaderMaterial.new()
	post_mat.shader = load("res://shaders/post.gdshader")
	post.material = post_mat
	post_layer.add_child(post)

	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)
	ui = Ui.new()
	ui.main = self
	ui.view = view
	ui.font = font
	ui_layer.add_child(ui)

	name_edit = LineEdit.new()
	name_edit.max_length = 12
	name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_edit.context_menu_enabled = false
	name_edit.position = Vector2(440, 318)
	name_edit.size = Vector2(400, 56)
	name_edit.add_theme_font_override("font", font)
	name_edit.add_theme_font_size_override("font_size", 28)
	name_edit.add_theme_color_override("font_color", Color(1, 1, 1))
	name_edit.add_theme_color_override("caret_color", Color(0.45, 0.95, 1.0))
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.03, 0.06, 0.11)
	box.border_color = Color(0.45, 0.95, 1.0)
	box.set_border_width_all(2)
	box.set_content_margin_all(8)
	name_edit.add_theme_stylebox_override("normal", box)
	name_edit.add_theme_stylebox_override("focus", box)
	name_edit.visible = false
	# Enter must never drop the field out of editing: a refused name has to stay correctable.
	# (Enter itself is handled in _input, so it works whatever state the field is in.)
	name_edit.keep_editing_on_text_submit = true
	name_edit.text_changed.connect(func(_t: String) -> void: name_error = "")
	ui_layer.add_child(name_edit)
	if OS.has_feature("web"):
		# the browser's own input field takes the typing (it handles the IME); the Godot field stays hidden
		web_name = load("res://scripts/web_name.gd").new()
		add_child(web_name)
		web_name.decided.connect(_name_submitted)
		web_name.cancelled.connect(_close_name)
		web_name.edited.connect(func() -> void: name_error = "")

	var fp_t0 := Time.get_ticks_msec()
	Replay.fingerprint = SelfTest.fingerprint()
	print("fingerprint %d (%d ms)" % [Replay.fingerprint, Time.get_ticks_msec() - fp_t0])
	online = Online.new()
	add_child(online)
	if opts.has("verify"):
		var vo := opts.duplicate()
		vo["offline"] = "1"
		online.setup(vo)
		_verify_loop()
		return
	online.setup(opts)
	if opts.has("diag") and ApiConfig.URL == "" and ResourceLoader.exists("res://scripts/diag.gd"):
		diag = load("res://scripts/diag.gd").new()
		diag.main = self
		diag.font = font
		ui_layer.add_child(diag)

	touch = load("res://scripts/touch.gd").new()
	touch.main = self
	touch.font = font
	ui_layer.add_child(touch)

	audio = AudioKit.new()
	add_child(audio)
	audio.set_volume(volume)
	audio.progress.connect(func(p: float) -> void: boot_p = p)
	_boot()


func _boot() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	await audio.generate()
	print("boot: sound ready in %d ms" % (Time.get_ticks_msec() - t0))
	_to_title()
	if opts.has("golden") or opts.has("mkreplay"):
		# platform comparison: the same fingerprint lines as tools/golden.gd, the build
		# fingerprint, and (mkreplay) bot-played replays recorded here for another engine to verify
		await _report("FP %d" % Replay.fingerprint)
		for g in int(opts.get("golden", "0")):
			await _report(SelfTest.golden_line(1.0, g))
			await get_tree().process_frame
		var first := int(opts.get("mkseed", "7000"))
		for i in int(opts.get("mkreplay", "0")):
			var r: Dictionary = SelfTest.record_run(first + i, 0.6, i % 2 == 0)
			await _report("REPLAY %d %d %d %d %s" % [first + i, r["score"], r["wave"], r["time_ms"], Replay.to_wire(r["raw"])])
			await get_tree().process_frame
		await _report("GOLDEN DONE")
		return
	if opts.has("uicheck"):
		await _ui_check()
		return
	if opts.has("flowtest"):
		await _flow_test()
		return
	match opts.get("auto", ""):
		"howto":
			_set_state(S.HOWTO)
		"ranking":
			_open_ranking()
		"game", "pause", "result":
			if opts.has("ranked"):
				var waited := 0.0
				while online.enabled and online.ticket.is_empty() and waited < 5.0:
					waited += get_process_delta_time()
					await get_tree().process_frame
			_start_run()
			autoplay = true
			bot = Bot.new(int(opts.get("seed", "5")), float(opts.get("skill", "0.9")))
			auto = opts["auto"]
			auto_freeze = float(opts.get("freeze", "-1"))


func _read_opts() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=")
			opts[kv[0]] = kv[1]
	if OS.has_feature("web"):
		var q: String = str(JavaScriptBridge.eval("window.location.search", true))
		if q.length() > 1 and q.begins_with("?"):
			for pair in q.substr(1).split("&"):
				var kv: PackedStringArray = pair.split("=")
				if kv.size() == 2:
					opts[kv[0]] = kv[1].uri_decode()
	if ApiConfig.URL != "":
		# production build: no test hooks that could submit runs the player did not play,
		# and no pointing the ranking at another server (only the verifier may say where the API is)
		for k in ["ranked", "name", "uicheck", "flowtest", "profile", "offline", "diag", "namedebug"]:
			opts.erase(k)
		if not opts.has("verify"):
			opts.erase("api")


# ---------------------------------------------------------------- save

func _load() -> void:
	var cfg := ConfigFile.new()
	var lang := "ja" if OS.get_locale_language() == "ja" else "en"
	if cfg.load(SAVE_PATH) == OK:
		best = cfg.get_value("s", "best", 0)
		plays = cfg.get_value("s", "plays", 0)
		learned = cfg.get_value("s", "learned", 0)
		volume = cfg.get_value("s", "volume", 0.8)
		lang = cfg.get_value("s", "lang", lang)
	loc.set_lang(lang)


func _save() -> void:
	if opts.has("auto"):
		return
	var cfg := ConfigFile.new()
	cfg.set_value("s", "best", best)
	cfg.set_value("s", "plays", plays)
	cfg.set_value("s", "learned", learned)
	cfg.set_value("s", "volume", volume)
	cfg.set_value("s", "lang", loc.lang)
	cfg.save(SAVE_PATH)


# ---------------------------------------------------------------- states

func _set_state(s: int) -> void:
	state = s
	state_t = 0.0
	menu_idx = 0


func _to_title() -> void:
	_set_state(S.TITLE)
	autoplay = false
	sim = Sim.new()
	bot = Bot.new(randi(), 0.9)
	view.sim = sim
	view.reset()
	view.set_process(true)
	audio.set_music(0, 0.0)
	hint = ""
	banner_t = 0.0
	rec_on = false
	online.abandon_run()
	online.prefetch()


func _start_run() -> void:
	_set_state(S.PLAY)
	autoplay = false
	var seed_value := int(opts.get("seed", "0"))
	var tutorial := plays < 2 and learned < 3
	# a ranked run plays the seed the server chose and records its inputs; nothing else differs
	var ranked_seed := 0
	if seed_value == 0 and (not opts.has("auto") or opts.has("ranked")):
		ranked_seed = online.take_ticket()
	else:
		online.abandon_run()
	rec_on = ranked_seed != 0
	rec = Replay.begin(ranked_seed, tutorial) if rec_on else PackedByteArray()
	name_asked = false
	sim = Sim.new(ranked_seed if rec_on else seed_value, tutorial)
	view.sim = sim
	view.reset()
	view.set_process(true)
	shown_score = 0
	last_mult = 1
	hint = ""
	hint_t = 0.0
	hint4_left = 6.0
	banner_t = 0.0
	sim.prev_shift = true      # a key still held from the menu must not count as a press
	audio.set_music(1, 0.0)
	audio.play("ui_ok")


func is_fullscreen() -> bool:
	return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN


func _toggle_fullscreen() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if is_fullscreen() else DisplayServer.WINDOW_MODE_FULLSCREEN)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and state == S.PLAY and not opts.has("auto"):
		_pause()


func _pause() -> void:
	_set_state(S.PAUSE)
	view.set_process(false)
	audio.set_focus(1.0)


func _resume() -> void:
	state = S.PLAY
	view.set_process(true)


# ---------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	if diag != null and name_open and event is InputEventKey:
		diag.key_seen(event)
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k: int = event.keycode
	if name_open:
		if k == KEY_ESCAPE:
			_close_name()
			get_viewport().set_input_as_handled()
		elif k == KEY_ENTER or k == KEY_KP_ENTER:
			# decided here, not by the field: so Enter works even if the field lost focus or
			# left its editing state. While an IME is still composing, the browser keeps the
			# confirming Enter to itself and it never arrives here.
			get_viewport().set_input_as_handled()
			if diag != null:
				diag.note("DECIDE: Enter reached the game (IME composing: %s)" % (DisplayServer.ime_get_text() != ""))
			if DisplayServer.ime_get_text() == "":
				_name_submitted(name_text())
		return
	if k == KEY_F11 or (k == KEY_F and state != S.PLAY):
		_toggle_fullscreen()
		return
	var up := k == KEY_UP or k == KEY_W
	var down := k == KEY_DOWN or k == KEY_S
	var left := k == KEY_LEFT or k == KEY_A
	var right := k == KEY_RIGHT or k == KEY_D
	var ok := k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_SPACE or k == KEY_Z
	var back := k == KEY_ESCAPE
	match state:
		S.TITLE:
			var count := 6 if can_fullscreen else 5
			if up or down:
				menu_idx = posmod(menu_idx + (1 if down else -1), count)
				audio.play("ui_move")
			elif menu_idx == 3 and (left or right or ok):
				loc.next_lang()
				audio.play("ui_ok")
				_save()
			elif menu_idx == 4 and (left or right):
				volume = clampf(snappedf(volume + (0.1 if right else -0.1), 0.1), 0.0, 1.0)
				audio.set_volume(volume)
				audio.play("ui_ok")
				_save()
			elif menu_idx == 5 and (left or right or ok):
				_toggle_fullscreen()
			elif ok:
				if menu_idx == 0:
					_start_run()
				elif menu_idx == 1:
					_set_state(S.HOWTO)
					audio.play("ui_ok")
				elif menu_idx == 2:
					_open_ranking()
		S.HOWTO:
			if ok or back:
				_set_state(S.TITLE)
				menu_idx = 1
				audio.play("ui_ok")
		S.PLAY:
			if back or k == KEY_P:
				_pause()
			elif up or down or left or right:
				aim_tap = true
		S.PAUSE:
			if back or k == KEY_P:
				_resume()
			elif up or down:
				menu_idx = posmod(menu_idx + (1 if down else -1), 3)
				audio.play("ui_move")
			elif ok:
				match menu_idx:
					0: _resume()
					1: _start_run()
					2: _to_title()
		S.RESULT:
			if state_t > 2.2:
				if ok or k == KEY_R:
					_start_run()
				elif back:
					_to_title()
				elif k == KEY_TAB:
					_open_ranking()
				elif k == KEY_N and online.enabled and online.sub.get("state", "") != "sending":
					_open_name()
				elif k == KEY_S and online.sub.get("state", "") == "error":
					online.send()
					audio.play("ui_ok")
		S.RANKING:
			var rows: int = online.board.size()
			var max_scroll := maxf(0.0, rows - 12.0)
			if back or k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_TAB:
				_close_ranking()
			elif up or down:
				rank_goal = clampf(rank_goal + (3.0 if down else -3.0), 0.0, max_scroll)
				audio.play("ui_move")
			elif k == KEY_PAGEDOWN or k == KEY_PAGEUP:
				rank_goal = clampf(rank_goal + (12.0 if k == KEY_PAGEDOWN else -12.0), 0.0, max_scroll)
				audio.play("ui_move")
			elif k == KEY_R:
				online.fetch_top()
				audio.play("ui_ok")
			elif k == KEY_N and online.enabled:
				_open_name()
			elif k == KEY_M:
				for i in rows:
					if online.board[i]["me"]:
						rank_goal = clampf(i - 5.0, 0.0, max_scroll)
				audio.play("ui_move")


func _read_play_input() -> Dictionary:
	var mv := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		mv.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		mv.x += 1.0
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
		mv.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
		mv.y += 1.0
	var out := {"move": mv.normalized(), "shift": Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_SPACE), "aim_tap": aim_tap}
	aim_tap = false
	return out


# ---------------------------------------------------------------- loop

func _process(delta: float) -> void:
	clock += delta
	state_t += delta
	if opts.has("shots") and state != S.BOOT:
		shot_t -= delta
		if shot_t <= 0.0:
			shot_t = float(opts.get("every", "2"))
			shot_n += 1
			get_viewport().get_texture().get_image().save_png("%s/%s_%02d.png" % [opts["shots"], opts.get("auto", "title"), shot_n])
			if shot_n >= int(opts.get("count", "8")):
				get_tree().quit()
	if opts.has("auto") and Engine.get_process_frames() % 120 == 0:
		print("fps %d  state %d  t %.1f" % [Engine.get_frames_per_second(), state, sim.real_time if sim != null else 0.0])
	score_pop = maxf(0.0, score_pop - delta * 4.0)
	mult_pop = maxf(0.0, mult_pop - delta * 4.0)
	banner_t = maxf(0.0, banner_t - delta)
	match state:
		S.TITLE, S.HOWTO:
			_step(delta, bot.decide(sim, delta), false)
			if sim.dead_t > 2.5:
				sim = Sim.new()
				bot = Bot.new(randi(), 0.9)
				view.sim = sim
				view.reset()
		S.PLAY:
			if auto_freeze >= 0.0 and sim.real_time >= auto_freeze:
				pass
			else:
				var inp := bot.decide(sim, delta) if autoplay else _read_play_input()
				if autoplay and opts.has("hold") and sim.focusing:
					bot.hold = maxi(bot.hold, 2)
				if autoplay and opts.has("lazy"):
					inp = {"move": Vector2.ZERO, "shift": false}
				if autoplay and opts.has("autokeys"):
					inp = Replay.unpack_input(Replay.pack_input(inp))     # test: the bot presses real key states
				if rec_on:
					Replay.add(rec, delta, inp)
				_step(delta, inp, true)
				_hints(delta)
				if auto == "result" and sim.alive and sim.real_time > float(opts.get("die", "20")):
					sim.hp = 1
					sim.inv = 0.0
					sim._hurt(sim.p_pos)
				if auto == "pause" and sim.real_time > 6.0:
					auto = ""
					_pause()
			if sim.dead_t > 1.7:
				_finish()
		S.RESULT:
			_step(delta, {}, false)
			if not name_asked and state_t > 3.4 and online.sub.get("state", "") == "need_name":
				name_asked = true
				_open_name()
		S.RANKING:
			if rank_from == S.TITLE:
				_step(delta, bot.decide(sim, delta), false)
				if sim.dead_t > 2.5:
					sim = Sim.new()
					bot = Bot.new(randi(), 0.9)
					view.sim = sim
					view.reset()
			else:
				_step(delta, {}, false)
			rank_scroll = lerpf(rank_scroll, rank_goal, minf(1.0, delta * 14.0))
			if diag != null and opts.has("autoname") and not name_open and state_t > 1.5 and not name_asked:
				name_asked = true
				_open_name()
	name_error_t = maxf(0.0, name_error_t - delta)
	if name_open and name_ready and web_name != null:
		# keep the HTML field exactly over the field's place, whatever the zoom or window size
		var xf: Transform2D = name_edit.get_viewport().get_final_transform() * name_edit.get_global_transform_with_canvas()
		var p0: Vector2 = xf * Vector2.ZERO
		var p1: Vector2 = xf * name_edit.size
		var sy: float = (p1.y - p0.y) / name_edit.size.y
		# the touch buttons go under the notes: NAME_BAR_Y in game units, here in the canvas's pixels
		web_name.place(Rect2(p0, p1 - p0), 28.0 * sy, name_error != "", p0.y + (NAME_BAR_Y - name_edit.global_position.y) * sy)
	elif name_open and name_ready and not (name_edit.has_focus() and name_edit.is_editing()):
		# a click elsewhere or the browser took the focus away: typing must keep going to the field
		name_edit.grab_focus()
		name_edit.edit()
	if opts.has("namedebug"):
		var ns := "open=%s visible=%s focus=%s editing=%s text=[%s] err=%s sub=%s saved=[%s]" % [name_open, name_edit.visible, name_edit.has_focus(), name_edit.is_editing(), name_text(), name_error, online.sub.get("state", ""), online.player_name]
		if ns != name_debug_last:
			name_debug_last = ns
			print("NAME " + ns)
	if opts.has("auto") and online != null and online.sub.get("state", "") != last_online:
		last_online = online.sub.get("state", "")
		print("ONLINE %s %s score=%d" % [last_online, JSON.stringify(online.sub), sim.score if sim != null else 0])
		if last_online == "error" and opts.has("resend"):
			get_tree().create_timer(float(opts["resend"])).timeout.connect(online.send)
	if opts.has("auto") and online != null and online.board_state != last_board:
		last_board = online.board_state
		print("BOARD %s entries=%d total=%d me=%s" % [last_board, online.board.size(), online.board_total, JSON.stringify(online.me)])
	if sim != null and shown_score < sim.score:
		shown_score = mini(sim.score, shown_score + maxi(1, int((sim.score - shown_score) * minf(1.0, delta * 12.0))))
	_uniforms(delta)


func _step(delta: float, inp: Dictionary, loud: bool) -> void:
	sim.step(delta, inp)
	view.consume(sim.events)
	_sounds(sim.events, loud)
	sim.events.clear()
	if loud:
		var heat := clampf(sim.alive_count() / 30.0 + (sim.mult - 1) / 10.0, 0.0, 1.0)
		audio.set_music(1, heat)
	if sim.mult > last_mult:
		mult_pop = 1.0
	last_mult = sim.mult


func _sounds(events: Array, loud: bool) -> void:
	var q := 0.0 if loud else -14.0
	for e in events:
		match e["k"]:
			"focus_in": audio.play("focus_in", 1.0, q - 4.0)
			"empty": if loud: audio.play("empty")
			"swap": audio.play("shift", 0.95 + randf() * 0.1, q)
			"kill":
				if e["pts"] > 0:
					score_pop = 1.0
					var p := minf(1.9, 0.85 + e["chain"] * 0.035)
					audio.play("shiftkill" if e["shift"] else "kill", p, q - (0.0 if e["shift"] else 3.0))
			"nova": audio.play("nova", 0.9 + randf() * 0.3, q - 6.0)
			"explode": audio.play("explode", 0.9 + randf() * 0.2, q)
			"shot": audio.play("shot", 0.9 + randf() * 0.25, q - 8.0)
			"charge_up": audio.play("charge_up", 1.0, q - 5.0)
			"dash": audio.play("dash", 1.0, q - 2.0)
			"thud": audio.play("thud", 1.0, q - 2.0)
			"laser_charge": audio.play("laser_charge", 1.0, q - 7.0)
			"laser": audio.play("laser", 1.0, q - 1.0)
			"fuse": audio.play("fuse", 1.0, q - 6.0)
			"bite": audio.play("bite", 1.0, q - 6.0)
			"hurt": audio.play("hurt", 1.0, q + 2.0)
			"dead": audio.play("dead", 1.0, q + 2.0)
			"spawn": audio.play("spawn", 0.8 + randf() * 0.5, q - 8.0)
			"heal": if loud: audio.play("heal")
			"burst": if loud: audio.play("burst", 1.0, -3.0)
			"wave":
				if loud:
					audio.play("wave", 1.0, -3.0)
					_banner("%s %d" % [loc.t("wave"), e["wave"]], 64, Color(1, 1, 1), 1.7)
			"wave_clear":
				if loud:
					audio.play("clear", 1.0, -4.0)
					_banner(loc.t("wave_clear"), 44, Color(0.45, 0.95, 1.0), 1.3)


func _banner(text: String, size: int, col: Color, dur: float) -> void:
	banner = text
	banner_size = size
	banner_col = col
	banner_dur = dur
	banner_t = dur


func _hints(delta: float) -> void:
	var want := ""
	if learned < 3 and sim.alive and sim.wave >= 1:
		if sim.swaps == 0:
			if sim._targetable_count() > 0:
				want = "hint2" if sim.focusing else "hint1"
		elif sim.kills == 0:
			want = "hint3"
		elif sim.kills < 8 and hint4_left > 0.0:
			hint4_left -= delta
			want = "hint4"
	if want != hint:
		hint = want
		hint_t = 0.0
	hint_t += delta


func _finish() -> void:
	plays += 1
	learned += sim.shift_kills
	var rank_i := 0
	for i in RANK_AT.size():
		if sim.score >= RANK_AT[i]:
			rank_i = i
	var record := sim.score > best and sim.score > 0
	result = {
		"score": sim.score, "best": maxi(best, sim.score), "record": record, "wave": sim.wave, "time": sim.real_time,
		"kills": sim.kills, "shift_kills": sim.shift_kills, "max_chain": sim.max_chain, "best_burst": sim.best_burst,
		"rank": RANKS[rank_i], "rank_i": rank_i, "next": RANK_AT[rank_i + 1] if rank_i + 1 < RANK_AT.size() else 0,
		"tip": randi() % 7,
	}
	if record:
		best = sim.score
	_save()
	if rec_on:
		Replay.close(rec, sim)
	online.finish_run(sim.score, sim.wave, rec if rec_on else PackedByteArray())
	rec_on = false
	rec = PackedByteArray()
	if opts.has("name") and online.sub.get("state", "") == "need_name" and Online.clean_name(str(opts["name"])) != "":
		name_asked = true
		online.set_player_name(Online.clean_name(str(opts["name"])))
	online.prefetch()
	_set_state(S.RESULT)
	audio.set_music(0, 0.0)
	hint = ""
	if record:
		get_tree().create_timer(2.8).timeout.connect(func() -> void:
			if state == S.RESULT:
				audio.play("record"))


func _uniforms(delta: float) -> void:
	if sim == null:
		return
	var demo := state == S.TITLE or state == S.HOWTO or (state == S.RANKING and rank_from == S.TITLE)
	var f_goal := 1.0 if (sim.focusing and not demo) else 0.0
	if sim.focusing and demo:
		f_goal = 0.5
	focus_vis = move_toward(focus_vis, f_goal, delta * 9.0)
	var d_goal := 0.0
	if state == S.TITLE or state == S.HOWTO or state == S.RESULT or state == S.BOOT or state == S.RANKING:
		d_goal = 1.0
	dim_vis = move_toward(dim_vis, d_goal, delta * 2.0)
	if state != S.PAUSE:
		audio.set_focus(focus_vis if state == S.PLAY else 0.0)
	var six: Dictionary = view.shader_points(6)
	var four: Dictionary = view.shader_points(4)
	bg_mat.set_shader_parameter("player_uv", sim.p_pos / Vector2(1280, 720))
	bg_mat.set_shader_parameter("time_s", clock)
	bg_mat.set_shader_parameter("focus", focus_vis)
	bg_mat.set_shader_parameter("hue", view.hue)
	bg_mat.set_shader_parameter("dim", dim_vis * 0.5)
	bg_mat.set_shader_parameter("warps", six["pts"])
	bg_mat.set_shader_parameter("warp_s", six["str"])
	post_mat.set_shader_parameter("chroma", view.chroma)
	post_mat.set_shader_parameter("focus", focus_vis)
	post_mat.set_shader_parameter("flash", view.flash * (1.0 if state == S.PLAY or state == S.RESULT else 0.3))
	post_mat.set_shader_parameter("glitch", view.glitch * (1.0 if state == S.PLAY else 0.4))
	post_mat.set_shader_parameter("time_s", clock)
	post_mat.set_shader_parameter("shocks", four["pts"])
	post_mat.set_shader_parameter("shock_s", four["str"])
	view.modulate = Color(1, 1, 1).lerp(Color(0.8, 0.82, 0.9), dim_vis * (1.0 if state != S.RESULT else 0.6))


# ---------------------------------------------------------------- tools

## Counts text that leaves the 1280x720 frame, on every screen, in every language.
func _ui_check() -> void:
	var frame := Rect2(0, 0, 1280, 720)
	var bad := 0
	var total := 0
	ui.record = true
	opts["auto"] = "uicheck"
	# once as a keyboard player sees it, then with the touch wording and buttons at several finger sizes
	# (game units per CSS pixel: a tablet, phones, the largest the layer allows)
	var over := 0
	for fingers in [0.0, 1.08, 1.75, 1.85, 2.0, 3.0]:
		loc.touch = fingers > 0.0
		touch.active = fingers > 0.0
		touch.force_upc = fingers
		for lang in Loc.LANGS:
			loc.set_lang(lang)
			for screen in ["title", "howto", "play", "pause", "result", "ranking", "ranking_empty", "name"]:
				match screen:
					"title":
						best = 1234567
						_to_title()
					"howto":
						_set_state(S.HOWTO)
					"play":
						_start_run()
						autoplay = true
						best = 1234567
					"pause":
						_pause()
					"result":
						result = {"score": 1234567, "best": 1234567, "record": false, "wave": 38, "time": 1234.0, "kills": 2345,
							"shift_kills": 678, "max_chain": 144, "best_burst": 43, "rank": "S", "rank_i": 4, "next": 110000, "tip": 0}
						_set_state(S.RESULT)
					"ranking", "ranking_empty":
						_close_name()
						_set_state(S.RANKING)
						online.enabled = true
						online.board = []
						online.me = {}
						online.pending = 0
						if screen == "ranking":
							for i in 100:
								online.board.append({"rank": i + 1, "name": ["ＷＷＷＷＷＷＷＷＷＷＷＷ", "WWWWWWWWWWWW", "鬱鬱鬱鬱鬱鬱鬱鬱鬱鬱鬱鬱"][i % 3], "score": 2000000000 - i, "wave": 99999, "at": 1794300000000, "me": i == 4})
							online.me = {"rank": 123456, "score": 2000000000, "wave": 99999, "at": 1794300000000, "name": "x"}
							online.pending = 1
						online.player_name = "ＷＷＷＷＷＷＷＷＷＷＷＷ" if screen == "ranking" else ""
						online.board_total = 1234567
						online.board_time = "23:59"
						online.board_loaded_at = -100.0
					"name":
						_set_state(S.RESULT)
						_open_name()
				var variants := 10 if screen == "result" else (4 if screen == "play" else (4 if screen.begins_with("ranking") else (4 if screen == "name" else 1)))
				for v in variants:
					if screen == "result":
						result["tip"] = v % 7
						result["record"] = v % 2 == 1
						state_t = 10.0
						online.best_score = 2000000000
						online.sub = [{"state": "none"}, {"state": "unranked"}, {"state": "need_name"}, {"state": "sending"},
							{"state": "verifying", "rank": 123456}, {"state": "queued"}, {"state": "verified", "rank": 123456},
							{"state": "not_best"}, {"state": "error"}, {"state": "rejected", "reason": "bad_name"}][v]
					if screen.begins_with("ranking"):
						online.board_state = ["ok", "loading", "error", "ok"][v]
						online.enabled = v != 3 or screen == "ranking"
						rank_scroll = [0.0, 44.0, 88.0, 3.5][v]
					if screen == "name":
						name_error = ["", "empty", "long", "chars"][v]
						name_edit.text = "ＷＷＷＷＷＷＷＷＷＷＷＷ"
					if screen == "play":
						hint = "hint%d" % (v + 1)
						hint_t = 1.0
						sim.chain = 144
						sim.mult = 9
						sim.chain_t = 3.0
						sim.score = 1234567
						shown_score = 1234567
						_banner("%s %d" % [loc.t("wave"), 38] if v % 2 == 0 else loc.t("wave_clear"), 64, Color(1, 1, 1), 99.0)
					for f in 3:
						if screen == "play":
							hint = "hint%d" % (v + 1)
							hint_t = 1.0
						if screen == "result":
							state_t = 10.0
						await get_tree().process_frame
					for r in ui.rects:
						total += 1
						if not frame.encloses(r[0]):
							bad += 1
							print("  OUTSIDE [%s/%s] %s  %s" % [lang, screen, str(r[0]), r[1]])
						if fingers > 0.0 and r[1] != "" and r[0].size.x > 0.0:
							for tb in touch.buttons:
								if tb["rect"].intersects(r[0]):
									over += 1
									print("  UNDER A TOUCH BUTTON [%s/%s/%.2f] %s  %s" % [lang, screen, fingers, str(r[0]), r[1]])
	_close_name()
	print("ui check: %d text blocks, %d outside the 1280x720 frame, %d under a touch button" % [total, bad, over])
	get_tree().quit()


func _key(code: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func _type(text: String) -> void:
	for i in text.length():
		var e := InputEventKey.new()
		e.unicode = text.unicode_at(i)
		e.pressed = true
		Input.parse_input_event(e)
		await get_tree().process_frame
		await get_tree().process_frame


func _tap(code: int) -> void:
	_key(code, true)
	await get_tree().process_frame
	await get_tree().process_frame
	_key(code, false)
	await get_tree().process_frame
	await get_tree().process_frame


func _expect(what: String, ok: bool) -> void:
	flow_total += 1
	if not ok:
		flow_fail += 1
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])


var flow_total := 0
var flow_fail := 0


## Drives the real key handlers through one whole session.
func _flow_test() -> void:
	opts["auto"] = "flow"
	online.save_path = "user://countershift_online_flowtest.cfg"      # never the player's own file
	_expect("starts on the title", state == S.TITLE)
	await _tap(KEY_DOWN)
	_expect("down moves the cursor", menu_idx == 1)
	await _tap(KEY_ENTER)
	_expect("enter opens how to play", state == S.HOWTO)
	await _tap(KEY_ESCAPE)
	_expect("esc returns to the title", state == S.TITLE and menu_idx == 1)
	await _tap(KEY_DOWN)
	await _tap(KEY_ENTER)
	_expect("enter opens the ranking", state == S.RANKING)
	await _tap(KEY_DOWN)
	await _tap(KEY_R)
	_expect("the ranking stays usable without a server", state == S.RANKING)
	await _tap(KEY_N)
	_expect("N does nothing while the ranking is off", not name_open or online.enabled)
	if name_open:
		await _tap(KEY_ESCAPE)
	await _tap(KEY_ESCAPE)
	_expect("esc returns to the title, on the ranking item", state == S.TITLE and menu_idx == 2)
	# ---- name entry (works offline too: the name is kept for later)
	var saved_name: String = online.player_name
	_open_name()
	await get_tree().create_timer(0.4).timeout
	_expect("the name field opens focused and ready to type", name_open and name_edit.has_focus() and name_edit.is_editing())
	await _type("a!")
	await _tap(KEY_ENTER)
	_expect("a name with a forbidden character is refused, with the reason", name_open and name_error == "chars" and name_edit.text == "a!")
	_expect("the field is still being edited after the refusal", name_edit.has_focus() and name_edit.is_editing())
	await _tap(KEY_BACKSPACE)
	_expect("the refusal message goes away when the text changes", name_error == "" and name_edit.text == "a")
	await _type("b")
	await _tap(KEY_ENTER)
	_expect("the corrected name is accepted with one Enter", not name_open and online.player_name == "ab" and state == S.TITLE)
	_open_name()
	await get_tree().create_timer(0.4).timeout
	name_edit.text = ""
	await _tap(KEY_ENTER)
	_expect("an empty name is refused and says so", name_open and name_error == "empty")
	name_edit.release_focus()
	for i in 3:
		await get_tree().process_frame
	_expect("a field that lost the focus takes it back", name_edit.has_focus() and name_edit.is_editing())
	name_edit.text = "ＡＢＣ　１２３４５６７８"
	await _tap(KEY_ENTER)
	_expect("full-width letters and space are folded and accepted", not name_open and online.player_name == "ABC 12345678")
	_open_name()
	await get_tree().create_timer(0.4).timeout
	name_edit.text = "かぜの旅びと"
	await _tap(KEY_KP_ENTER)
	_expect("Japanese is accepted, also with the keypad Enter", not name_open and online.player_name == "かぜの旅びと")
	_open_name()
	await get_tree().create_timer(0.4).timeout
	await _type("zzz")
	await _tap(KEY_ESCAPE)
	_expect("esc cancels without changing the name or leaving the title", not name_open and online.player_name == "かぜの旅びと" and state == S.TITLE)
	online.player_name = saved_name
	await _tap(KEY_DOWN)
	var before := loc.lang
	await _tap(KEY_RIGHT)
	_expect("right changes the language", loc.lang != before)
	await _tap(KEY_RIGHT)
	_expect("and back again", loc.lang == before)
	await _tap(KEY_DOWN)
	await _tap(KEY_LEFT)
	_expect("left lowers the volume", is_equal_approx(volume, 0.7))
	await _tap(KEY_RIGHT)
	await _tap(KEY_UP)
	await _tap(KEY_UP)
	await _tap(KEY_UP)
	await _tap(KEY_UP)
	_expect("the cursor is back on start", menu_idx == 0)
	_key(KEY_SPACE, true)
	await get_tree().process_frame
	await get_tree().process_frame
	_expect("space starts a run", state == S.PLAY)
	for i in 10:
		await get_tree().process_frame
	_expect("the held key is not read as a shift", not sim.focusing and sim.swaps == 0)
	_key(KEY_SPACE, false)
	var start := sim.p_pos
	_key(KEY_RIGHT, true)
	for i in 30:
		await get_tree().process_frame
	_key(KEY_RIGHT, false)
	_expect("right arrow moves the player", sim.p_pos.x > start.x + 40.0)
	var guard := 0
	while sim._targetable_count() == 0 and guard < 600:
		guard += 1
		await get_tree().process_frame
	_expect("enemies arrive", sim._targetable_count() > 0)
	_key(KEY_SHIFT, true)
	for i in 6:
		await get_tree().process_frame
	_expect("holding shift slows time", sim.focusing and sim.ts < 0.6 and sim.target != null)
	var victim := sim.target
	var there := victim.pos
	_key(KEY_SHIFT, false)
	for i in 3:
		await get_tree().process_frame
	_expect("releasing trades places", sim.swaps == 1 and sim.p_pos.distance_to(there) < 30.0 and victim.exposed > 0.0)
	await _tap(KEY_ESCAPE)
	_expect("esc pauses", state == S.PAUSE)
	var frozen := sim.real_time
	for i in 10:
		await get_tree().process_frame
	_expect("time stands still while paused", sim.real_time == frozen)
	await _tap(KEY_ENTER)
	_expect("enter resumes", state == S.PLAY)
	sim.hp = 1
	sim.inv = 0.0
	sim._hurt(sim.p_pos)
	guard = 0
	while state != S.RESULT and guard < 600:
		guard += 1
		await get_tree().process_frame
	_expect("losing every shield shows the result", state == S.RESULT)
	_expect("an offline run is marked as not ranked, or nothing is shown", online.sub.get("state", "") in ["none", "unranked"])
	await _tap(KEY_ENTER)
	_expect("the result ignores keys for a moment", state == S.RESULT)
	state_t = 3.0
	await _tap(KEY_TAB)
	_expect("tab opens the ranking from the result", state == S.RANKING)
	await _tap(KEY_ESCAPE)
	_expect("and returns to the same result", state == S.RESULT and state_t >= 10.0)
	await _tap(KEY_ENTER)
	_expect("enter retries", state == S.PLAY and sim.score == 0 and sim.hp == Sim.MAX_HP)
	await _tap(KEY_P)
	await _tap(KEY_DOWN)
	await _tap(KEY_DOWN)
	await _tap(KEY_ENTER)
	_expect("pause menu returns to the title", state == S.TITLE)
	print("flow test: %d checks, %d failed" % [flow_total, flow_fail])
	get_tree().quit(1 if flow_fail > 0 else 0)


# ---------------------------------------------------------------- ranking / name

func _open_ranking() -> void:
	rank_from = state
	_set_state(S.RANKING)
	rank_scroll = 0.0
	rank_goal = 0.0
	online.fetch_top()
	audio.play("ui_ok")


func _close_ranking() -> void:
	audio.play("ui_ok")
	if rank_from == S.RESULT:
		state = S.RESULT
		state_t = 10.0
	else:
		_set_state(S.TITLE)
		menu_idx = 2


func _open_name() -> void:
	# the key that opened the field (N) must not also be typed into it
	get_viewport().set_input_as_handled()
	name_open = true
	name_ready = false
	name_error = ""
	name_error_t = 0.0
	name_edit.text = online.player_name
	name_edit.visible = web_name == null
	audio.play("ui_ok")
	# focus a moment later, so that the key still going through the browser is not typed
	await get_tree().create_timer(0.2).timeout
	if not name_open:
		return
	if web_name != null:
		web_name.show_field(online.player_name, loc.touch)
	else:
		name_edit.text = online.player_name
		name_edit.grab_focus()
		name_edit.edit()
		name_edit.caret_column = name_edit.text.length()
	name_ready = true


func _close_name() -> void:
	name_open = false
	name_ready = false
	if web_name != null:
		web_name.hide_field()
	name_edit.release_focus()
	name_edit.visible = false


## What is in the name field right now (the HTML field on the Web, the Godot field elsewhere).
func name_text() -> String:
	return web_name.text() if (web_name != null and web_name.is_open) else name_edit.text


func _name_submitted(text: String) -> void:
	var clean: String = Online.clean_name(text)
	if diag != null:
		diag.note("DECIDE: name check on %d chars -> %s" % [text.length(), "ACCEPTED" if clean != "" else "REFUSED (" + Online.name_problem(text) + ")"])
	if clean == "":
		name_error = Online.name_problem(text)      # stays on screen until the text changes
		name_error_t = 0.6                          # (a short shake of the field)
		audio.play("empty")
		return
	_close_name()
	audio.play("ui_ok")
	online.set_player_name(clean)


## Verifier mode: replays queued runs in this very build and reports what they really scored.
## Start with --verify=1 --api=<url> --vtoken=<VERIFIER_TOKEN> (Web: the same as query parameters).
func _verify_loop() -> void:
	var pid := Replay.platform_id()
	var vtoken := str(opts.get("vtoken", ""))
	await _report("VERIFIER READY platform %d build %d fp %d" % [pid, Replay.BUILD, Replay.fingerprint])
	while true:
		var box := [false, {}]
		print("VERIFIER ALIVE")
		online._req(HTTPClient.METHOD_GET, "/v1/verify/next?platform=%d&fp=%d" % [pid, Replay.fingerprint], null, func(ok: bool, _code: int, d: Dictionary) -> void:
			box[0] = true
			box[1] = d if ok else {}, vtoken)
		while not box[0]:
			await get_tree().process_frame
		var job_info: Dictionary = box[1]
		if not job_info.has("id"):
			if opts.has("once"):
				await _report("VERIFIER IDLE")
				if not OS.has_feature("web"):
					get_tree().quit()
				return
			await get_tree().create_timer(float(opts.get("vpoll", "10"))).timeout
			continue
		var t0 := Time.get_ticks_msec()
		var res := {}
		var job: Dictionary = Replay.open(Replay.from_wire(str(job_info.get("replay", ""))))
		if job.has("error"):
			res = {"ok": false, "reason": job["error"]}
		else:
			while not Replay.advance(job, 1500):
				await get_tree().process_frame
			res = Replay.result(job)
		res["id"] = job_info["id"]
		var sent := [false]
		online._req(HTTPClient.METHOD_POST, "/v1/verify/result", res, func(_ok: bool, _code: int, _d: Dictionary) -> void:
			sent[0] = true, vtoken)
		while not sent[0]:
			await get_tree().process_frame
		await _report("VERIFIED %s ok=%s score=%s reason=%s in %d ms" % [str(job_info["id"]).left(8), str(res.get("ok")), str(res.get("score", "-")), str(res.get("reason", "")), Time.get_ticks_msec() - t0])


## Prints a line; with ?report=1 (local tests) it is also posted to /__report on the page's own
## server, for browsers whose console cannot be read (the WebKit check).
func _report(line: String) -> void:
	print(line)
	if not opts.has("report") or not OS.has_feature("web"):
		return
	var origin := str(JavaScriptBridge.eval("window.location.origin", true))
	var h := HTTPRequest.new()
	h.timeout = 5.0
	add_child(h)
	var done := [false]
	h.request_completed.connect(func(_a: int, _b: int, _c: PackedStringArray, _d: PackedByteArray) -> void:
		done[0] = true
		h.queue_free())
	if h.request(origin + "/__report", PackedStringArray(["Content-Type: text/plain"]), HTTPClient.METHOD_POST, line) != OK:
		h.queue_free()
		return
	while not done[0]:
		await get_tree().process_frame
