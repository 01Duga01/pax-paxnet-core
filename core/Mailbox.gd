extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ПИСЬМА И ДЕЛА МЕЖДУ ИГРОКАМИ: сделки, союзы, мир, соправитель, объявление войны. Ходит через
# приказы, поэтому исполняется ровно один раз и у всех в одном порядке; состояние входит в
# сверку (раздел "mail"). Согласие нужно от адресата; война — одностороннее действие.

const Proto = preload("res://mods/paxnet/core/Proto.gd")

const KINDS := ["war", "peace", "alliance", "trade", "coruler", "letter"]
const NEEDS_REPLY := ["peace", "alliance", "trade", "coruler"]
const EXPIRES_DAYS := 60
const MAX_OPEN := 12

var next_id := 1
var items := {}     # id → {id, from, to, kind, terms, day, status}
var log: Array = []


func to_dict() -> Dictionary:
	return {"next": next_id, "items": items, "log": log}


func load_dict(d: Dictionary) -> void:
	next_id = int(d.get("next", 1))
	items = (d.get("items", {}) as Dictionary).duplicate(true)
	log = (d.get("log", []) as Array).duplicate(true)
	# ключи после сети остаются числами, но на всякий случай нормализуем
	var fixed := {}
	for k in items:
		fixed[int(k)] = items[k]
	items = fixed


func _open_from(seat: int) -> int:
	var n := 0
	for id in items:
		if items[id]["from"] == seat and items[id]["status"] == "open":
			n += 1
	return n


# mail.send: {to, kind, terms}
func send(adapter, from_seat: int, args: Dictionary, day: int, to_is_human: bool) -> Dictionary:
	var kind := str(args.get("kind", ""))
	var to_seat := int(args.get("to", -1))
	if not KINDS.has(kind) or to_seat < 0 or to_seat == from_seat or from_seat < 0:
		return {"ok": false, "code": Proto.ERR_ILLEGAL, "text": "mail_bad"}
	if _open_from(from_seat) >= MAX_OPEN:
		return {"ok": false, "code": Proto.ERR_RATE, "text": "mail_many"}
	var terms: Dictionary = args.get("terms", {}) if args.get("terms") is Dictionary else {}
	var id := next_id
	next_id += 1
	var it := {"id": id, "from": from_seat, "to": to_seat, "kind": kind, "terms": terms, "day": day, "status": "open"}
	if kind == "war" or kind == "letter":
		var res: Dictionary = adapter.apply_deal(kind, from_seat, to_seat, terms) if kind == "war" else {"ok": true}
		it["status"] = "done"
		_archive(it)
		return {"ok": bool(res.get("ok", true)), "code": str(res.get("code", "")), "text": "mail_sent", "id": id, "to": to_seat}
	if not to_is_human:
		var yes: bool = adapter.auto_reply(kind, from_seat, to_seat, terms)
		return _resolve(adapter, it, yes)
	items[id] = it
	return {"ok": true, "code": "", "text": "mail_sent", "id": id, "to": to_seat}


# mail.reply: {id, accept}
func reply(adapter, from_seat: int, args: Dictionary) -> Dictionary:
	var id := int(args.get("id", -1))
	if not items.has(id) or items[id]["to"] != from_seat or items[id]["status"] != "open":
		return {"ok": false, "code": Proto.ERR_ILLEGAL, "text": "mail_none"}
	return _resolve(adapter, items[id], bool(args.get("accept", false)))


func _resolve(adapter, it: Dictionary, accept: bool) -> Dictionary:
	items.erase(it["id"])
	it["status"] = "accepted" if accept else "declined"
	var res := {"ok": true, "code": "", "text": it["status"], "id": it["id"], "to": it["from"]}
	if accept:
		var d: Dictionary = adapter.apply_deal(it["kind"], it["from"], it["to"], it["terms"])
		if not bool(d.get("ok", true)):
			it["status"] = "failed"
			res["text"] = "failed"
			res["code"] = str(d.get("code", ""))
	_archive(it)
	return res


func _archive(it: Dictionary) -> void:
	log.append({"id": it["id"], "from": it["from"], "to": it["to"], "kind": it["kind"], "status": it["status"], "day": it["day"]})
	if log.size() > 40:
		log.pop_front()


func expire(day: int) -> void:
	for id in items.keys():
		if day - int(items[id]["day"]) > EXPIRES_DAYS:
			items[id]["status"] = "expired"
			_archive(items[id])
			items.erase(id)


func open_for(seat: int) -> Array:
	var out: Array = []
	for id in items:
		if items[id]["to"] == seat and items[id]["status"] == "open":
			out.append(items[id])
	return out
