extends "res://mods/paxnet_core/core/Adapter.gd"
## Мир из разделов-словарей для теста синхронизации (режим «мир считает хост»).
const StateHash = preload("res://mods/paxnet_core/core/StateHash.gd")
const Bytes = preload("res://mods/paxnet_core/core/Bytes.gd")
var sections: Dictionary = {}
var day: int = 0
var installed: int = 0
var notices: Array = []

func section_names() -> Array:
	var k: Array = sections.keys()
	k.sort()
	return k

func hashes(_tick: int, _all: bool = false) -> Dictionary:
	var h: Dictionary = {}
	for n in sections:
		h[n] = StateHash.short(sections[n])
	return h

func section_data(names: Array) -> Dictionary:
	var out: Dictionary = {}
	for n in names:
		if sections.has(n):
			out[n] = (sections[n] as Dictionary).duplicate(true)
	return out

func apply_sections(data: Dictionary) -> void:
	for n in data:
		sections[n] = data[n]

func world_snapshot() -> PackedByteArray:
	return Bytes.encode({"s": sections, "d": day})

func install_world(b: PackedByteArray) -> bool:
	var d: Dictionary = Bytes.decode(b)
	if not bool(d["ok"]):
		return false
	var v: Dictionary = d["v"]
	sections = v["s"]
	day = int(v["d"])
	installed += 1
	return true

func current_day() -> int:
	return day

func countries() -> Array:
	return [{"id": 0, "name": "A"}, {"id": 1, "name": "B"}, {"id": 2, "name": "C"}]

func on_notice(code: String, _args: Dictionary) -> void:
	notices.append(code)
