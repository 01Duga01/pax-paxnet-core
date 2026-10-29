extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# СВЯЗЬ ХОСТА через ретранслятор игры (Network.relay_pipe). Замена UDP-порта, UPnP и пробивки NAT
# оригинального PaxNet: моду в песочнице сокеты запрещены, а канал игры уже идёт по wss до
# mp.paxuniverse.ru и подписан лицензией игрока. Комната открывается с кодом; гость в канале - номер
# 2.., его «адрес» для сессии - "pipe#<номер>". Звено узнаётся по подписи на любом адресе, поэтому
# гость, переоткрывший канал под новым номером, продолжает то же звено без нового рукопожатия.

const RelayPipe = preload("res://mods/paxnet_core/transport/RelayPipe.gd")
const Relay = preload("res://mods/paxnet_core/transport/Relay.gd")
const Proto = preload("res://mods/paxnet_core/core/Proto.gd")
const Cipher = preload("res://mods/paxnet_core/core/Cipher.gd")

## Канал игры доставляет надёжно и по порядку: повторы звена почти не нужны, держим их редкими.
const LINK_TUNE: Dictionary = {"timeout_ms": 15000, "keepalive_ms": 500, "min_rto_ms": 400, "max_rto_ms": 4000}
## Сколько ждать комнату от ретранслятора.
const OPEN_WAIT_MS: int = 20000
## Сколько раз поднимать комнату заново, если ретранслятор её закрыл.
const REOPEN_TRIES: int = 6
const EP_PREFIX: String = "pipe#"

## HostSession (нетипизирован: скрипт ядра).
var session: Object = null
## Фабрика канала для тестов и своего пути: Callable(first: Dictionary) -> Object.
var pipe_factory: Callable = Callable()
## (kind: String, data: Dictionary) - room | relay_error | reopening.
var on_status: Callable = Callable()
var pipe: Object = null
## idle | opening | open | failed | closed
var state: String = "idle"
var fail_code: String = ""
var room_code: String = ""
## Код, который хотим получить (продолжение сохранённой партии под тем же кодом).
var want_code: String = ""
## PIN приглашения (см. Cipher.bind) и прежний PIN при продолжении партии. pinned = false - комната без PIN
## (общий код по сиду: приглашённым нечем делиться секретом).
var pin: String = ""
var want_pin: String = ""
var pinned: bool = true
var stats: Dictionary = {"in": 0, "out": 0, "bytes_in": 0, "bytes_out": 0, "reopened": 0}

var _owner: Node = null
var _first: Dictionary = {}
var _open_ms: int = -1
var _reopen_at: int = -1
var _reopen_n: int = 0
var _now: int = 0


## Открыть комнату. owner - любой узел в дереве (через него ищется сеть игры).
## opts: name, public, max, preset, host_name, ai. Возврат: "" или код ошибки Proto.ERR_*.
func open(owner: Node, opts: Dictionary, now_ms: int) -> String:
	_owner = owner
	_now = now_ms
	session.set("send_to", Callable(self, "_send_to"))
	if pinned:
		# секретная часть переживает перезапуск, отпечаток ключа - нет: ключ хоста создаётся заново при запуске
		var fp: String = Cipher.fingerprint(Cipher.public_pem(Cipher.host_key()))
		var secret_part: String = want_pin.substr(0, Relay.PIN_SECRET_LEN) if want_pin.length() == Relay.PIN_LEN \
			else Relay.new_secret(Cipher.random_bytes(Relay.PIN_SECRET_LEN))
		pin = secret_part + fp
	else:
		pin = ""
	session.set("pin", pin)
	var tune: Dictionary = session.get("link_tune")
	tune.merge(LINK_TUNE, true)
	_first = {"op": "host", "name": str(opts.get("name", "")), "public": bool(opts.get("public", false)),
		"max": int(opts.get("max", 5)), "ai": str(opts.get("ai", "")), "preset": str(opts.get("preset", "paxnet")),
		"host_name": str(opts.get("host_name", "")), "code": want_code}
	return _open_pipe()


