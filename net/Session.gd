extends Node
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# СЕТЕВАЯ ПАРТИЯ ДЛЯ МОДА: одна точка входа поверх ядра PaxNet. Хост открывает комнату на
# ретрансляторе игры и получает код; гость входит по коду или приглашению. Дальше - лобби (места,
# готовность, правила, чат), время (пауза, скорость, голосование), сообщения мода ровно один раз и
# через обрывы, переподключение тем же игроком. Мир для сверки - адаптер (core/Adapter.gd); без
# него - BasicAdapter (только лобби и сообщения).
#
# Узел обрабатывается и на паузе (PROCESS_MODE_ALWAYS). Создавать - PaxNetLib.new_session().

signal changed
## Сообщение мода/игры: from_id - 1 хост, 2.. гости.
signal message(from_id: int, type: String, data: Variant)
## Событие сессии: peer_joined, peer_left, lobby, started, step, connected, lost, world_installed,
## patched, mismatch, action_rejected, room, reopening, closed, failed…
signal event(kind: String, data: Dictionary)
## Партия не удалась или закрыта: код Proto.ERR_* (перевод - paxnet_err_<код> и paxnet_err_<код>_do).
signal failed(code: String)

const HostSession = preload("res://mods/paxnet_core/core/HostSession.gd")
const GuestSession = preload("res://mods/paxnet_core/core/GuestSession.gd")
const PipeHost = preload("res://mods/paxnet_core/transport/PipeHost.gd")
const PipeGuest = preload("res://mods/paxnet_core/transport/PipeGuest.gd")
const Relay = preload("res://mods/paxnet_core/transport/Relay.gd")
const Proto = preload("res://mods/paxnet_core/core/Proto.gd")
const Hmac = preload("res://mods/paxnet_core/core/Hmac.gd")
const BasicAdapter = preload("res://mods/paxnet_core/net/BasicAdapter.gd")

const HOST_ID: int = 1

## "" | host | guest
var role: String = ""
## "" | connecting | lobby | syncing | playing | reconnecting | failed | closed
var status: String = ""
## HostSession или GuestSession (скрипты ядра).
var session: Object = null
## PipeHost или PipeGuest.
var transport: Object = null
var adapter: Object = null
## Постоянный ключ игрока: по нему хост узнаёт вернувшегося (то же место, та же страна).
var player_key: String = ""
## Мод-потребитель (из его mod.json): хост и гость обязаны совпасть по id и версии мода.
var app_id: String = ""
var app_version: String = ""
var display_name: String = ""
## Фабрика канала вместо ретранслятора игры (тесты, свой путь): Callable(first: Dictionary) -> Object.
var pipe_factory: Callable = Callable()
## Понятная причина последней ошибки: {what, do, code, args}.
var last_notice: Dictionary = {}
## Настройки комнаты по умолчанию (host(..., cfg) их перекрывает).
var defaults: Dictionary = {"max_players": 5, "time_mode": "host", "join_in_progress": true, "allow_coruler": true,
	"ready_required": false, "public": false, "preset": "paxnet", "room_name": ""}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _now() -> int:
	return Time.get_ticks_msec()


func _key() -> String:
	if player_key == "":
		player_key = (Crypto.new().generate_random_bytes(16) as PackedByteArray).hex_encode()
	return player_key


# Ключ записи самого хоста в списке игроков (и в файле сохранения): производный, а не сам ключ игрока, чтобы
# сохранение, которым поделились, не раскрывало постоянный ключ.
func _host_roster_key() -> String:
	return Hmac.mac("pax-host".to_utf8_buffer(), _key().to_utf8_buffer()).hex_encode().substr(0, 32)


# ------------------------------------------------------------------ хост

## Открыть комнату. cfg - правила лобби (max_players, time_mode "host"|"vote", join_in_progress,
## allow_coruler, ready_required), комната (room_name, public, preset, want_code - прежний код) и
## режим ядра (authority, external_time, push_min_ms, mods). Возврат: "" или код ошибки.
func host(name: String, adapter_: Object = null, cfg: Dictionary = {}) -> String:
	leave()
	display_name = name
	adapter = adapter_ if adapter_ != null else BasicAdapter.new()
	var c: Dictionary = defaults.duplicate()
	c.merge(cfg, true)
	var core: Dictionary = c.duplicate()
	core["app"] = app_id
	core["app_ver"] = app_version
	core["name"] = str(c["room_name"]) if str(c["room_name"]) != "" else name
	for k in ["room_name", "public", "preset", "want_code", "want_pin", "pinned"]:
		core.erase(k)
	session = HostSession.new(adapter, core)
	session.set("host_name", name)
	session.set("host_key", _host_roster_key())
	session.set("on_event", Callable(self, "_on_host_event"))
	session.set("on_app", Callable(self, "_on_app"))
	_prepare_host(c)
	transport = PipeHost.new()
	transport.set("session", session)
	transport.set("pipe_factory", pipe_factory)
	transport.set("want_code", str(c.get("want_code", "")))
	transport.set("want_pin", str(c.get("want_pin", "")))
	transport.set("pinned", bool(c.get("pinned", true)))
	transport.set("on_status", Callable(self, "_on_transport_status"))
	var err: String = str(transport.call("open", self, {"name": core["name"], "public": bool(c["public"]),
		"max": int(c["max_players"]), "preset": str(c["preset"]), "host_name": name}, _now()))
	if err != "":
		session = null
		transport = null
		role = ""
		_set_failed(err)
		return err
	role = "host"
	status = "connecting"
	_changed()
	return ""


