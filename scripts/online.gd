extends Node
## Online ranking client. Everything here is asynchronous and optional:
## if the server is away, slow or wrong, the game plays exactly as it does offline.

const Replay = preload("res://scripts/replay.gd")
const ApiConfig = preload("res://scripts/api_config.gd")

## The ranking API address comes from api_config.gd (empty: the page's own origin on the Web;
## elsewhere the ranking is off). The server refuses replays longer than this when encoded:
const MAX_WIRE := 1900000
const TIMEOUT := 8.0
const TICKET_FRESH_MS := 20 * 60 * 1000

var base := ""
var enabled := false
var save_path := "user://countershift_online.cfg"

var player_id := ""
var token := ""
var player_name := ""
var best_score := 0          # last known verified online best
var best_wave := 0

var ticket := {}             # prefetched: {run_id, seed, at}
var ticket_busy := false
var run := {}                # the ticket being played: {run_id, seed}
var recreate_tried := false

var board: Array = []
var board_state := "idle"    # idle / loading / ok / error
var board_total := 0
var board_time := ""
var board_loaded_at := 0.0
var me := {}                 # {rank, score, wave, at, name}
var pending := 0

## state: none / unranked / need_name / sending / verifying / queued / verified / rejected / error / not_best
var sub := {"state": "none"}
var payload := {}
var poll_left := 0
var sub_serial := 0
var diag_cb := Callable()      # set only by the temporary diagnostic overlay


func setup(opts: Dictionary) -> void:
	base = str(opts.get("api", ApiConfig.URL))
	if base == "" and OS.has_feature("web"):
		var origin := str(JavaScriptBridge.eval("window.location.origin", true))
		if origin.begins_with("http"):
			base = origin
	base = base.trim_suffix("/")
	enabled = base != "" and Replay.platform_id() != 0 and not opts.has("offline")
	if opts.has("profile"):
		save_path = "user://countershift_online_%s.cfg" % str(opts["profile"]).validate_filename()
	_load()
	if enabled:
		_ensure_player(prefetch)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) == OK and cfg.get_value("o", "base", "") == base:
		player_id = cfg.get_value("o", "id", "")
		token = cfg.get_value("o", "token", "")
		player_name = cfg.get_value("o", "name", "")
		best_score = cfg.get_value("o", "best", 0)
		best_wave = cfg.get_value("o", "best_wave", 0)
	elif cfg.load(save_path) == OK:
		player_name = cfg.get_value("o", "name", "")     # another server: keep only the name


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("o", "base", base)
	cfg.set_value("o", "id", player_id)
	cfg.set_value("o", "token", token)
	cfg.set_value("o", "name", player_name)
	cfg.set_value("o", "best", best_score)
	cfg.set_value("o", "best_wave", best_wave)
	cfg.save(save_path)


func _auth() -> Dictionary:
	return {"player_id": player_id, "token": token}


## cb(ok: bool, code: int, data: Dictionary). code 0 = no answer (offline, timeout).
func _req(method: int, path: String, body: Variant, cb: Callable, bearer: String = "") -> void:
	if diag_cb.is_valid():
		diag_cb.call("request %s" % path.get_slice("?", 0))
	var h := HTTPRequest.new()
	h.timeout = TIMEOUT
	add_child(h)
	h.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray) -> void:
		h.queue_free()
		var d := {}
		if result == HTTPRequest.RESULT_SUCCESS:
			var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				d = parsed
		var answered := result == HTTPRequest.RESULT_SUCCESS
		if diag_cb.is_valid():
			diag_cb.call("answer %s -> HTTP %d %s" % [path.get_slice("?", 0), code if answered else 0, str(d.get("error", "ok" if d.get("ok", false) else "no answer"))])
		cb.call(answered and code == 200 and d.get("ok", false) == true, code if answered else 0, d))
	var headers := PackedStringArray(["Content-Type: application/json"])
	if bearer != "":
		headers.append("Authorization: Bearer " + bearer)
	var err := h.request(base + path, headers, method, JSON.stringify(body) if body != null else "")
	if err != OK:
		h.queue_free()
		cb.call_deferred(false, 0, {})


