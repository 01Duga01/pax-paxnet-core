extends "res://mods/paxnet_core/core/SessionBase.gd"
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ГОСТЬ ПАРТИИ. Отдаёт приказы хосту, исполняет шаги мира хоста в том же порядке, сверяет свой
# мир с суммами из шага и, если разошёлся, просит у хоста только нужные разделы. Шаги
# выдерживает в ритме хоста (буфер против рывков сети), поэтому дата у гостя идёт ровно.
# Связь пропала — сам переподключается в ту же партию за ту же страну.

const Handshake = preload("res://mods/paxnet_core/core/Handshake.gd")
const Xfer = preload("res://mods/paxnet_core/core/Xfer.gd")
const Frag = preload("res://mods/paxnet_core/core/Frag.gd")
const Delta = preload("res://mods/paxnet_core/core/Delta.gd")
const AppChannel = preload("res://mods/paxnet_core/core/AppChannel.gd")
const Hmac = preload("res://mods/paxnet_core/core/Hmac.gd")

const MAX_WORLD_RAW := 256 << 20      # размер мира после распаковки, который гость готов принять от хоста
const MAX_PATCH_RAW := 64 << 20

var state := "idle"              # idle | connecting | lobby | syncing | playing | reconnecting | failed | closed
var key := ""
var name := "?"
var pin := ""                    # PIN приглашения: защита от подмены ключа на ретрансляторе
var room_code := ""              # код комнаты: из него и ключа игрока выводится ключ для этой комнаты
var extra_info := {}             # mods, code, game_ver…
var send_fn: Callable            # (bytes) — датаграмма хосту (UDP или через ретранслятор)
var on_event: Callable           # (kind, data)
var on_app: Callable             # (from_id, type, data) — сообщение протокола игры/мода
var app := AppChannel.new()
var link
var dialer
var lobby := {}
var countries: Array = []
var chat_log: Array = []
var last_notice := {}
var rtt_ms := 0.0
var auto_reconnect := true
var target_depth := 2
var stats := {"applied": 0, "resyncs": 0, "patches": 0, "worlds": 0, "mismatch_ticks": 0, "replayed": 0}

var _pending := {}               # t → шаг
var _patches := {}               # as_of → данные разделов (применить сразу после шага as_of)
var _blob := {}                  # ожидаемая передача: {xid, as_of, kind}
var _recv
var _frag := Frag.new()
var _cseq := 0
var _unacked := {}               # c → {c, k, g}
var _next_apply_ms := -1
var _last_report_ms := 0
var _last_resync_ms := -10000
var _core := 0                   # короткая сумма своего мира на шаге tick
var _has_world := false
var _reconnect_at := -1
var _reconnect_tries := 0
var _lost_since := -1
var _now := 0
var _last_ping_ms := 0
var _disp := {"from": 0.0, "to": 0.0, "t0": 0, "iv": 1}


func _init(adapter_, key_: String, name_: String = "?") -> void:
	adapter = adapter_
	key = key_
	name = name_


func _emit(kind: String, data: Dictionary = {}) -> void:
	if on_event.is_valid():
		on_event.call(kind, data)


# Хосту уходит не сам ключ игрока, а ключ ЭТОЙ комнаты: HMAC(ключ игрока, код комнаты). Хост узнаёт по нему
# вернувшегося игрока у себя, но в чужой комнате этот ключ ничего не открывает.
func room_key() -> String:
	return Hmac.mac(key.to_utf8_buffer(), ("pax-room|" + room_code).to_utf8_buffer()).hex_encode().substr(0, 32)


func _info() -> Dictionary:
	var i := {"proto": Proto.version, "key": room_key(), "name": name, "has_world": _has_world and state != "syncing",
		"last_tick": tick if _has_world else -1, "core": _core}
	i.merge(extra_info)
	return i


# ------------------------------------------------------------------ вход

# UDP (напрямую или через ретранслятор): датаграммы уходят в send_fn, приходят в on_datagram.
func connect_udp(now_ms: int) -> void:
	_now = now_ms
	dialer = Handshake.Dialer.new()
	dialer.send_fn = func(b): if send_fn.is_valid(): send_fn.call(b)
	dialer.on_connected = func(l, w): _on_connected(l, w)
	dialer.on_failed = func(code): _on_failed(code)
	dialer.link_tune = link_tune
	dialer.pin = pin
	if state != "reconnecting":
		state = "connecting"
	dialer.start(now_ms, _info())
	dialer.poll(now_ms)