## Для наследников: донастроить HostSession до открытия комнаты (продолжение сохранения и т.п.).
func _prepare_host(_cfg: Dictionary) -> void:
	pass


## Хост начинает партию: гости получают мир (или пустой мир BasicAdapter).
func start() -> Dictionary:
	if role != "host":
		return {"ok": false, "code": Proto.ERR_HOST_ONLY}
	var r: Dictionary = session.call("lobby_cmd", HOST_ID, {"op": "start"})
	if bool(r.get("ok", false)):
		status = "playing"
	_changed()
	return r


# ------------------------------------------------------------------ гость

## Войти по коду, «PAX-…» или ссылке. extra - что хост увидит при входе (mods - для сверки модов).
func join(target: String, name: String, adapter_: Object = null, extra: Dictionary = {}) -> String:
	leave()
	display_name = name
	adapter = adapter_ if adapter_ != null else BasicAdapter.new()
	session = GuestSession.new(adapter, _key(), name)
	var info: Dictionary = {"mods": ""}
	info.merge(extra, true)
	info["app"] = app_id
	info["app_ver"] = app_version
	session.set("extra_info", info)
	session.set("on_event", Callable(self, "_on_guest_event"))
	session.set("on_app", Callable(self, "_on_app"))
	transport = PipeGuest.new()
	transport.set("session", session)
	transport.set("pipe_factory", pipe_factory)
	var err: String = str(transport.call("open", self, target, _now()))
	if err != "":
		session = null
		transport = null
		role = ""
		_set_failed(err)
		return err
	role = "guest"
	status = "connecting"
	_changed()
	return ""


## Гость: войти снова (после ошибки связи) - тот же ключ, то же место.
func rejoin() -> String:
	if role != "guest" or transport == null:
		return Proto.ERR_ILLEGAL
	last_notice = {}
	status = "reconnecting"
	var e: String = str(transport.call("rejoin"))
	_changed()
	return e


## Гость: мир разошёлся и не вылечился - получить его целиком заново.
func request_full_world() -> void:
	if role == "guest" and session != null:
		last_notice = {}
		session.call("request_full_world")


# ------------------------------------------------------------------ общее

func leave() -> void:
	if session != null:
		if role == "guest":
			session.call("leave")
		elif role == "host":
			session.call("close_all", Proto.ERR_HOST_LEFT)
	if transport != null:
		transport.call("poll", _now())
		transport.call("close")
	var was: bool = role != ""
	session = null
	transport = null
	role = ""
	status = ""
	if was:
		_changed()


func is_host() -> bool:
	return role == "host"


func is_guest() -> bool:
	return role == "guest"


## В партии и связь есть.
func active() -> bool:
	return role != "" and (status == "lobby" or status == "playing" or status == "syncing")


func my_id() -> int:
	if role == "host":
		return HOST_ID
	return int(session.get("my_id")) if session != null else 0


func code() -> String:
	if transport == null:
		return ""
	return str(transport.get("room_code")) if role == "host" else str(transport.get("code"))


## PIN приглашения (только у хоста): без него приглашённый не пройдёт рукопожатие.
func pin() -> String:
	return str(transport.get("pin")) if transport != null and role == "host" else ""


func invite_link() -> String:
	return Relay.invite_link(code(), pin())


## «КОД#PIN» для ручного ввода и показа.
func invite_code() -> String:
	return code() + (("#" + pin()) if pin() != "" else "")


## [{id, name, seat, role, ready, ai, ping, host, away}]
func players() -> Array:
	if session == null:
		return []
	if role == "host":
		var st: Dictionary = session.call("lobby_state")
		return st.get("players", [])
	var lobby: Dictionary = session.get("lobby")
	return lobby.get("players", [])


func player_name(id: int) -> String:
	for p in players():
		if int((p as Dictionary).get("id", -1)) == id:
			return str((p as Dictionary).get("name", "?"))
	return "?"


## Пинг до хоста (гость), мс.
func rtt_ms() -> float:
	return float(session.get("rtt_ms")) if role == "guest" and session != null else 0.0


## Время партии: {v, paused, speed, by, by_name, mode, votes}.
func time_state() -> Dictionary:
	if session == null:
		return {}
	var t: Object = session.get("time")
	return t.call("to_dict")