func _ensure_player(then: Callable) -> void:
	if player_id != "" and token != "":
		then.call()
		return
	_req(HTTPClient.METHOD_POST, "/v1/player", {}, func(ok: bool, _code: int, d: Dictionary) -> void:
		if ok:
			player_id = str(d.get("player_id", ""))
			token = str(d.get("token", ""))
			best_score = 0
			best_wave = 0
			_save()
			then.call())


func _lost_identity() -> bool:
	# the server no longer knows us (database reset): start again once, as a new player
	if recreate_tried:
		return false
	recreate_tried = true
	player_id = ""
	token = ""
	return true


func prefetch() -> void:
	if not enabled or ticket_busy:
		return
	if not ticket.is_empty() and Time.get_ticks_msec() - int(ticket["at"]) < TICKET_FRESH_MS:
		return
	ticket = {}
	ticket_busy = true
	_ensure_player(func() -> void:
		_req(HTTPClient.METHOD_POST, "/v1/run", _auth(), func(ok: bool, code: int, d: Dictionary) -> void:
			ticket_busy = false
			if ok and int(d.get("build", 0)) == Replay.BUILD:
				ticket = {"run_id": str(d["run_id"]), "seed": int(d["seed"]), "at": Time.get_ticks_msec()}
			elif code == 401 and _lost_identity():
				prefetch()))
	if player_id == "":
		ticket_busy = false


## Called when a run starts. Returns the server's seed, or 0 for an unranked (offline) run.
func take_ticket() -> int:
	run = {}
	if not enabled or ticket.is_empty() or Time.get_ticks_msec() - int(ticket["at"]) > TICKET_FRESH_MS:
		prefetch()
		return 0
	run = ticket
	ticket = {}
	_start_ping(str(run["run_id"]), 3)
	prefetch()
	return int(run["seed"])


func _start_ping(run_id: String, tries: int) -> void:
	var body := _auth()
	body["run_id"] = run_id
	_req(HTTPClient.METHOD_POST, "/v1/run/start", body, func(ok: bool, code: int, _d: Dictionary) -> void:
		if not ok and code == 0 and tries > 1:
			get_tree().create_timer(2.0).timeout.connect(func() -> void: _start_ping(run_id, tries - 1)))


func abandon_run() -> void:
	run = {}


## Called with the finished run. raw is the recorded replay (empty for an unranked run).
func finish_run(score: int, wave: int, raw: PackedByteArray) -> void:
	sub_serial += 1
	payload = {}
	if not enabled:
		sub = {"state": "none"}
		return
	if run.is_empty() or raw.is_empty():
		sub = {"state": "unranked"}
		return
	var run_id := str(run["run_id"])
	run = {}
	if score <= 0:
		sub = {"state": "none"}
		return
	if best_score >= score:
		sub = {"state": "not_best"}
		return
	var wire := Replay.to_wire(raw)
	if wire.length() > MAX_WIRE:
		sub = {"state": "rejected", "reason": "replay_too_large"}      # do not upload what will be refused
		return
	payload = {"run_id": run_id, "score": score, "wave": wave, "replay": wire}
	if player_name == "":
		sub = {"state": "need_name"}
	else:
		send()


func send() -> void:
	if payload.is_empty():
		return
	var serial := sub_serial
	sub = {"state": "sending"}
	var body := _auth()
	body.merge(payload)
	body["name"] = player_name
	_req(HTTPClient.METHOD_POST, "/v1/submit", body, func(ok: bool, code: int, d: Dictionary) -> void:
		if serial != sub_serial:
			return
		if ok and d.get("status", "") == "pending":
			sub = {"state": "verifying", "id": str(d["submission_id"]), "rank": int(d.get("provisional_rank", 0)), "total": int(d.get("total", 0))}
			payload = {}
			poll_left = 30
			_poll(serial)
		elif ok and d.get("status", "") == "not_best":
			payload = {}
			_take_me(d)
			sub = {"state": "not_best"}
		elif code == 0 or code >= 500:
			sub = {"state": "error"}
		elif d.get("error", "") == "run_used":
			payload = {}
			sub = {"state": "queued"}
		else:
			var reason := str(d.get("error", "invalid"))
			if reason != "rate_limited" and reason != "bad_name":
				payload = {}      # (a refused name can be changed and the same record sent again)
			sub = {"state": "rejected", "reason": reason})


