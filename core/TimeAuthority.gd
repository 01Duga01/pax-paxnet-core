extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ВРЕМЯ ПАРТИИ: пауза и скорость. Решает хост или голосование (настройка лобби); видно, кто
# поставил паузу. Состояние одно — у хоста; гости получают его сообщением M_TIME.

const Proto = preload("res://mods/paxnet/core/Proto.gd")

var mode := "host"               # "host" | "vote"
var paused := true
var speed := 1                   # 1..5
var paused_by := 0               # id игрока, 0 — никто/система
var paused_by_name := ""
var version := 0
var vote_window_ms := 15000
var profile := [                 # скорость → {days за шаг, мс между шагами}
	{"days": 0, "ms": 250},
	{"days": 1, "ms": 1000},
	{"days": 1, "ms": 500},
	{"days": 2, "ms": 250},
	{"days": 5, "ms": 250},
	{"days": 15, "ms": 250},
]
var _votes := {}                 # id → {kind, value, ids:{}, until}


func step_params() -> Dictionary:
	return profile[clampi(speed, 1, profile.size() - 1)]


func to_dict() -> Dictionary:
	return {"v": version, "paused": paused, "speed": speed, "by": paused_by, "by_name": paused_by_name, "mode": mode,
		"votes": _votes_view()}


func load_dict(d: Dictionary) -> void:
	version = int(d.get("v", 0))
	paused = bool(d.get("paused", true))
	speed = int(d.get("speed", 1))
	paused_by = int(d.get("by", 0))
	paused_by_name = str(d.get("by_name", ""))
	mode = str(d.get("mode", "host"))


func _votes_view() -> Array:
	var out: Array = []
	for k in _votes:
		var v: Dictionary = _votes[k]
		out.append({"kind": v["kind"], "value": v["value"], "yes": v["ids"].size(), "need": v["need"]})
	return out


# Команда игрока. voters — id всех живых людей-игроков (кто голосует). Возврат {ok, code, changed}.
func command(player_id: int, player_name: String, is_host: bool, kind: String, value, voters: Array, now_ms: int) -> Dictionary:
	if kind != "pause" and kind != "resume" and kind != "speed":
		return {"ok": false, "code": Proto.ERR_ILLEGAL, "changed": false}
	if is_host:
		return _apply(player_id, player_name, kind, value)
	if mode == "host":
		return {"ok": false, "code": Proto.ERR_HOST_ONLY, "changed": false}
	# голосование: пауза и «пуск» одному — как есть (пауза безопасна), скорость — большинством
	if kind == "pause":
		return _apply(player_id, player_name, kind, value)
	var key := "%s:%s" % [kind, str(value)]
	var need := int(floor(float(voters.size()) / 2.0)) + 1
	var cur: Dictionary = _votes.get(key, {"kind": kind, "value": value, "ids": {}, "until": now_ms + vote_window_ms, "need": need})
	cur["need"] = need
	cur["ids"][player_id] = true
	_votes[key] = cur
	var yes := 0
	for id in cur["ids"]:
		if voters.has(id):
			yes += 1
	if yes >= need:
		_votes.erase(key)
		return _apply(player_id, player_name, kind, value)
	version += 1
	return {"ok": true, "code": "vote", "changed": true}


func _apply(player_id: int, player_name: String, kind: String, value) -> Dictionary:
	var before := [paused, speed]
	match kind:
		"pause":
			paused = true
			paused_by = player_id
			paused_by_name = player_name
		"resume":
			paused = false
			paused_by = 0
			paused_by_name = ""
		"speed":
			speed = clampi(int(value), 1, profile.size() - 1)
	var changed: bool = before != [paused, speed]
	if changed:
		version += 1
	return {"ok": true, "code": "", "changed": changed}


func expire(now_ms: int) -> bool:
	var dirty := false
	for k in _votes.keys():
		if now_ms > int(_votes[k]["until"]):
			_votes.erase(k)
			dirty = true
	if dirty:
		version += 1
	return dirty
