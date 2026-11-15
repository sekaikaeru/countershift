extends RefCounted
## Tests only: prints what the touch layer (scripts/touch.gd) does, for tools/touch_check.mjs.
## Switched on by ?touchlog=1, and only where this file exists: the release export preset "WebProd"
## leaves it out, the test preset "WebTest" (tools/build_web.sh ... WebTest, local API only) keeps it.


func key(code: int, down: bool) -> void:
	print("TOUCHKEY %s %s" % [OS.get_keycode_string(code), "down" if down else "up"])


func woke(upc: float, portrait: bool, loc: RefCounted) -> void:
	print("TOUCH active upc=%.2f portrait=%s" % [upc, portrait])
	words(loc)


func asleep(loc: RefCounted) -> void:
	print("TOUCH asleep (keyboard)")
	words(loc)


func state(n: int) -> void:
	print("TOUCH state %d" % n)


## Which wording the screens use right now.
func words(loc: RefCounted) -> void:
	print("TOUCH words touch=%s lang=%s | %s" % [loc.touch, loc.lang, " | ".join(["nav", "r_nav", "rk_nav", "how_back", "how1_b", "how2_h", "how_note", "hint1", "hint2", "tip4", "on_need_name"].map(func(k): return "%s=[%s]" % [k, loc.t(k).replace("\n", " ")]))])
