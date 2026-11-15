extends Node
## Web only: the player's name is typed into a real HTML <input> laid over the game.
##
## Why: Godot 4.7's own text input on the Web loses the "composition ended" event of the macOS
## Japanese IME in Chromium; from then on the engine drops every key, Enter included (seen in a
## real-keyboard diagnostic log, 2026-11-12). A browser's own input field handles the IME itself.
##
## The field exists once, is shown only while the name window is open, and is never rebuilt or
## rewritten while the player types. Its value is only ever read as text (never as HTML).
## Native builds do not use this file.

signal decided(text: String)      # Enter, outside of an IME conversion
signal cancelled                  # Escape
signal edited                     # the text changed

const JS := """
(function () {
  if (window.__csName) return;
  var el = document.createElement('input');
  el.type = 'text';
  el.setAttribute('autocomplete', 'off');
  el.setAttribute('autocorrect', 'off');
  el.setAttribute('autocapitalize', 'off');
  el.setAttribute('spellcheck', 'false');
  el.setAttribute('aria-label', 'name');
  el.maxLength = 32;
  var s = el.style;
  s.position = 'fixed'; s.display = 'none'; s.zIndex = '20'; s.boxSizing = 'border-box';
  s.margin = '0'; s.padding = '0 8px'; s.textAlign = 'center'; s.outline = 'none'; s.borderRadius = '0';
  s.background = '#080f1c'; s.color = '#ffffff'; s.caretColor = '#73f2ff'; s.border = '2px solid #73f2ff';
  s.fontFamily = '"Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic", "Noto Sans JP", "Segoe UI", sans-serif';
  s.fontWeight = '700';
  document.body.appendChild(el);
  // A player on the touch controls (the game says so when it opens the window): there may be no Enter or
  // Escape key worth trusting, and the on-screen keyboard covers half the screen. So the field gets two
  // buttons under the window's notes, a font the browser will not zoom into (16px or more), and it moves
  // to the top while the keyboard is up. A keyboard player gets none of this, touch screen or not.
  var coarse = false;
  var bar = null;
  {
    bar = document.createElement('div');
    bar.style.cssText = 'position:fixed;display:none;z-index:21;gap:8px;';
    var mk = function (label, kind, bg) {
      var b = document.createElement('button');
      b.type = 'button'; b.textContent = label;
      b.style.cssText = 'font:700 16px sans-serif;color:#fff;background:' + bg + ';border:2px solid #73f2ff;border-radius:0;padding:0 14px;height:40px;min-width:64px;touch-action:manipulation;';
      b.addEventListener('click', function (e) {
        e.preventDefault();
        if (kind === 'enter' && st.composing) { note('OK button (IME, ignored)'); return; }
        note(kind === 'enter' ? 'OK button (decide)' : 'cancel button');
        tell(kind);
      });
      bar.appendChild(b);
      return b;
    };
    mk('OK', 'enter', '#0e3a46');
    mk('\u2715', 'escape', '#1a1420');
    document.body.appendChild(bar);
  }
  var st = window.__csName = { el: el, open: false, composing: false, cb: null, log: [], logging: false, coarse: coarse, top: false };
  function note(t) { if (st.logging) { st.log.push(t); if (st.log.length > 200) st.log.shift(); } }
  function tell(kind) { if (st.cb) st.cb(kind); }
  el.addEventListener('compositionstart', function () { st.composing = true; note('compositionstart'); });
  el.addEventListener('compositionend', function () { st.composing = false; note('compositionend'); });
  el.addEventListener('input', function () { note('input (now ' + el.value.length + ' chars)'); tell('input'); });
  el.addEventListener('focus', function () { note('focus'); });
  el.addEventListener('blur', function () {
    note('blur');
    // typing must keep going here (a touch device may put its keyboard away: the field is tapped again to type)
    if (st.open && !coarse) setTimeout(function () { if (st.open) el.focus(); }, 0);
  });
  el.addEventListener('keydown', function (e) {
    e.stopPropagation();                                   // the game never sees what is typed
    if (e.key === 'Enter') {
      // an Enter that belongs to the IME (it confirms a conversion) is not a decision
      if (e.isComposing || e.keyCode === 229 || st.composing) { note('Enter (IME, ignored)'); return; }
      e.preventDefault();
      note('Enter (decide)');
      tell('enter');
    } else if (e.key === 'Escape') {
      if (e.isComposing || e.keyCode === 229 || st.composing) { note('Escape (IME, ignored)'); return; }
      e.preventDefault();
      note('Escape (cancel)');
      tell('escape');
    } else {
      note('key' + (e.isComposing || e.keyCode === 229 ? ' (IME)' : ''));
    }
  });
  el.addEventListener('keyup', function (e) { e.stopPropagation(); });
  el.addEventListener('keypress', function (e) { e.stopPropagation(); });
  st.show = function (text, touch) {
    coarse = st.coarse = !!touch;
    if (coarse) el.setAttribute('enterkeyhint', 'done'); else el.removeAttribute('enterkeyhint');
    if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen();   // an overlay cannot show in fullscreen
    el.value = text;                                        // plain text, set once when the window opens
    st.open = true; st.composing = false;
    s.display = 'block';
    bar.style.display = coarse ? 'flex' : 'none';
    el.focus();
    try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
    note('shown');
  };
  st.hide = function () {
    st.open = false; st.composing = false;
    s.display = 'none';
    if (bar) bar.style.display = 'none';
    el.blur();
    var c = document.getElementById('canvas') || document.querySelector('canvas');
    if (c) c.focus();
    note('hidden');
  };
  // x, y, w, h, font: in the canvas's own pixels (Godot's window coordinates)
  st.place = function (x, y, w, h, font, bad, barY) {
    var c = document.getElementById('canvas') || document.querySelector('canvas');
    if (!c) return;
    var r = c.getBoundingClientRect();
    var k = c.width > 0 ? r.width / c.width : 1;
    s.left = (r.left + x * k) + 'px'; s.top = (r.top + y * k) + 'px';
    s.width = (w * k) + 'px'; s.height = (h * k) + 'px';
    s.fontSize = (font * k) + 'px';
    s.borderWidth = Math.max(1, 2 * h * k / 56) + 'px';
    s.borderColor = bad ? '#ff7380' : '#73f2ff';
    if (!coarse) return;
    st.last = [x, y, w, h, font, bad, barY];
    if (parseFloat(s.fontSize) < 16) s.fontSize = '16px';        // below 16px iOS zooms the page when the field is focused
    var vv = window.visualViewport;
    st.top = !!vv && vv.height < window.innerHeight - 80;        // the on-screen keyboard is up
    if (st.top) {                                                // keep the field and the buttons above the keyboard
      var fw = Math.min(360, vv.width - 190);
      s.left = (vv.offsetLeft + 8) + 'px'; s.top = (vv.offsetTop + 8) + 'px';
      s.width = fw + 'px'; s.height = '40px'; s.fontSize = '18px';
      bar.style.left = (vv.offsetLeft + 16 + fw) + 'px'; bar.style.top = (vv.offsetTop + 8) + 'px';
    } else {
      var er = el.getBoundingClientRect();
      // under the window's notes, where a keyboard player reads "ENTER / ESC" (the game leaves that line out)
      bar.style.left = Math.max(4, er.left + er.width / 2 - (bar.offsetWidth || 144) / 2) + 'px';
      bar.style.top = Math.min(window.innerHeight - 44, r.top + barY * k) + 'px';
    }
  };
  if (window.visualViewport) {
    var again = function () { if (st.open && coarse && st.last) st.place.apply(null, st.last); };
    window.visualViewport.addEventListener('resize', again);
    window.visualViewport.addEventListener('scroll', again);
  }
  st.state = function () { return (document.activeElement === el ? '1' : '0') + (st.composing ? '1' : '0') + el.value.length; };
})();
"""