func _open_pipe() -> String:
	RelayPipe.close(pipe)
	_first["code"] = room_code if room_code != "" else want_code
	pipe = RelayPipe.open(_owner, _first, pipe_factory)
	if pipe == null:
		state = "failed"
		fail_code = Proto.ERR_RELAY
		return fail_code
	RelayPipe.wire(pipe, self, "_on_")
	state = "opening"
	_open_ms = _now
	return ""


func close() -> void:
	RelayPipe.close(pipe)
	pipe = null
	state = "closed"


func invite_link() -> String:
	return Relay.invite_link(room_code, pin)


## Код с PIN для ручного ввода: «КОД#PIN».
func invite_code() -> String:
	return (room_code + "#" + pin) if pin != "" else room_code


func _status(kind: String, data: Dictionary = {}) -> void:
	if on_status.is_valid():
		on_status.call(kind, data)


func _send_to(ep: String, data: PackedByteArray) -> void:
	if pipe == null or not ep.begins_with(EP_PREFIX):
		return
	stats["out"] = int(stats["out"]) + 1
	stats["bytes_out"] = int(stats["bytes_out"]) + data.size()
	RelayPipe.send(pipe, ep.substr(EP_PREFIX.length()).to_int(), data)


# ------------------------------------------------------------------ сигналы канала

func _on_lobby_ready(code: Variant = null, _rules: Variant = null) -> void:
	room_code = str(code) if code != null else room_code
	want_code = room_code
	state = "open"
	_reopen_n = 0
	_status("room", {"code": room_code})


func _on_refused(why: Variant = null) -> void:
	var w: String = str(why)
	if room_code != "" and _reopen_n < REOPEN_TRIES:
		# комната уже была: ретранслятор её потерял - поднимаем под тем же кодом
		_schedule_reopen()
		return
	state = "failed"
	fail_code = Proto.ERR_FULL if w.contains("full") else Proto.ERR_RELAY
	RelayPipe.close(pipe)
	pipe = null
	_status("relay_error", {"code": fail_code, "why": w})


func _on_peer_connected(_id: Variant = 0) -> void:
	pass


## Гость пропал из канала. Сессия сама заметит это по молчанию звена; если гость вернётся
## под новым номером, звено продолжится по подписи.
func _on_peer_disconnected(id: Variant = 0) -> void:
	if int(id) == 1 and room_code != "":
		# канал самого хоста оборвался
		_schedule_reopen()


func _schedule_reopen() -> void:
	RelayPipe.close(pipe)
	pipe = null
	state = "opening"
	_reopen_n += 1
	_reopen_at = _now + mini(500 * (1 << mini(_reopen_n, 4)), 8000)
	stats["reopened"] = int(stats["reopened"]) + 1
	_status("reopening", {"try": _reopen_n})


# ------------------------------------------------------------------ главный цикл

func poll(now_ms: int) -> void:
	_now = now_ms
	if pipe == null and _reopen_at >= 0 and now_ms >= _reopen_at:
		_reopen_at = -1
		if _open_pipe() != "":
			_status("relay_error", {"code": fail_code})
	if pipe != null:
		RelayPipe.poll(pipe)
		var guard: int = 0
		while pipe != null and guard < 2048:
			var pk: Array = RelayPipe.recv(pipe)
			if pk.is_empty():
				break
			guard += 1
			var b: PackedByteArray = pk[1]
			stats["in"] = int(stats["in"]) + 1
			stats["bytes_in"] = int(stats["bytes_in"]) + b.size()
			session.call("on_datagram", EP_PREFIX + str(int(pk[0])), b, now_ms)
		if state == "opening" and _open_ms >= 0 and now_ms - _open_ms > OPEN_WAIT_MS and room_code == "":
			_on_refused("timeout")
	session.call("update", now_ms)
