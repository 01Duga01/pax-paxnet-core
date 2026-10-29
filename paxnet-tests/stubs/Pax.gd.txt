extends Node
signal world_stepped(game: Variant, from_day: int, days: int)
var game: Variant = null
func register_command(_n: String, _c: Callable, _h: String = "") -> void:
	pass
func get_mod(_id: String) -> Variant:
	return null