func on_datagram(data: PackedByteArray, now_ms: int) -> void:
	_now = now_ms
	if dialer != null:
		dialer.on_datagram(data, now_ms)


# WebSocket: транспорт сам соединился и получил приветствие хоста.
func attach_stream(l, welcome: Dictionary) -> void:
	_on_connected(l, welcome)


func connect_info() -> Dictionary:
	return _info()


func _on_failed(code: String) -> void:
	if state == "reconnecting" and code == Proto.ERR_NO_ROUTE:
		_schedule_reconnect()
		return
	state = "failed"
	last_notice = Proto.human(code)
	adapter.on_notice(code, {})
	_emit("failed", {"code": code})


func _on_connected(l, welcome) -> void:
	if not (welcome is Dictionary):
		return
	link = l
	link.on_message = func(t: int, body: PackedByteArray): _on_message(t, body)
	my_id = int(welcome.get("id", 0))
	simulate = not bool(welcome.get("authority", false))
	_reconnect_tries = 0
	_lost_since = -1
	time.load_dict(welcome.get("time", {}))
	var last := int(welcome.get("last_cseq", 0))
	_cseq = maxi(_cseq, last)
	for c in _unacked.keys():
		if int(c) <= last:
			_unacked.erase(c)
	app.resend(link)
	var order := _unacked.keys()
	order.sort()
	for c in order:
		link.send_reliable(Proto.M_ACTION, Bytes.encode(_unacked[c]), true)
	match str(welcome.get("mode", "lobby")):
		"lobby":
			state = "lobby"
		"replay":
			state = "playing"
			world_seed = int(welcome.get("seed", world_seed))
			stats["replayed"] += 1
		"world":
			state = "syncing"
			_has_world = false
	_emit("connected", {"id": my_id, "mode": welcome.get("mode", ""), "reconnect": welcome.get("reconnect", false)})


func _schedule_reconnect() -> void:
	_reconnect_tries += 1
	_reconnect_at = _now + mini(500 * (1 << mini(_reconnect_tries, 4)), 8000)


# ------------------------------------------------------------------ что отдаёт игрок

# Приказ (промптом или мышью). Возвращает номер приказа; итог придёт в шаге мира.
func submit(kind: String, args = null) -> int:
	_cseq += 1
	var a := {"c": _cseq, "k": kind, "g": args}
	_unacked[_cseq] = a
	if link != null and not link.dead:
		link.send_reliable(Proto.M_ACTION, Bytes.encode(a), true)
	return _cseq


# Сообщение протокола игры или мода: to — id игрока (1 — хост), 0 — всем остальным.
# Доходит ровно один раз, даже через обрыв связи.
func app_send(to: int, type: String, data) -> void:
	app.send(link if link != null and not link.dead else null, {"to": to, "type": type, "data": data})


func lobby_cmd(cmd: Dictionary) -> void:
	if link != null:
		link.send_reliable(Proto.M_LOBBY_CMD, Bytes.encode(cmd))


func chat(text: String) -> void:
	if link != null:
		link.send_reliable(Proto.M_CHAT, Bytes.encode({"text": text}))


func time_cmd(kind: String, value = null) -> void:
	if link != null:
		link.send_reliable(Proto.M_TIME_CMD, Bytes.encode({"k": kind, "v": value}))


func leave() -> void:
	if link != null:
		link.send_reliable(Proto.M_BYE, Bytes.encode({"why": "bye"}))
		link.poll(_now)
	auto_reconnect = false
	state = "closed"


# Кнопка «Получить мир заново» (если лечение по разделам не помогло).
func request_full_world() -> void:
	_has_world = false
	if link != null:
		link.send_reliable(Proto.M_BYE, PackedByteArray())
	link = null
	state = "reconnecting"
	connect_udp(_now)


# ------------------------------------------------------------------ приём

