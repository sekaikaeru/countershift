extends Node
## Every sound is synthesized at start-up; the project ships no audio files.

const SR := 22050
const LOOP_N := 336000       # 8 bars at 126 BPM
const STEP := 2625           # one 16th note

signal progress(p: float)

var sfx := {}
var players: Array[AudioStreamPlayer] = []
var next_player := 0
var music: AudioStreamPlayer
var sync: AudioStreamSynchronized
var stem_vol: Array[float] = [0.0, 0.0, 0.0, 0.0]
var stem_goal: Array[float] = [0.0, 0.0, 0.0, 0.0]
var lowpass: AudioEffectLowPassFilter
var focus_amt := 0.0
var ready_ok := false
var rng := RandomNumberGenerator.new()
var last_played := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rng.seed = 4242
	AudioServer.add_bus()
	AudioServer.set_bus_name(1, "Music")
	AudioServer.add_bus()
	AudioServer.set_bus_name(2, "Sfx")
	lowpass = AudioEffectLowPassFilter.new()
	lowpass.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(1, lowpass)
	for i in 14:
		var p := AudioStreamPlayer.new()
		p.bus = "Sfx"
		add_child(p)
		players.append(p)
	music = AudioStreamPlayer.new()
	music.bus = "Music"
	add_child(music)


func set_volume(v: float) -> void:
	AudioServer.set_bus_mute(0, v <= 0.001)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v, 0.001)))


func play(name: String, pitch: float = 1.0, vol_db: float = 0.0) -> void:
	if not sfx.has(name):
		return
	var now := Time.get_ticks_msec()
	if now - int(last_played.get(name, -1000)) < 35:
		return
	last_played[name] = now
	var p := players[next_player]
	next_player = (next_player + 1) % players.size()
	p.stream = sfx[name]
	p.pitch_scale = clampf(pitch, 0.3, 3.0)
	p.volume_db = vol_db
	p.play()


## mode: 0 = title, 1 = play, heat 0..1 = how intense the fight is
func set_music(mode: int, heat: float) -> void:
	if mode == 0:
		stem_goal = [0.85, 0.0, 0.0, 0.5]
	else:
		stem_goal = [0.55, 0.9, 0.85, clampf(heat * 1.4, 0.0, 1.0)]


func set_focus(a: float) -> void:
	focus_amt = a


func _process(delta: float) -> void:
	if not ready_ok:
		return
	for i in 4:
		stem_vol[i] = move_toward(stem_vol[i], stem_goal[i], delta * 0.9)
		sync.set_sync_stream_volume(i, linear_to_db(maxf(stem_vol[i], 0.0005)))
	music.pitch_scale = lerpf(1.0, 0.62, focus_amt)
	lowpass.cutoff_hz = lerpf(18000.0, 650.0, pow(focus_amt, 0.6))


# ---------------------------------------------------------------- synthesis

func _wav(buf: PackedFloat32Array, loop: bool = false, rate: int = SR) -> AudioStreamWAV:
	var n := buf.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	return w


func _render(dur: float, f: Callable) -> AudioStreamWAV:
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	for i in n:
		buf[i] = f.call(float(i) / SR, float(i) / n)
	# short fade at the end so nothing clicks
	for i in mini(200, n):
		buf[n - 1 - i] *= float(i) / 200.0
	return _wav(buf)


func _sweep(t: float, f0: float, f1: float, dur: float) -> float:
	# phase of an exponential sweep from f0 to f1 over dur
	var k := log(f1 / f0) / dur
	return TAU * f0 * (exp(k * t) - 1.0) / k


func _sq(ph: float) -> float:
	return 1.0 if fposmod(ph, TAU) < PI else -1.0


func _saw(ph: float) -> float:
	return fposmod(ph, TAU) / PI - 1.0


