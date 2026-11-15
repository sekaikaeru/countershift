extends Control
## Touch controls for phones and tablets.
##
## Nothing here knows the game's rules. A finger is turned into the very key presses a keyboard
## sends (arrows, SHIFT, ENTER, ESC, TAB, N, S), through Input.parse_input_event. So the game, the
## replay recording and the ranking cannot tell a finger from a key: the left thumb is an 8-way
## stick (the same 8 directions the arrow keys give), the right thumb holds SHIFT.
##
## The layer stays invisible and does nothing until the first touch, so a keyboard player never sees it.
## A key press that did not come from this layer (a real keyboard) puts it away again, and the texts go
## back to the keyboard wording (main.loc.touch): whichever the player used last decides.

const DIRS := [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]
const WORDS := {
	"ok": ["OK", "決定"], "back": ["BACK", "もどる"], "retry": ["RETRY", "もう一度"], "title": ["TITLE", "タイトル"],
	"rank": ["RANKING", "ランキング"], "name": ["NAME", "名前"], "send": ["SEND AGAIN", "再送信"],
	"refresh": ["REFRESH", "更新"], "mine": ["MY RANK", "自分の順位"],
	"move": ["MOVE", "移動"], "rotate": ["TURN YOUR PHONE SIDEWAYS", "スマホを横向きにしてください"],
}

var main: Node
var font: Font
var active := false            # true from the first touch on
var stick_id := -1             # finger on the stick, or -1
var stick_origin := Vector2.ZERO
var stick_pos := Vector2.ZERO
var shift_id := -1             # finger holding SHIFT, or -1
var held := {}                 # keycode -> true: keys this layer is holding down right now
var btn_of := {}               # finger -> keycode of the button under it
var buttons: Array = []        # buttons of the current screen: {rect, key, word, arrow}
var last_state := -1
var used_stick := false
var used_shift := false
var upc := 1.0                 # game units per CSS pixel: how big a finger is on this screen
var portrait := false
var clock := 0.0
var sent := {}                 # "keycode:pressed" -> how many of this layer's own key events are still on their way
var force_upc := 0.0           # tests only (the text check): pretend this finger size, never upright
var tlog: RefCounted = null    # tests only: scripts/touch_log.gd, a file that release builds do not contain


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()
	# The test log (which keys a finger turned into, which wording is shown) lives in its own script.
	# The release export preset leaves that file out, so a released build cannot print it at all.
	if main.opts.has("touchlog") and ResourceLoader.exists("res://scripts/touch_log.gd"):
		tlog = load("res://scripts/touch_log.gd").new()
		tlog.words.call_deferred(main.loc)


func word(k: String) -> String:
	return WORDS[k][1 if main.loc.lang == "ja" else 0]


## Works out how large a finger is in game units, and whether the phone is held upright.
func _measure() -> void:
	var ws := Vector2(DisplayServer.window_get_size())
	if force_upc > 0.0:
		upc = force_upc
		portrait = false
		return
	if ws.x <= 0.0 or ws.y <= 0.0:
		return
	var shown_w := minf(ws.x, ws.y * 16.0 / 9.0)             # the 16:9 picture inside the window
	var dpr := maxf(1.0, DisplayServer.screen_get_scale())
	upc = clampf(1280.0 / shown_w * dpr, 0.6, 3.0)
	portrait = ws.y > ws.x * 1.05


func _key(code: int, down: bool) -> void:
	if down == held.has(code):
		return
	if down:
		held[code] = true
	else:
		held.erase(code)
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	var tag := "%d:%s" % [code, down]
	sent[tag] = sent.get(tag, 0) + 1
	Input.parse_input_event(ev)
	if tlog != null:
		tlog.key(code, down)


## Lets go of everything: used when the screen changes, the page loses focus or a touch is cancelled.
func release_all() -> void:
	stick_id = -1
	shift_id = -1
	btn_of.clear()
	for code in held.keys():
		_key(code, false)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if not active or event.echo:
			return
		var tag := "%d:%s" % [event.keycode, event.pressed]
		if sent.get(tag, 0) > 0:               # one of this layer's own
			sent[tag] -= 1
		elif event.pressed and not main.name_open:
			_sleep()                           # a real keyboard: the keyboard wording and no touch buttons
		return
	if event is InputEventScreenTouch:
		if not active:
			active = true
			main.loc.touch = true
			sent.clear()
			last_state = -1
			_measure()
			_layout()
			if tlog != null:
				tlog.woke(upc, portrait, main.loc)
		if event.canceled or not event.pressed:
			_lift(event.index)
		else:
			_down(event.index, event.position)
	elif event is InputEventScreenDrag and event.index == stick_id:
		stick_pos = event.position
		_stick_keys()


## Back to how a keyboard player sees the game, until the next touch.
func _sleep() -> void:
	release_all()
	active = false
	main.loc.touch = false
	buttons.clear()
	queue_redraw()
	if tlog != null:
		tlog.asleep(main.loc)