func _on_message(type: int, body: PackedByteArray) -> void:
	match type:
		Proto.M_FRAG:
			var done: Array = _frag.feed(body)
			if not done.is_empty():
				_on_message(int(done[0]), done[1])
		Proto.M_CLOSURE:
			var c := decode_closure(body)
			if c.is_empty():
				return
			var t := int(c["t"])
			if t <= tick or _pending.has(t):
				return
			if state == "syncing" and _blob.get("kind", "") == "world" and t <= int(_blob["as_of"]):
				return
			_pending[t] = c
		Proto.M_LOBBY:
			var d := Bytes.decode(body)
			if d["ok"] and d["v"] is Dictionary:
				lobby = d["v"]
				if lobby.has("countries"):
					countries = lobby["countries"]
				adapter.on_roster_changed(lobby.get("players", []))
				_emit("lobby", lobby)
		Proto.M_CHAT:
			var d2 := Bytes.decode(body)
			if d2["ok"] and d2["v"] is Dictionary:
				chat_log.append(d2["v"])
				adapter.on_chat(int(d2["v"].get("from", 0)), str(d2["v"].get("name", "")), str(d2["v"].get("text", "")))
		Proto.M_ACTION_RESULT:
			var d3 := Bytes.decode(body)
			if d3["ok"] and d3["v"] is Dictionary:
				var c2 := int(d3["v"].get("c", 0))
				_unacked.erase(c2)
				if bool(d3["v"].get("done", false)):
					# итог исполнения (режим власти хоста): показать автору
					if not simulate:
						adapter.on_action_result({"id": my_id}, {"kind": str(d3["v"].get("k", "")), "c": c2}, d3["v"])
					return
				if not bool(d3["v"].get("ok", false)) and str(d3["v"].get("code", "")) != "dup":
					adapter.on_notice(str(d3["v"].get("code", "")), {"c": c2})
					_emit("action_rejected", d3["v"])
		Proto.M_TIME:
			var d4 := Bytes.decode(body)
			if d4["ok"] and d4["v"] is Dictionary:
				time.load_dict(d4["v"])
				adapter.on_time_state(d4["v"])
		Proto.M_NOTICE:
			var d5 := Bytes.decode(body)
			if d5["ok"] and d5["v"] is Dictionary:
				last_notice = Proto.human(str(d5["v"].get("code", "")))
				adapter.on_notice(str(d5["v"].get("code", "")), d5["v"].get("args", {}))
		Proto.M_PATCH:
			var d6 := Bytes.decode(body)
			if d6["ok"] and d6["v"] is Dictionary and (d6["v"] as Dictionary).has("as_of"):
				_queue_patch(int(d6["v"]["as_of"]), d6["v"])
		Proto.M_PATCH_BLOB:
			var d7 := Bytes.decode(body)
			if d7["ok"] and d7["v"] is Dictionary:
				_blob = {"xid": int(d7["v"].get("xid", -1)), "as_of": int(d7["v"].get("as_of", 0)), "kind": "patch", "raw": int(d7["v"].get("raw", 0))}
		Proto.M_WORLD:
			var d8 := Bytes.decode(body)
			if d8["ok"] and d8["v"] is Dictionary and (d8["v"] as Dictionary).get("meta") is Dictionary:
				var as_of := int(d8["v"].get("as_of", 0))
				_blob = {"xid": int(d8["v"].get("xid", -1)), "as_of": as_of, "kind": "world", "meta": d8["v"]["meta"]}
				state = "syncing"
				_has_world = false
				for t2 in _pending.keys():
					if int(t2) <= as_of:
						_pending.erase(t2)
				_patches.clear()
		Proto.M_XFER_BEGIN:
			_recv = Xfer.Receiver.new(link, body)
			_recv.on_done = func(id, data, _meta): _on_blob(id, data)
		Proto.M_XFER_CHUNK:
			if _recv != null:
				_recv.on_chunk(body)
		Proto.M_APP:
			for m in app.on_msg(body):
				if on_app.is_valid():
					on_app.call(int(m.get("from", 1)), str(m.get("type", "")), m.get("data"))
		Proto.M_APP_ACK:
			app.on_ack(body)
		Proto.M_PING:
			link.send_unreliable(Proto.M_PONG, body)
		Proto.M_PONG:
			var r := Bytes.R.new(body)
			var sent := r.varint()
			if r.ok:
				rtt_ms = float(_now - sent)
		Proto.M_BYE:
			var d9 := Bytes.decode(body)
			var why := "host_left"
			if d9["ok"] and d9["v"] is Dictionary:
				why = str(d9["v"].get("why", "host_left"))
			state = "closed"
			auto_reconnect = false
			last_notice = Proto.human(Proto.ERR_KICKED if why == "kicked" else Proto.ERR_HOST_LEFT)
			adapter.on_notice(last_notice["code"], {})
			_emit("closed", {"why": why})