func generate() -> void:
	var lp := [0.0]
	var nz := func() -> float: return rng.randf() * 2.0 - 1.0
	var lpn := func(a: float) -> float:
		lp[0] += (rng.randf() * 2.0 - 1.0 - lp[0]) * a
		return lp[0]

	sfx["ui_move"] = _render(0.05, func(t: float, u: float) -> float: return sin(TAU * 1300.0 * t) * (1.0 - u) * 0.3)
	sfx["ui_ok"] = _render(0.16, func(t: float, u: float) -> float: return (sin(_sweep(t, 600.0, 1400.0, 0.16)) * 0.35 + _sq(_sweep(t, 300.0, 700.0, 0.16)) * 0.08) * (1.0 - u))
	sfx["empty"] = _render(0.12, func(t: float, u: float) -> float: return _sq(TAU * 95.0 * t) * 0.22 * (1.0 - u))
	sfx["focus_in"] = _render(0.3, func(t: float, u: float) -> float: return (sin(_sweep(t, 1100.0, 160.0, 0.3)) * 0.4 + lpn.call(0.2) * 0.25) * pow(1.0 - u, 1.5))
	sfx["shift"] = _render(0.34, func(t: float, u: float) -> float:
		var zap := _saw(_sweep(t, 2400.0, 90.0, 0.34)) * exp(-t * 11.0) * 0.5
		var sub := sin(_sweep(t, 150.0, 45.0, 0.34)) * exp(-t * 7.0) * 0.8
		var click: float = nz.call() * exp(-t * 90.0) * 0.6
		return zap + sub + click)
	sfx["kill"] = _render(0.3, func(t: float, u: float) -> float:
		return lpn.call(0.5) * exp(-t * 16.0) * 0.6 + _sq(_sweep(t, 420.0, 900.0, 0.3)) * exp(-t * 14.0) * 0.22 + sin(TAU * 60.0 * t) * exp(-t * 12.0) * 0.5)
	sfx["shiftkill"] = _render(0.45, func(t: float, u: float) -> float:
		var bell := (sin(TAU * 880.0 * t) + sin(TAU * 1320.0 * t) * 0.6 + sin(TAU * 1760.0 * t) * 0.3) * exp(-t * 7.0) * 0.26
		return bell + lpn.call(0.6) * exp(-t * 20.0) * 0.5 + sin(_sweep(t, 110.0, 40.0, 0.45)) * exp(-t * 9.0) * 0.6)
	sfx["nova"] = _render(0.4, func(t: float, u: float) -> float: return sin(_sweep(t, 70.0, 260.0, 0.4)) * exp(-t * 8.0) * 0.5 + lpn.call(0.12) * exp(-t * 9.0) * 0.5)
	sfx["explode"] = _render(0.8, func(t: float, u: float) -> float:
		return lpn.call(0.18 * exp(-t * 3.0) + 0.02) * exp(-t * 4.5) * 1.6 + sin(_sweep(t, 90.0, 28.0, 0.8)) * exp(-t * 4.0) * 0.9)
	sfx["shot"] = _render(0.1, func(t: float, u: float) -> float: return _sq(_sweep(t, 760.0, 280.0, 0.1)) * (1.0 - u) * 0.2)
	sfx["charge_up"] = _render(0.8, func(t: float, u: float) -> float: return _saw(_sweep(t, 90.0, 520.0, 0.8)) * u * 0.3 * (0.6 + 0.4 * sin(TAU * 22.0 * t)))
	sfx["dash"] = _render(0.32, func(t: float, u: float) -> float: return lpn.call(0.08 + u * 0.4) * sin(PI * u) * 0.9 + sin(_sweep(t, 240.0, 70.0, 0.32)) * (1.0 - u) * 0.4)
	sfx["thud"] = _render(0.28, func(t: float, u: float) -> float: return sin(_sweep(t, 110.0, 36.0, 0.28)) * exp(-t * 10.0) * 1.0 + nz.call() * exp(-t * 70.0) * 0.5)
	sfx["laser_charge"] = _render(1.3, func(t: float, u: float) -> float: return sin(_sweep(t, 260.0, 1500.0, 1.3) + sin(TAU * 31.0 * t) * 1.5) * u * u * 0.32)
	sfx["laser"] = _render(0.4, func(t: float, u: float) -> float:
		return (_saw(TAU * 174.0 * t) + _saw(TAU * 176.5 * t) + _sq(TAU * 87.0 * t)) * 0.2 * pow(1.0 - u, 0.6) + lpn.call(0.7) * exp(-t * 12.0) * 0.5)
	sfx["fuse"] = _render(1.0, func(t: float, u: float) -> float:
		var rate := 5.0 + u * 16.0
		return _sq(TAU * 1250.0 * t) * (0.2 if fposmod(t * rate * (1.0 + u), 1.0) < 0.35 else 0.0))
	sfx["hurt"] = _render(0.55, func(t: float, u: float) -> float: return _sq(_sweep(t, 420.0, 70.0, 0.55)) * (1.0 - u) * 0.3 + lpn.call(0.3) * exp(-t * 7.0) * 0.8)
	sfx["dead"] = _render(1.6, func(t: float, u: float) -> float:
		return _saw(_sweep(t, 520.0, 30.0, 1.6)) * pow(1.0 - u, 1.2) * 0.35 + lpn.call(0.1) * exp(-t * 2.2) * 1.2 + sin(_sweep(t, 80.0, 25.0, 1.6)) * exp(-t * 2.0) * 0.8)
	sfx["spawn"] = _render(0.3, func(t: float, u: float) -> float: return sin(_sweep(t, 260.0, 620.0, 0.3)) * sin(PI * u) * 0.14)
	sfx["bite"] = _render(0.1, func(t: float, u: float) -> float: return nz.call() * (1.0 if fposmod(t * 90.0, 1.0) < 0.5 else 0.2) * (1.0 - u) * 0.4)
	sfx["spark"] = _render(0.05, func(t: float, u: float) -> float: return nz.call() * (1.0 - u) * 0.1)
	var arp := func(notes: Array, t: float, each: float) -> float:
		var idx := mini(int(t / each), notes.size() - 1)
		var lt := t - idx * each
		var f: float = notes[idx]
		return (sin(TAU * f * lt) + _sq(TAU * f * lt) * 0.2) * exp(-lt * 9.0) * 0.3
	sfx["wave"] = _render(0.6, func(t: float, u: float) -> float: return arp.call([440.0, 523.25, 659.25, 880.0], t, 0.09))
	sfx["clear"] = _render(0.8, func(t: float, u: float) -> float: return arp.call([523.25, 659.25, 783.99, 1046.5, 1318.5], t, 0.085))
	sfx["heal"] = _render(0.5, func(t: float, u: float) -> float: return arp.call([659.25, 987.77], t, 0.14))
	sfx["burst"] = _render(0.7, func(t: float, u: float) -> float: return arp.call([880.0, 1108.7, 1318.5, 1760.0, 2217.5, 2637.0], t, 0.06) * 0.9)
	sfx["record"] = _render(1.2, func(t: float, u: float) -> float: return arp.call([523.25, 659.25, 783.99, 1046.5, 783.99, 1046.5, 1318.5, 1568.0], t, 0.1))
	progress.emit(0.2)
	await get_tree().process_frame
	await _music()
	ready_ok = true
	progress.emit(1.0)


