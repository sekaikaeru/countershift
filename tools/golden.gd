extends SceneTree
## Prints the behaviour fingerprint. Compare with docs/golden-baseline.txt.
## Usage: godot --headless --path . -s tools/golden.gd

const SelfTest = preload("res://scripts/selftest.gd")


func _init() -> void:
	for skill in [1.0, 0.3]:
		for g in 8:
			print(SelfTest.golden_line(skill, g))
	quit()