# msg: {as_of, data: {раздел: целиком}} (лечение) или {as_of, delta: {раздел: разница}} (изменения шага).
func _queue_patch(as_of: int, msg) -> void:
	if not (msg is Dictionary):
		return
	if as_of <= tick:
		_apply_patch(msg)
	elif _patches.has(as_of):
		_merge_patch(_patches[as_of], msg)
	else:
		_patches[as_of] = msg


func _merge_patch(into: Dictionary, msg: Dictionary) -> void:
	if msg.has("hs"):
		into["hs"] = msg["hs"]
	for k in ["data", "delta"]:
		if msg.has(k):
			var cur: Dictionary = into.get(k, {})
			cur.merge(msg[k], true)
			into[k] = cur


var _last_hs := {}


func _apply_patch(msg: Dictionary) -> void:
	if msg.has("hs"):
		_last_hs = msg["hs"]
	var data: Dictionary = (msg.get("data", {}) as Dictionary).duplicate()
	var stale: Array = []
	var deltas: Dictionary = msg.get("delta", {})
	if not deltas.is_empty():
		var bases: Dictionary = adapter.section_data(deltas.keys().filter(func(n): return not deltas[n].has("full")))
		for n in deltas:
			var v = Delta.apply(bases.get(n), deltas[n])
			if v == null:
				stale.append(n)       # наш раздел уже не тот, к которому разница: просим целиком
			else:
				data[n] = v
	var own := {}
	var game := {}
	for n in data:
		if n == "mail" or n == "seats":
			own[n] = data[n]
		else:
			game[n] = data[n]
	if not game.is_empty():
		adapter.apply_sections(game)
	if not own.is_empty():
		apply_own_sections(own)
	stats["patches"] += 1
	if not stale.is_empty() and link != null:
		stats["resyncs"] += 1
		link.send_reliable(Proto.M_RESYNC, Bytes.encode({"t": tick, "names": stale}))
	_emit("patched", {"names": data.keys(), "tick": tick})


func _on_blob(id: int, data: PackedByteArray) -> void:
	if _blob.is_empty() or int(_blob["xid"]) != id:
		return
	var b := _blob
	if b["kind"] == "world":
		var meta: Dictionary = b["meta"]
		var raw_size := int(meta.get("raw", 0)) if meta is Dictionary else -1
		if raw_size < 0 or raw_size > MAX_WORLD_RAW:
			_blob = {}
			_emit("failed", {"code": Proto.ERR_DESYNC})
			return
		# пустой мир (адаптер без мира) - распаковывать нечего: decompress(0) движок не принимает
		var raw: PackedByteArray = data.decompress(raw_size, Bytes.ZSTD) if raw_size > 0 else PackedByteArray()
		if not adapter.install_world(raw):
			_emit("failed", {"code": Proto.ERR_DESYNC})
			return
		world_seed = int(meta.get("seed", 0))
		tick = int(b["as_of"])
		apply_own_sections(meta.get("own", {}))
		time.load_dict(meta.get("time", {}))
		_has_world = true
		_core = StateHash.short(core_hashes(tick))
		state = "playing"
		_next_apply_ms = -1
		stats["worlds"] += 1
		_blob = {}
		_emit("world_installed", {"tick": tick})
	else:
		var raw_patch := int(b["raw"])
		if raw_patch < 0 or raw_patch > MAX_PATCH_RAW:
			_blob = {}
			return
		var raw2: PackedByteArray = data.decompress(raw_patch, Bytes.ZSTD) if raw_patch > 0 else PackedByteArray()
		var d := Bytes.decode(raw2)
		if d["ok"] and d["v"] is Dictionary and (d["v"] as Dictionary).has("as_of"):
			_queue_patch(int(d["v"]["as_of"]), d["v"])
		_blob = {}