func _poll(serial: int) -> void:
	get_tree().create_timer(2.0).timeout.connect(func() -> void:
		if serial != sub_serial or sub.get("state", "") != "verifying":
			return
		var body := _auth()
		body["submission_id"] = sub["id"]
		_req(HTTPClient.METHOD_POST, "/v1/submission", body, func(ok: bool, _code: int, d: Dictionary) -> void:
			if serial != sub_serial or sub.get("state", "") != "verifying":
				return
			if ok and d.get("status", "") == "verified":
				_take_me(d)
				sub = {"state": "verified", "rank": int(me.get("rank", 0)), "total": int(d.get("total", 0))}
			elif ok and d.get("status", "") == "rejected":
				sub = {"state": "rejected", "reason": str(d.get("reason", "invalid")).get_slice(":", 0)}
			else:
				poll_left -= 1
				if poll_left <= 0:
					sub = {"state": "queued"}
				else:
					_poll(serial)))


func _take_me(d: Dictionary) -> void:
	var m: Variant = d.get("me", null)
	if typeof(m) == TYPE_DICTIONARY:
		me = {"rank": int(m["rank"]), "score": int(m["score"]), "wave": int(m["wave"]), "at": int(m["at"]), "name": str(m["name"])}
		best_score = int(m["score"])
		best_wave = int(m["wave"])
		_save()


## Folds what a Japanese keyboard often produces into the plain form the server stores
## (the server does the same with NFKC): full-width letters, digits, marks and space.
static func fold_name(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var c := raw.unicode_at(i)
		if c >= 0xFF01 and c <= 0xFF5E:
			c -= 0xFEE0
		elif c == 0x3000:
			c = 0x20
		out += String.chr(c)
	out = out.strip_edges()
	while out.contains("  "):
		out = out.replace("  ", " ")
	return out


## Why a name cannot be used: "" (it can), "empty", "long" or "chars".
static func name_problem(raw: String) -> String:
	var s := fold_name(raw)
	if s.length() < 1:
		return "empty"
	if s.length() > 12:
		return "long"
	var re := RegEx.new()
	re.compile("^[A-Za-z0-9\\p{Hiragana}\\p{Katakana}\\p{Han}ー・ _.\\-]+$")
	if re.search(s) == null:
		return "chars"
	if s.replace(" ", "").replace("_", "").replace(".", "").replace("-", "").replace("・", "") == "":
		return "chars"
	return ""


## Returns the name as it may be sent, or "" when it cannot be used.
static func clean_name(raw: String) -> String:
	return fold_name(raw) if name_problem(raw) == "" else ""


## Sets the name. If a record is waiting for a name it is sent; otherwise the server is told.
func set_player_name(n: String) -> void:
	player_name = n
	_save()
	if sub.get("state", "") == "need_name" or (sub.get("state", "") == "rejected" and sub.get("reason", "") == "bad_name" and not payload.is_empty()):
		send()
	elif enabled and player_id != "":
		var body := _auth()
		body["name"] = n
		_req(HTTPClient.METHOD_POST, "/v1/name", body, func(ok: bool, _code: int, _d: Dictionary) -> void:
			if ok and board_state == "ok":
				fetch_top())


func fetch_top() -> void:
	if not enabled or board_state == "loading":
		return
	board_state = "loading"
	var path := "/v1/top?limit=100"
	if player_id != "":
		path += "&player=" + player_id.uri_encode()
	_req(HTTPClient.METHOD_GET, path, null, func(ok: bool, _code: int, d: Dictionary) -> void:
		if not ok:
			board_state = "error"
			return
		board = []
		for e: Dictionary in d.get("entries", []):
			board.append({"rank": int(e["rank"]), "name": str(e["name"]), "score": int(e["score"]), "wave": int(e["wave"]), "at": int(e["at"]), "me": e.get("me", false) == true})
		board_total = int(d.get("total", 0))
		pending = int(d.get("pending", 0))
		me = {}
		_take_me(d)
		var now := Time.get_time_dict_from_system()
		board_time = "%02d:%02d" % [now["hour"], now["minute"]]
		board_loaded_at = Time.get_ticks_msec() / 1000.0
		board_state = "ok")