func _down(i: int, p: Vector2) -> void:
	if main.name_open or portrait:
		return
	for b in buttons:
		if b["rect"].grow(6.0).has_point(p):
			btn_of[i] = b["key"]
			_key(b["key"], true)
			return
	if main.state != main.S.PLAY:
		return
	if p.x < 640.0:
		if stick_id == -1:
			stick_id = i
			stick_origin = p
			stick_pos = p
			_stick_keys()
	elif shift_id == -1:
		shift_id = i
		used_shift = true
		_key(KEY_SHIFT, true)


func _lift(i: int) -> void:
	if btn_of.has(i):
		_key(btn_of[i], false)
		btn_of.erase(i)
	if i == stick_id:
		stick_id = -1
		for code in DIRS:
			_key(code, false)
	if i == shift_id:
		shift_id = -1
		_key(KEY_SHIFT, false)


## The stick gives exactly what the arrow keys give: one of 8 directions, or nothing.
func _stick_keys() -> void:
	var v := stick_pos - stick_origin
	var dead := 14.0 * upc
	var reach := 58.0 * upc
	if v.length() > reach:
		stick_origin = stick_pos - v.normalized() * reach      # the base follows the thumb
		v = stick_pos - stick_origin
	var want := {KEY_LEFT: false, KEY_RIGHT: false, KEY_UP: false, KEY_DOWN: false}
	if v.length() >= dead:
		used_stick = true
		var oct := posmod(int(round(v.angle() / (PI / 4.0))), 8)   # 0 right, 2 down, 4 left, 6 up
		want[KEY_RIGHT] = oct == 7 or oct == 0 or oct == 1
		want[KEY_DOWN] = oct == 1 or oct == 2 or oct == 3
		want[KEY_LEFT] = oct == 3 or oct == 4 or oct == 5
		want[KEY_UP] = oct == 5 or oct == 6 or oct == 7
	for code in DIRS:
		if not want[code]:
			_key(code, false)
	for code in DIRS:
		if want[code]:
			_key(code, true)


func _btn(rect: Rect2, key: int, w: String = "", arrow: int = -1) -> void:
	buttons.append({"rect": rect, "key": key, "word": w, "arrow": arrow})


## The buttons of the current screen. Sizes follow the finger size; places are the corners,
## away from the menu texts in the middle.
func _layout() -> void:
	buttons.clear()
	if not active or main.name_open or portrait:
		return
	var h := clampf(46.0 * upc, 58.0, 100.0)
	var w := h * 1.45
	var m := 20.0
	var gap := 10.0
	var by := 720.0 - m - h                 # bottom row
	var by2 := by - gap - h                  # row above it
	var rx := 1280.0 - m                     # right edge
	var S = main.S
	match main.state:
		S.TITLE:
			_btn(Rect2(m, by2, w, h), KEY_UP, "", 0)
			_btn(Rect2(m, by, w, h), KEY_DOWN, "", 1)
			_btn(Rect2(rx - w * 2.0 - gap, by2, w, h), KEY_LEFT, "", 2)
			_btn(Rect2(rx - w, by2, w, h), KEY_RIGHT, "", 3)
			_btn(Rect2(rx - w * 2.0 - gap, by, w * 2.0 + gap, h), KEY_ENTER, "ok")
		S.HOWTO:
			_btn(Rect2(rx - w * 1.6, by, w * 1.6, h), KEY_ESCAPE, "back")
		S.PLAY:
			var ph := clampf(34.0 * upc, 44.0, 64.0)
			_btn(Rect2(330.0, 10.0, ph * 1.25, ph), KEY_ESCAPE, "", 4)
		S.PAUSE:
			_btn(Rect2(m, by2, w, h), KEY_UP, "", 0)
			_btn(Rect2(m, by, w, h), KEY_DOWN, "", 1)
			_btn(Rect2(rx - w * 1.6, by, w * 1.6, h), KEY_ENTER, "ok")
		S.RESULT:
			_btn(Rect2(m, by, w * 1.25, h), KEY_ESCAPE, "title")
			_btn(Rect2(rx - w * 1.25, by, w * 1.25, h), KEY_ENTER, "retry")
			_btn(Rect2(rx - w * 1.25, by2, w * 1.25, h), KEY_TAB, "rank")
			if main.online.enabled:
				_btn(Rect2(m, by2, w * 1.25, h), KEY_N, "name")
				if main.online.sub.get("state", "") == "error":
					_btn(Rect2(m, by2 - gap - h, w * 1.25, h), KEY_S, "send")
		S.RANKING:
			# one row along the bottom, from the right: nothing over the table, its footer or the player's card
			# (the table's last row ends at 616 and its status line is left of 500: lower and a little smaller here)
			h = minf(h, 80.0)
			w = h * 1.45
			by = 720.0 - 12.0 - h
			var x := rx - w
			_btn(Rect2(x, by, w, h), KEY_ESCAPE, "back")
			if main.online.enabled:
				x -= w + gap
				_btn(Rect2(x, by, w, h), KEY_N, "name")
			if main.online.enabled:
				x -= w + gap
				_btn(Rect2(x, by, w, h), KEY_M, "mine")
				x -= w + gap
				_btn(Rect2(x, by, w, h), KEY_R, "refresh")
			x -= w + gap
			_btn(Rect2(x, by, w, h), KEY_DOWN, "", 1)
			x -= w + gap
			_btn(Rect2(x, by, w, h), KEY_UP, "", 0)


