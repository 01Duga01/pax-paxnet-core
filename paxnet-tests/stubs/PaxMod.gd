class_name PaxMod
extends Node
var _settings: Dictionary = {}
var _data: Dictionary = {}
var mod_id: String = "paxnet"
func path(p: String) -> String:
	return "res://mods/%s/%s" % [mod_id, p]
func tr_key(k: String) -> String:
	return k
func get_setting(k: String, def: Variant = null) -> Variant:
	return _settings.get(k, def)
func set_setting(k: String, v: Variant) -> void:
	_settings[k] = v
func save_data(k: String, v: Variant) -> void:
	_data[k] = v
func load_data(k: String, def: Variant = null) -> Variant:
	return _data.get(k, def)
func hook(_name: String, _cb: Callable) -> void:
	pass
func log_warning(m: String) -> void:
	push_warning(m)
func log_info(m: String) -> void:
	print(m)