# ------------------------------------------------------------------ исполнение шагов

func _drain(now_ms: int) -> void:
	if state != "playing":
		return
	var guard := 0
	while _pending.has(tick + 1) and guard < 64:
		guard += 1
		var c: Dictionary = _pending[tick + 1]
		# большой кусок мира ещё качается — на его шаге ждём
		if not _blob.is_empty() and _blob["kind"] == "patch" and int(_blob["as_of"]) <= tick + 1:
			if int(_blob["as_of"]) <= tick or c.has("p"):
				return
		var n := int(c.get("n", 0))
		var iv := int(c.get("iv", 0))
		if n > 0 and iv > 0:
			if _next_apply_ms < 0:
				_next_apply_ms = now_ms
			if now_ms < _next_apply_ms and _pending.size() <= target_depth:
				return
			# догоняем — расписание не уезжает в будущее дальше одного шага
			_next_apply_ms = mini(maxi(_next_apply_ms + iv, now_ms - iv), now_ms + iv)
		# изменения этого шага от хоста (режим власти хоста) ещё в пути — шаг без них не применяем
		var t_next := tick + 1
		if c.has("p") and not _patches.has(t_next):
			if _next_apply_ms >= 0 and n > 0 and iv > 0:
				_next_apply_ms -= iv
			return
		_pending.erase(t_next)
		var day_before := float(adapter.current_day())
		apply_closure(c)
		stats["applied"] += 1
		if _patches.has(tick):
			_apply_patch(_patches[tick])
			_patches.erase(tick)
		_disp = {"from": day_before, "to": float(adapter.current_day()), "t0": now_ms, "iv": maxi(iv, 1)}
		_verify(c)


func _verify(c: Dictionary) -> void:
	var want: Dictionary = c.get("h", {})
	if not simulate:
		want = _last_hs
		_last_hs = {}
		if want.is_empty():
			return
	var mine := core_hashes(tick, not simulate)
	_core = StateHash.short(mine)
	var bad: Array = []
	for n in want:
		if int(mine.get(n, -1)) != int(want[n]):
			bad.append(n)
	if bad.is_empty():
		return
	stats["mismatch_ticks"] += 1
	if _now - _last_resync_ms < 300:
		return
	_last_resync_ms = _now
	stats["resyncs"] += 1
	link.send_reliable(Proto.M_RESYNC, Bytes.encode({"t": tick, "names": bad}))
	_emit("mismatch", {"t": tick, "names": bad})


# Дата для показа: плавно между шагами, без рывков.
func display_day(now_ms: int) -> float:
	var k := clampf(float(now_ms - int(_disp["t0"])) / float(_disp["iv"]), 0.0, 1.0)
	return lerpf(float(_disp["from"]), float(_disp["to"]), k)


func queue_depth() -> int:
	return _pending.size()


# ------------------------------------------------------------------ главный цикл

func update(now_ms: int) -> void:
	_now = now_ms
	if dialer != null and link == null:
		dialer.poll(now_ms)
	if state == "reconnecting" and link == null and _reconnect_at >= 0 and now_ms >= _reconnect_at:
		_reconnect_at = -1
		connect_udp(now_ms)
	if link == null:
		return
	link.poll(now_ms)
	if link.dead:
		link = null
		if auto_reconnect and state != "closed":
			_lost_since = now_ms
			state = "reconnecting"
			adapter.on_notice(Proto.ERR_TIMEOUT, {"auto": true})
			_emit("lost", {})
			_reconnect_tries = 0
			_schedule_reconnect()
		return
	if _recv != null:
		_recv.poll(now_ms)
		if _blob.get("kind", "") != "":
			adapter.on_progress(str(_blob["kind"]), _recv.progress())
	_drain(now_ms)
	app.poll(link)
	if state == "playing" and now_ms - _last_report_ms >= 500:
		_last_report_ms = now_ms
		link.send_unreliable(Proto.M_REPORT, Bytes.W.new().varint(tick).u32(_core).buf)
	if now_ms - _last_ping_ms >= 1000:
		_last_ping_ms = now_ms
		link.send_unreliable(Proto.M_PING, Bytes.W.new().varint(now_ms).buf)
