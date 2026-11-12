extends Node2D
## A draw surface: the owner supplies the drawing function.

var fn: Callable


func _draw() -> void:
	if fn.is_valid():
		fn.call(self)
