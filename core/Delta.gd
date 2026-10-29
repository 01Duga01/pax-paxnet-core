extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Разница раздела мира между двумя шагами: для словаря — изменённые и удалённые ключи верхнего
# уровня (глубже — целиком), остальное — целиком. base — сумма раздела, к которому разница применима:
# не совпала у гостя — он просит раздел целиком.

const StateHash = preload("res://mods/paxnet_core/core/StateHash.gd")


static func diff(old, new) -> Dictionary:
	if not (old is Dictionary) or not (new is Dictionary):
		return {"full": new}
	var set := {}
	var del: Array = []
	for k in new:
		if not old.has(k) or StateHash.of(old[k]) != StateHash.of(new[k]):
			set[k] = new[k]
	for k in old:
		if not new.has(k):
			del.append(k)
	# если поменялась большая часть — дешевле целиком
	if set.size() > (new as Dictionary).size() * 0.6 and (new as Dictionary).size() > 8:
		return {"full": new}
	return {"set": set, "del": del, "base": StateHash.short(old)}


static func is_empty(d: Dictionary) -> bool:
	return not d.has("full") and (d.get("set", {}) as Dictionary).is_empty() and (d.get("del", []) as Array).is_empty()


# Применить к base (копии текущего раздела). Возврат: новое значение или null, если base не тот.
static func apply(base, d: Dictionary):
	if d.has("full"):
		return d["full"]
	if not (base is Dictionary) or StateHash.short(base) != int(d.get("base", -1)):
		return null
	var out: Dictionary = (base as Dictionary).duplicate(true)
	for k in d.get("del", []):
		out.erase(k)
	var set: Dictionary = d.get("set", {})
	for k in set:
		out[k] = set[k]
	return out