func _add_note(buf: PackedFloat32Array, start: int, length: int, freq: float, amp: float, kind: int, div: int = 1) -> void:
	start /= div
	length /= div
	var total := buf.size()
	var inc := freq * div / SR
	var ph := 0.0
	var lp := 0.0
	var inv := 1.0 / length
	if kind == 0:      # bass: saw + sub through a closing filter
		for i in length:
			var u := i * inv
			ph += inc
			var s := (ph - floorf(ph)) * 2.0 - 1.0
			lp += (s - lp) * (0.05 + 0.3 * exp(-u * 5.0))
			var env := minf(1.0, i * 0.02) * (1.0 - u * u)
			var k := posmod(start + i, total)
			buf[k] += (lp + sin(ph * PI)) * env * amp
	elif kind == 1:    # arp pluck
		for i in length:
			var u := i * inv
			ph += inc
			var s := (ph - floorf(ph)) * 2.0 - 1.0
			lp += (s - lp) * (0.06 + 0.55 * exp(-u * 7.0))
			var k := posmod(start + i, total)
			buf[k] += lp * exp(-u * 4.5) * minf(1.0, i * 0.02) * amp
	else:              # pad: two detuned voices, slow in and out
		var ph2 := 0.0
		var inc2 := inc * 1.006
		for i in length:
			var u := i * inv
			ph += inc
			ph2 += inc2
			var env := sin(PI * u)
			var k := posmod(start + i, total)
			buf[k] += (sin(ph * TAU) + sin(ph2 * TAU)) * env * amp


