extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# СВЯЗЬ ГОСТЯ через ретранслятор игры (Network.relay_pipe). Вход по коду комнаты или ссылке-
# приглашению. Хост в канале - номер 1. Если канал оборвался, а партия жива, гость входит в ту же
# комнату заново: звено продолжается по подписи (без нового рукопожатия), а если оно успело
# умереть - сессия сама переподключается в ту же страну с тем же ключом.

const RelayPipe = preload("res://mods/paxnet_core/transport/RelayPipe.gd")
const Relay = preload("res://mods/paxnet_core/transport/Relay.gd")
const Proto = preload("res://mods/paxnet_core/core/Proto.gd")
const PipeHost = preload("res://mods/paxnet_core/transport/PipeHost.gd")

## Сколько ждать входа в комнату.
const JOIN_WAIT_MS: int = 10000
## Сколько раз входить заново после обрыва канала.
const REJOIN_TRIES: int = 8

## GuestSession (нетипизирован: скрипт ядра).
var session: Object = null
var pipe_factory: Callable = Callable()
var pipe: Object = null
## idle | joining | joined | rejoining | failed | closed
var state: String = "idle"
var fail_code: String = ""
var code: String = ""
var stats: Dictionary = {"in": 0, "out": 0, "bytes_in": 0, "bytes_out": 0, "rejoined": 0}

var _owner: Node = null
var _ever_joined: bool = false
var _join_ms: int = -1
var _rejoin_at: int = -1
var _rejoin_n: int = 0
var _host_gone: bool = false
var _lost_ms: int = -1
var _now: int = 0
## Сессия переподключается дольше этого, а канал «жив» - значит, канал тоже мёртв: входим заново.
const STALE_PIPE_MS: int = 6000


## target - код, «PAX-…» или ссылка-приглашение. Возврат: "" или код ошибки Proto.ERR_*.
func open(owner: Node, target: String, now_ms: int) -> String:
	_owner = owner
	_now = now_ms
	code = Relay.parse_code(target)
	if code == "":
		return Proto.ERR_CODE
	session.set("room_code", code)
	session.set("pin", Relay.parse_pin(target))
	session.set("send_fn", Callable(self, "_send"))
	var tune: Dictionary = session.get("link_tune")
	tune.merge(PipeHost.LINK_TUNE, true)
	return _open_pipe()


func _open_pipe() -> String:
	RelayPipe.close(pipe)
	pipe = RelayPipe.open(_owner, {"op": "join", "code": code}, pipe_factory)
	if pipe == null:
		state = "failed"
		fail_code = Proto.ERR_RELAY
		return fail_code
	RelayPipe.wire(pipe, self, "_on_")
	state = "joining" if not _ever_joined else "rejoining"
	_join_ms = _now
	_host_gone = false
	return ""


func close() -> void:
	if pipe != null:
		RelayPipe.poll(pipe)
	RelayPipe.close(pipe)
	pipe = null
	state = "closed"


func _send(data: PackedByteArray) -> void:
	if pipe == null:
		return
	stats["out"] = int(stats["out"]) + 1
	stats["bytes_out"] = int(stats["bytes_out"]) + data.size()
	RelayPipe.send(pipe, 1, data)


func _fail(err: String) -> void:
	state = "failed"
	fail_code = err
	RelayPipe.close(pipe)
	pipe = null
	session.call("_on_failed", err)


# ------------------------------------------------------------------ сигналы канала

func _on_lobby_ready(_code: Variant = null, _rules: Variant = null) -> void:
	var first: bool = not _ever_joined
	_ever_joined = true
	state = "joined"
	_rejoin_n = 0
	if first:
		session.call("connect_udp", _now)
	else:
		stats["rejoined"] = int(stats["rejoined"]) + 1
		# звено живо - оно продолжится по подписи; умерло - рукопожатие заново
		if session.get("link") == null and str(session.get("state")) != "closed":
			session.call("connect_udp", _now)


