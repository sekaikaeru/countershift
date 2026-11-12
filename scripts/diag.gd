extends Control
## TEMPORARY diagnostic overlay for the name entry (local builds only).
## It is switched on with ?diag=1 and exists only in development exports: the production export
## preset leaves this file out, and a production build ignores the option anyway.
##
## It shows, and reports to the local test server, what happens between the keyboard and the name
## being accepted: browser key and composition events, what reaches Godot, the field's state, the
## decision, and the API calls. It never records which characters were typed or the name itself:
## only kinds of keys ("char", "Enter", ...) and lengths.

const MAX_LINES := 15

var main: Node
var font: Font
var lines: Array[String] = []
var counts := {}
var seq := 0
var button := Rect2(1010, 300, 250, 46)
var web := false
var post_queue: Array[String] = []
var posting := false
var last_state := ""
var js_focus := "?"
var js_ime := "?"
var clock := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	web = OS.has_feature("web")
	if web:
		JavaScriptBridge.eval("""
(function(){ if (window.__csd) return; var d = window.__csd = { q: [] };
 function cat(e){ var k = e.key || ''; if (k === ' ') return 'Space';
   if (['Enter','Escape','Backspace','Tab','Process','Shift','Control','Alt','Meta','Unidentified','Dead','Eisu','KanaMode','Lang1','Lang2','Convert','NonConvert','F2'].indexOf(k) >= 0 || k.indexOf('Arrow') === 0) return k;
   return k.length === 1 ? 'char' : 'other'; }
 function tgt(e){ var t = e.target; if (!t || !t.tagName) return '?'; if (t.tagName === 'CANVAS') return 'canvas'; if (t.className === 'ime') return 'imebox'; return t.tagName.toLowerCase(); }
 function rec(e){ var s;
   if (e.type.indexOf('composition') === 0) s = e.type + ' len=' + ((e.data || '').length);
   else if (e.type === 'keydown' || e.type === 'keyup') s = e.type + ' ' + cat(e) + (e.isComposing ? ' composing' : '') + (e.keyCode === 229 ? ' code229' : '') + (e.repeat ? ' repeat' : '');
   else s = e.type;
   d.q.push(s + ' @' + tgt(e)); if (d.q.length > 200) d.q.shift(); }
 ['keydown','keyup','compositionstart','compositionend','focusin','focusout'].forEach(function(t){ document.addEventListener(t, rec, true); });
 var ua = navigator.userAgent; var b = /Edg\\//.test(ua) ? 'Edge' : /OPR\\//.test(ua) ? 'Opera' : /Firefox\\//.test(ua) ? 'Firefox' : /Chrome\\//.test(ua) ? 'Chromium-based' : /Safari\\//.test(ua) ? 'Safari/WebKit' : 'other';
 d.browser = b + (/Mac/.test(ua) ? ' on macOS' : '');
})();""", true)
		note("browser: " + str(JavaScriptBridge.eval("window.__csd.browser", true)))
	else:
		note("native build (no browser events)")
	main.name_edit.text_changed.connect(func(t: String) -> void: note("field: text changed, now %d chars" % t.length()))
	main.name_edit.text_submitted.connect(func(_t: String) -> void: note("field: text_submitted signal"))
	main.name_edit.focus_entered.connect(func() -> void: note("field: got focus"))
	main.name_edit.focus_exited.connect(func() -> void: note("field: LOST focus"))
	main.name_edit.editing_toggled.connect(func(on: bool) -> void: note("field: editing " + ("ON" if on else "OFF")))
	main.name_edit.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventKey and e.pressed:
			count("field got key"))
	main.online.diag_cb = func(text: String) -> void: note("api: " + text)
	if main.web_name != null:
		main.web_name.set_logging(true)
		note("name field: HTML input (browser handles the IME)")
	else:
		note("name field: Godot LineEdit")


func count(what: String) -> void:
	counts[what] = int(counts.get(what, 0)) + 1


## One diagnostic line: shown on screen and sent to the local test server.
func note(text: String) -> void:
	seq += 1
	var line := "%03d %s" % [seq, text]
	lines.append(line)
	if lines.size() > MAX_LINES:
		lines.pop_front()
	print("DIAG " + line)
	post_queue.append(line)
	_pump()


func _pump() -> void:
	if not web or posting or post_queue.is_empty():
		return
	posting = true
	var body := "\n".join(post_queue.map(func(l: String) -> String: return "DIAG " + l))
	post_queue.clear()
	var h := HTTPRequest.new()
	h.timeout = 4.0
	add_child(h)
	h.request_completed.connect(func(_a: int, _b: int, _c: PackedStringArray, _d: PackedByteArray) -> void:
		h.queue_free()
		posting = false
		_pump())
	var origin := str(JavaScriptBridge.eval("window.location.origin", true))
	if h.request(origin + "/__report", PackedStringArray(["Content-Type: text/plain"]), HTTPClient.METHOD_POST, body) != OK:
		h.queue_free()
		posting = false