func _music() -> void:
	var stems: Array[PackedFloat32Array] = []
	for i in 4:
		var b := PackedFloat32Array()
		b.resize(LOOP_N / 2 if (i == 0 or i == 2) else LOOP_N)
		stems.append(b)
	var roots := [110.0, 87.31, 73.42, 82.41]                         # A, F, D, E
	var chords := [[220.0, 261.63, 329.63], [174.61, 220.0, 261.63], [146.83, 174.61, 220.0], [164.81, 207.65, 246.94]]
	var bar := STEP * 16
	# pad
	for c in 4:
		for f in chords[c]:
			_add_note(stems[0], c * bar * 2 - 3000, bar * 2 + 9000, f, 0.08, 2, 2)
		_add_note(stems[0], c * bar * 2, bar * 2, roots[c] * 0.5, 0.1, 2, 2)
		await get_tree().process_frame
	progress.emit(0.4)
	# drums
	var d := stems[1]
	for beat in 32:
		var s := beat * STEP * 4
		for i in 5200:
			var t := float(i) / SR
			d[(s + i) % LOOP_N] += sin(TAU * (48.0 * t + 14.0 * (1.0 - exp(-t * 28.0)))) * exp(-t * 11.0) * 0.95
		if beat % 2 == 1:
			var lp := 0.0
			for i in 4200:
				var t := float(i) / SR
				var n := rng.randf() * 2.0 - 1.0
				lp += (n - lp) * 0.6
				d[(s + i) % LOOP_N] += lp * exp(-t * 20.0) * 0.5 + sin(TAU * 185.0 * t) * exp(-t * 30.0) * 0.3
		for h in 4:
			var hs := s + h * STEP
			var ha := 0.2 if h == 2 else (0.07 if h % 2 == 1 else 0.05)
			var prev := 0.0
			for i in 1300:
				var n := rng.randf() * 2.0 - 1.0
				d[(hs + i) % LOOP_N] += (n - prev) * exp(-float(i) / SR * (55.0 if h != 2 else 30.0)) * ha
				prev = n
		if beat % 8 == 7:
			await get_tree().process_frame
	progress.emit(0.6)
	# bass
	var pat := [1.0, 0.0, 1.0, 2.0, 0.0, 1.0, 2.0, 1.0, 1.0, 0.0, 1.0, 2.0, 0.0, 2.0, 1.0, 2.0]
	for b in 8:
		var root: float = roots[b / 2]
		for st in 16:
			if pat[st] > 0.0:
				_add_note(stems[2], b * bar + st * STEP, int(STEP * 1.5), root * pat[st], 0.24, 0, 2)
		await get_tree().process_frame
	progress.emit(0.8)
	# arp, with an echo three steps later
	var order := [0, 2, 4, 2, 3, 2, 4, 5, 0, 2, 4, 2, 5, 4, 3, 2]
	for b in 8:
		var ch: Array = chords[b / 2]
		var tones := [ch[0] * 2.0, ch[1] * 2.0, ch[2] * 2.0, ch[0] * 4.0, ch[1] * 4.0, ch[2] * 4.0]
		for st in 16:
			var f: float = tones[order[(st + b * 5) % 16] if b % 2 == 1 else order[st]]
			var a := 0.13 if st % 4 == 0 else 0.09
			_add_note(stems[3], b * bar + st * STEP, STEP * 3, f, a, 1)
			_add_note(stems[3], b * bar + (st + 3) * STEP, STEP * 3, f, a * 0.35, 1)
		await get_tree().process_frame
	sync = AudioStreamSynchronized.new()
	sync.stream_count = 4
	for i in 4:
		sync.set_sync_stream(i, _wav(stems[i], true, SR / 2 if (i == 0 or i == 2) else SR))
		sync.set_sync_stream_volume(i, -60.0)
		await get_tree().process_frame
	music.stream = sync
	music.volume_db = -5.0
	music.play()