func state() -> Dictionary:
	return {"role": role, "status": status, "code": code(), "players": players(), "time": time_state(),
		"notice": last_notice, "rtt": rtt_ms(), "id": my_id()}


# ------------------------------------------------------------------ что отдаёт игрок

## Сообщение мода: to - id игрока (1 - хост), 0 - всем, кроме себя. Доходит ровно один раз,
## по порядку, даже через обрыв связи. data - простые значения (числа, строки, массивы, словари,
## PackedByteArray, Vector2/3, Color); объекты не передаются.
func send(to: int, type: String, data: Variant = null) -> bool:
	if session == null:
		return false
	session.call("app_send", to, type, data)
	return true


func broadcast(type: String, data: Variant = null) -> bool:
	return send(0, type, data)


## Приказ мира (через шаг ядра, у всех в одном порядке). Возврат гостя - номер приказа; хоста - {ok, code}.
func action(kind: String, args: Variant = null) -> Variant:
	if session == null:
		return null
	if role == "host":
		return session.call("host_action", kind, args)
	return session.call("submit", kind, args)


func chat(text: String) -> void:
	if role == "host":
		session.call("chat", HOST_ID, text)
	elif role == "guest":
		session.call("chat", text)


## Время: kind - pause | resume | speed (value 1..5).
func time_cmd(kind: String, value: Variant = null) -> void:
	if role == "host":
		session.call("time_cmd", HOST_ID, kind, value)
	elif role == "guest":
		session.call("time_cmd", kind, value)


## Команда лобби: {op: seat, seat, role} | {op: ready, on} | {op: name, name} | {op: rules, …} | {op: kick, id}.
func lobby_cmd(cmd: Dictionary) -> Variant:
	if role == "host":
		return session.call("lobby_cmd", HOST_ID, cmd)
	if role == "guest":
		session.call("lobby_cmd", cmd)
	return null


func set_ready(on: bool) -> void:
	lobby_cmd({"op": "ready", "on": on})


func choose_seat(seat: int, as_coruler: bool = false) -> void:
	lobby_cmd({"op": "seat", "seat": seat, "role": "coruler" if as_coruler else "player"})


## Владелец места зовёт игрока в соправители (без приглашения занять чужое место нельзя).
func invite_coruler(guest_id: int) -> void:
	lobby_cmd({"op": "coruler_invite", "id": guest_id})


func revoke_coruler(guest_id: int) -> void:
	lobby_cmd({"op": "coruler_revoke", "id": guest_id})


func kick(id: int) -> void:
	if role == "host":
		lobby_cmd({"op": "kick", "id": id})


# ------------------------------------------------------------------ цикл и события

func _process(_d: float) -> void:
	if transport == null:
		return
	transport.call("poll", _now())
	if role == "guest" and session != null:
		var st: String = str(session.get("state"))
		if st == "failed" and status == "closed":
			st = "closed"
		if st != status and st != "idle":
			status = st
			_changed()


func _on_app(from_id: Variant, type: Variant, data: Variant) -> void:
	message.emit(int(from_id), str(type), data)


func _on_transport_status(kind: String, data: Dictionary) -> void:
	match kind:
		"room":
			if status == "connecting":
				status = "lobby" if str(session.get("phase")) == "lobby" else "playing"
		"relay_error":
			_set_failed(str(data.get("code", Proto.ERR_RELAY)))
	event.emit(kind, data)
	_changed()


func _on_host_event(kind: String, data: Dictionary) -> void:
	if kind == "started":
		status = "playing"
	event.emit(kind, data)
	if kind in ["peer_joined", "peer_left", "lobby", "started"]:
		_changed()


func _on_guest_event(kind: String, data: Dictionary) -> void:
	match kind:
		"failed":
			_set_failed(str(data.get("code", Proto.ERR_TIMEOUT)))
		"closed":
			var why: String = str(data.get("why", Proto.ERR_HOST_LEFT))
			status = "closed"
			last_notice = Proto.human(Proto.ERR_KICKED if why == "kicked" else Proto.ERR_HOST_LEFT)
			failed.emit(str(last_notice["code"]))
		"lost":
			last_notice = Proto.human(Proto.ERR_TIMEOUT)
		"connected", "world_installed":
			last_notice = {}
	event.emit(kind, data)
	_changed()


func _set_failed(code_: String) -> void:
	# хост закрыл партию или выгнал - это не сбой связи: партия закрыта
	status = "closed" if code_ == Proto.ERR_HOST_LEFT or code_ == Proto.ERR_KICKED else "failed"
	notice(code_, {})
	failed.emit(code_)


## Понятная причина для окна: что случилось и что нажать.
func notice(code_: String, args: Dictionary) -> void:
	last_notice = Proto.human(code_)
	last_notice["args"] = args
	_changed()


func _changed() -> void:
	changed.emit()


func _exit_tree() -> void:
	leave()