## Called by main.gd for every key event Godot receives.
func key_seen(e: InputEventKey) -> void:
	var kind := "other"
	match e.keycode:
		KEY_ENTER, KEY_KP_ENTER: kind = "Enter"
		KEY_ESCAPE: kind = "Escape"
		KEY_BACKSPACE: kind = "Backspace"
		KEY_F2: kind = "F2"
		KEY_SPACE: kind = "Space"
		KEY_SHIFT: kind = "Shift"
		KEY_NONE: kind = "char (text only)" if e.unicode != 0 else "none"
		_: kind = "char" if e.unicode >= 32 else "other"
	if not e.pressed:
		return
	note("godot: key %s%s" % [kind, " (repeat)" if e.echo else ""])


func _input(event: InputEvent) -> void:
	if not main.name_open:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		note("TEST: decide with F2")
		get_viewport().set_input_as_handled()
		main._name_submitted(main.name_text())
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and button.has_point(event.position):
		note("TEST: decide with the button")
		get_viewport().set_input_as_handled()
		main._name_submitted(main.name_text())


func _process(delta: float) -> void:
	clock += delta
	if web:
		var raw := str(JavaScriptBridge.eval("(function(){var d=window.__csd;var q=d.q.join('|');d.q=[];var a=document.activeElement;var i=document.querySelector('.ime');return q+'~'+(a?(a.tagName==='CANVAS'?'canvas':(a.className==='ime'?'imebox':a.tagName.toLowerCase())):'none')+'~'+(i?(i.style.display||'shown'):'missing')})()", true))
		var parts := raw.split("~")
		if parts.size() == 3:
			js_focus = parts[1]
			js_ime = parts[2]
			if parts[0] != "" and main.name_open:
				for ev in parts[0].split("|"):
					if not ev.ends_with("@input"):          # the HTML field reports its own events
						note("browser: " + ev)
	if main.web_name != null:
		for ev in main.web_name.drain():
			note("html: " + ev)
	if main.name_open:
		var e: LineEdit = main.name_edit
		var st := ""
		if main.web_name != null:
			var ws: Array = main.web_name.state()
			st = "HTML field focus=%s | IME converting=%s | chars=%d | refused=%s | godot IME state=%s" % [
				ws[0], ws[1], ws[2], main.name_error if main.name_error != "" else "-", DisplayServer.ime_get_text() != ""]
		else:
			st = "field focus=%s editing=%s chars=%d | IME composing=%s (%d) | refused=%s | browser focus=%s imebox=%s" % [
				e.has_focus(), e.is_editing(), e.text.length(), DisplayServer.ime_get_text() != "", DisplayServer.ime_get_text().length(),
				main.name_error if main.name_error != "" else "-", js_focus, js_ime]
		if st != last_state:
			last_state = st
			note("state: " + st)
	elif last_state != "":
		last_state = ""
		note("state: name window CLOSED (name set: %s, online: %s)" % [main.online.player_name != "", main.online.sub.get("state", "-")])
	queue_redraw()


func _draw() -> void:
	var w := 470.0
	var x := 1280.0 - w - 8.0
	var h := 20.0 + MAX_LINES * 15.0 + 40.0
	draw_rect(Rect2(x, 8, w, h), Color(0, 0, 0, 0.82))
	draw_rect(Rect2(x, 8, w, h), Color(1, 0.8, 0.2, 0.9), false, 1.5)
	draw_string(font, Vector2(x + 8, 24), "DIAGNOSTIC BUILD (local only) — keys are logged by kind, never by character", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.8, 0.2))
	var y := 42.0
	for l in lines:
		var col := Color(0.85, 0.9, 1.0)
		if l.contains("godot:"):
			col = Color(0.5, 1.0, 0.6)
		elif l.contains("browser:"):
			col = Color(0.6, 0.85, 1.0)
		elif l.contains("DECIDE") or l.contains("TEST") or l.contains("api:"):
			col = Color(1, 0.9, 0.4)
		draw_string(font, Vector2(x + 8, y), l.left(76), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
		y += 15.0
	draw_string(font, Vector2(x + 8, 8 + h - 26), "sent to local log: %d lines | field keys: %d" % [seq, int(counts.get("field got key", 0))], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.7, 0.7))
	draw_string(font, Vector2(x + 8, 8 + h - 10), "tests: F2 = decide without Enter   |   click the yellow button = decide", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.7, 0.7))
	if main.name_open:
		draw_rect(button, Color(1, 0.8, 0.2, 0.25 + 0.1 * sin(clock * 4.0)))
		draw_rect(button, Color(1, 0.8, 0.2), false, 2.0)
		draw_string(font, button.position + Vector2(16, 30), "決定（診断用ボタン）", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 0.9, 0.5))