var is_open := false
var _cb: JavaScriptObject
var _st: JavaScriptObject
var _placed := ""


func _ready() -> void:
	JavaScriptBridge.eval(JS, true)
	_st = JavaScriptBridge.get_interface("__csName")
	_cb = JavaScriptBridge.create_callback(_on_js)      # kept in a member: the bridge needs it alive
	_st.cb = _cb


func _on_js(args: Array) -> void:
	if not is_open:
		return
	match str(args[0]):
		"enter": decided.emit(text())
		"escape": cancelled.emit()
		"input": edited.emit()


## touch: the player is on the touch controls (OK and cancel buttons, on-screen keyboard manners).
func show_field(initial: String, touch: bool = false) -> void:
	is_open = true
	_placed = ""
	_st.show(initial, touch)


func hide_field() -> void:
	if is_open:
		is_open = false
		_st.hide()


func text() -> String:
	return str(_st.el.value)


## Keeps the field exactly over `rect` (window pixels), whatever the zoom or window size.
func place(rect: Rect2, font_px: float, bad: bool, bar_y: float = 0.0) -> void:
	var key := "%s|%.2f|%s|%.1f" % [str(rect), font_px, bad, bar_y]
	var canvas_key := str(JavaScriptBridge.eval("(function(){var c=document.getElementById('canvas')||document.querySelector('canvas');var r=c.getBoundingClientRect();return [r.left,r.top,r.width,c.width].join(',')})()", true))
	key += canvas_key
	if key == _placed:
		return
	_placed = key
	_st.place(rect.position.x, rect.position.y, rect.size.x, rect.size.y, font_px, bad, bar_y)


## For the diagnostic overlay only: [has focus, IME converting, number of characters].
func state() -> Array:
	var s := str(_st.state())
	return [s.substr(0, 1) == "1", s.substr(1, 1) == "1", int(s.substr(2))]


func set_logging(on: bool) -> void:
	_st.logging = on


## For the diagnostic overlay only: kinds of events since the last call (never characters).
func drain() -> PackedStringArray:
	var out := str(JavaScriptBridge.eval("(function(){var s=window.__csName;var q=s.log.join('|');s.log=[];return q})()", true))
	return out.split("|", false)