func _process(delta: float) -> void:
	if not active:
		return
	clock += delta
	_measure()
	if main.state != last_state:
		last_state = main.state
		release_all()
		if tlog != null:
			tlog.state(main.state)
	if main.name_open and not held.is_empty():
		release_all()
	if portrait:
		if not held.is_empty():
			release_all()
		if main.state == main.S.PLAY:        # holding the phone upright pauses the game
			_key(KEY_ESCAPE, true)
			_key(KEY_ESCAPE, false)
	_layout()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		release_all()


func _tri(c: Vector2, r: float, dir: int, col: Color) -> void:
	var a: float = [-PI / 2.0, PI / 2.0, PI, 0.0][dir]
	var pts := PackedVector2Array()
	for k in 3:
		pts.append(c + Vector2.from_angle(a + k * TAU / 3.0) * r)
	draw_colored_polygon(pts, col)


func _draw() -> void:
	if not active:
		return
	var cyan := Color(0.45, 0.95, 1.0)
	if portrait:
		draw_rect(Rect2(0, 0, 1280, 720), Color(0.02, 0.03, 0.07, 0.92))
		draw_string(font, Vector2(0, 380), word("rotate"), HORIZONTAL_ALIGNMENT_CENTER, 1280, 54, cyan)
		return
	for b in buttons:
		var r: Rect2 = b["rect"]
		var down := held.has(b["key"])
		draw_rect(r, Color(0.03, 0.06, 0.11, 0.8 if down else 0.55))
		draw_rect(r, Color(cyan, 0.95 if down else 0.6), false, 2.0)
		var c := r.get_center()
		if b["arrow"] == 4:                  # pause: two bars
			var bw := r.size.x * 0.12
			draw_rect(Rect2(c.x - bw * 1.6, c.y - r.size.y * 0.24, bw, r.size.y * 0.48), Color(cyan, 0.85))
			draw_rect(Rect2(c.x + bw * 0.6, c.y - r.size.y * 0.24, bw, r.size.y * 0.48), Color(cyan, 0.85))
		elif b["arrow"] >= 0:
			_tri(c, r.size.y * 0.26, b["arrow"], Color(cyan, 0.9))
		else:
			var fs := int(r.size.y * 0.36)
			var tw := font.get_string_size(word(b["word"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			if tw > r.size.x - 14.0:             # a long word on a narrow button: smaller letters, never clipped
				fs = int(fs * (r.size.x - 14.0) / tw)
			draw_string(font, Vector2(r.position.x, c.y + fs * 0.36), word(b["word"]), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, Color(1, 1, 1, 0.95))
	if main.state != main.S.PLAY or main.name_open:
		return
	var reach := 58.0 * upc
	# left thumb: the stick appears where the thumb lands; until then a faint mark shows where to put it
	if stick_id != -1:
		var v := (stick_pos - stick_origin).limit_length(reach)
		draw_arc(stick_origin, reach, 0.0, TAU, 48, Color(cyan, 0.35), 2.0)
		draw_circle(stick_origin + v, reach * 0.42, Color(cyan, 0.30))
	else:
		var hint_c := Vector2(40.0 + reach, 720.0 - 40.0 - reach)
		var a := 0.10 if used_stick else 0.26 + 0.08 * sin(clock * 3.0)
		draw_arc(hint_c, reach, 0.0, TAU, 48, Color(cyan, a), 2.0)
		if not used_stick:
			draw_string(font, Vector2(hint_c.x - reach, hint_c.y + 7.0), word("move"), HORIZONTAL_ALIGNMENT_CENTER, reach * 2.0, int(reach * 0.30), Color(1, 1, 1, a + 0.2))
	# right thumb: anywhere on the right half holds SHIFT; the ring only shows that it is held
	var sc := Vector2(1280.0 - 40.0 - reach, 720.0 - 40.0 - reach)
	var sa := 0.5 if shift_id != -1 else (0.10 if used_shift else 0.26 + 0.08 * sin(clock * 3.0))
	draw_arc(sc, reach, 0.0, TAU, 48, Color(1.0, 0.85, 0.3, sa), 3.0 if shift_id != -1 else 2.0)
	if shift_id != -1 or not used_shift:
		draw_string(font, Vector2(sc.x - reach, sc.y + 7.0), "SHIFT", HORIZONTAL_ALIGNMENT_CENTER, reach * 2.0, int(reach * 0.30), Color(1, 1, 1, sa + 0.2))
