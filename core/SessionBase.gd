extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ОБЩЕЕ У ХОСТА И ГОСТЯ: как исполняется шаг мира. Хост и гость зовут одну и ту же функцию
# apply_closure, поэтому «одинаковые входы → одинаковый мир» держится на одном куске кода.
#
# Шаг мира (closure) — единица синхронизации, как «тик с действиями» у Factorio:
#   t   номер шага (растёт на 1, без пропусков)
#   n   сколько дней продвинуть мир (0 — шаг только с приказами, например на паузе)
#   iv  за сколько мс хост сделал шаг (гость выдерживает тот же ритм, дата идёт ровно)
#   a   приказы по порядку: {p игрок, s страна, r роль, c номер приказа игрока, k вид, g данные}
#   ev  системные события (страну взял игрок / ведёт ИИ) — в том же порядке с приказами
#   nw  новости шага (газета, хроника) — только из итогов, раз и с номером
#   ai  итоги нейросети (рассказ и исход) — одни на всех
#   h   суммы разделов мира после шага: name → u32 (гость сверяет и при расхождении просит лечить)

const Bytes = preload("res://mods/paxnet/core/Bytes.gd")
const StateHash = preload("res://mods/paxnet/core/StateHash.gd")
const Proto = preload("res://mods/paxnet/core/Proto.gd")
const Mailbox = preload("res://mods/paxnet/core/Mailbox.gd")
const TimeAuthority = preload("res://mods/paxnet/core/TimeAuthority.gd")
const SharedRng = preload("res://mods/paxnet/core/SharedRng.gd")

var adapter
var tick := 0                    # последний применённый шаг
var world_seed := 0
var mailbox := Mailbox.new()
var time := TimeAuthority.new()
var seats := {}                  # страна → {id, key, name, role, ai}
var news_seen := {}              # номер новости → true (повтор не печатаем)
var results_log: Array = []      # последние результаты приказов (для тестов и окна приказов)
var my_id := 0
var _skip_advance_now := false  # хост с внешним временем: дни уже прожиты игрой
var simulate := true
## Настройки звена от транспорта (timeout_ms, keepalive_ms, min_rto_ms…): применяются к каждому новому звену.
## Словарь общий с рукопожатием: транспорт дополняет его до входа.
var link_tune := {}             # false — гость в режиме власти хоста: шаг не пересчитывает, ждёт изменения


# Разделы, которыми владеет сама сессия (не игра).
func _own_sections() -> Dictionary:
	return {"mail": StateHash.short(mailbox.to_dict()), "seats": StateHash.short(seats)}


func core_hashes(at_tick: int, all: bool = false) -> Dictionary:
	var h: Dictionary = adapter.hashes(at_tick, all)
	if not h.has("date"):
		h["date"] = adapter.current_day()
	h.merge(_own_sections())
	return h


func own_section_data(names: Array) -> Dictionary:
	var out := {}
	for n in names:
		if n == "mail":
			out["mail"] = mailbox.to_dict()
		elif n == "seats":
			out["seats"] = seats.duplicate(true)
	return out


func apply_own_sections(data: Dictionary) -> void:
	if data.has("mail"):
		mailbox.load_dict(data["mail"])
	if data.has("seats"):
		seats = {}
		for k in data["seats"]:
			seats[int(k)] = data["seats"][k]


func seat_is_human(seat: int) -> bool:
	return seats.has(seat) and not bool(seats[seat].get("ai", false))


# Исполнить шаг. Возвращает результаты приказов [{p, c, k, result}].
func apply_closure(c: Dictionary) -> Array:
	var out: Array = []
	tick = int(c["t"])
	for ev in c.get("ev", []):
		_apply_event(ev)
	if not simulate:
		_outputs(c)
		return out
	for a in c.get("a", []):
		var actor := {"id": int(a["p"]), "seat": int(a["s"]), "role": str(a["r"])}
		var k := str(a["k"])
		var res: Dictionary
		if k == "mail.send":
			var args: Dictionary = a["g"] if a["g"] is Dictionary else {}
			res = mailbox.send(adapter, actor["seat"], args, adapter.current_day(), seat_is_human(int(args.get("to", -1))))
		elif k == "mail.reply":
			res = mailbox.reply(adapter, actor["seat"], a["g"] if a["g"] is Dictionary else {})
		else:
			res = adapter.execute_action(actor, {"kind": k, "args": a["g"], "c": int(a["c"])}, {"tick": tick, "day": adapter.current_day()})
		out.append({"p": actor["id"], "c": int(a["c"]), "k": k, "result": res})
		adapter.on_action_result(actor, {"kind": k, "args": a["g"], "c": int(a["c"])}, res)
	var n := int(c.get("n", 0))
	if n > 0 and not _skip_advance_now:
		adapter.advance(n, tick, world_seed)
		mailbox.expire(adapter.current_day())
	_outputs(c)
	return out


# Что шаг показывает игроку (газета, итоги нейросети): у всех одинаково и один раз.
func _outputs(c: Dictionary) -> void:
	for e in c.get("nw", []):
		var nid := int(e.get("id", 0))
		if nid == 0 or not news_seen.has(nid):
			news_seen[nid] = true
			adapter.on_news(e)
	for e in c.get("ai", []):
		var rid := int(e.get("rid", 0))
		var key := -rid
		if not news_seen.has(key):
			news_seen[key] = true
			adapter.on_ai_result(e)
	if news_seen.size() > 4000:   # бесконечно не копим: свежие номера всегда больше
		var keys := news_seen.keys()
		keys.sort()
		for i in 1000:
			news_seen.erase(keys[i])


func _apply_event(ev: Dictionary) -> void:
	match str(ev.get("k", "")):
		"seat":
			var s := int(ev["seat"])
			if int(ev.get("id", 0)) == 0 and not bool(ev.get("keep", false)):
				seats.erase(s)
			else:
				seats[s] = {"id": int(ev["id"]), "key": str(ev.get("key", "")), "name": str(ev.get("name", "")),
					"role": str(ev.get("role", "player")), "ai": bool(ev.get("ai", false))}
		"ai":
			var s2 := int(ev["seat"])
			if seats.has(s2):
				seats[s2]["ai"] = bool(ev["on"])
	if simulate:
		adapter.apply_event(ev)


static func encode_closure(c: Dictionary) -> PackedByteArray:
	return Bytes.encode(c)


static func decode_closure(b: PackedByteArray) -> Dictionary:
	var d := Bytes.decode(b)
	if not d["ok"] or not (d["v"] is Dictionary) or not (d["v"] as Dictionary).has("t"):
		return {}
	return d["v"]
