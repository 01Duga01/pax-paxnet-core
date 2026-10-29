extends Node
func _ready() -> void:
	var bad: int = 0
	var files: Array = []
	_walk("res://mods/paxnet", files)
	for f in files:
		var s: Variant = load(f)
		if s == null or not (s is Script) or not (s as Script).can_instantiate():
			print("FAIL ", f)
			bad += 1
	print("compiled ", files.size(), " failed ", bad)
	print("ZSTD check: ", FileAccess.COMPRESSION_ZSTD, " DEFLATE: ", FileAccess.COMPRESSION_DEFLATE)
	get_tree().quit(1 if bad > 0 else 0)
func _walk(d: String, out: Array) -> void:
	for f in ResourceLoader.list_directory(d):
		if f.ends_with("/"):
			_walk(d + "/" + f.trim_suffix("/"), out)
		elif f.ends_with(".gd"):
			out.append(d + "/" + f)