func _on_refused(why: Variant = null) -> void:
	var w: String = str(why)
	var gone: bool = w.contains("code") or w.contains("room") or w.contains("not")
	if _ever_joined:
		if not gone and _rejoin_n < REJOIN_TRIES:
			_schedule_rejoin()
			return
		# комнаты больше нет: хост закрыл партию
		session.set("auto_reconnect", false)
		_fail(Proto.ERR_HOST_LEFT)
		return
	_fail(Proto.ERR_FULL if w.contains("full") else (Proto.ERR_CODE if gone else Proto.ERR_RELAY))


func _on_peer_connected(_id: Variant = 0) -> void:
	pass


func _on_peer_disconnected(id: Variant = 0) -> void:
	if int(id) == 1:
		# сначала дочитать пришедшее (там может быть прощание хоста), решим в poll
		_host_gone = true


func _schedule_rejoin() -> void:
	RelayPipe.close(pipe)
	pipe = null
	state = "rejoining"
	_rejoin_n += 1
	_rejoin_at = _now + (300 if _rejoin_n == 1 else mini(1000 * _rejoin_n, 8000))


# ------------------------------------------------------------------ главный цикл

func poll(now_ms: int) -> void:
	_now = now_ms
	var sstate: String = str(session.get("state"))
	if pipe == null and _rejoin_at >= 0 and now_ms >= _rejoin_at:
		_rejoin_at = -1
		if sstate == "closed" or sstate == "failed":
			state = "closed"
		elif _rejoin_n > REJOIN_TRIES:
			session.set("auto_reconnect", false)
			_fail(Proto.ERR_TIMEOUT)
		elif _open_pipe() != "":
			_fail(Proto.ERR_RELAY)
	if pipe != null:
		RelayPipe.poll(pipe)
		var guard: int = 0
		while pipe != null and guard < 2048:
			var pk: Array = RelayPipe.recv(pipe)
			if pk.is_empty():
				break
			guard += 1
			if int(pk[0]) != 1:
				continue
			var b: PackedByteArray = pk[1]
			stats["in"] = int(stats["in"]) + 1
			stats["bytes_in"] = int(stats["bytes_in"]) + b.size()
			session.call("on_datagram", b, now_ms)
		if pipe != null and _host_gone:
			_host_gone = false
			sstate = str(session.get("state"))
			if sstate != "closed" and sstate != "failed" and bool(session.get("auto_reconnect")):
				_schedule_rejoin()
			elif sstate != "closed":
				_fail(Proto.ERR_HOST_LEFT)
		if pipe != null and (state == "joining" or state == "rejoining") and now_ms - _join_ms > JOIN_WAIT_MS:
			if _ever_joined and _rejoin_n < REJOIN_TRIES:
				_schedule_rejoin()
			elif _ever_joined:
				session.set("auto_reconnect", false)
				_fail(Proto.ERR_TIMEOUT)
			else:
				_fail(Proto.ERR_RELAY)
	session.call("update", now_ms)
	# звено умерло, рукопожатие по «живому» каналу не проходит - канал тоже мёртв
	if str(session.get("state")) == "reconnecting":
		if _lost_ms < 0:
			_lost_ms = now_ms
		elif state == "joined" and now_ms - _lost_ms > STALE_PIPE_MS and now_ms - _join_ms > STALE_PIPE_MS:
			_lost_ms = now_ms
			_schedule_rejoin()
	else:
		_lost_ms = -1


## Войти заново вручную (кнопка «Войти снова»): новый канал, сессия - тем же ключом.
func rejoin() -> String:
	_rejoin_n = 0
	_rejoin_at = -1
	session.set("auto_reconnect", true)
	if str(session.get("state")) != "reconnecting":
		session.set("state", "reconnecting")
	session.set("link", null)
	var e: String = _open_pipe()
	return e
