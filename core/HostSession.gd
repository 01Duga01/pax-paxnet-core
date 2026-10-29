extends "res://mods/paxnet/core/SessionBase.gd"
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ХОСТ ПАРТИИ. Единственный источник порядка: принимает приказы, ставит их в очередь, выпускает
# шаги мира (closure) и рассылает их всем; сверяет миры; лечит расходящиеся разделы; ведёт лобби,
# время, переподключение, сохранение. Сокетов не знает: ему дают датагаммы (UDP через Listener)
# или готовые звенья (WebSocket через admit_stream).

const Handshake = preload("res://mods/paxnet/core/Handshake.gd")
const UdpLink = preload("res://mods/paxnet/core/UdpLink.gd")
const Xfer = preload("res://mods/paxnet/core/Xfer.gd")
const Frag = preload("res://mods/paxnet/core/Frag.gd")
const Delta = preload("res://mods/paxnet/core/Delta.gd")
const AppChannel = preload("res://mods/paxnet/core/AppChannel.gd")

const HOST_ID := 1
const MAX_ACTION_BYTES := 700
const MAX_CLOSURE := 1100       # шаг обязан влезать в одно надёжное сообщение (MTU 1200)
const LOG_TICKS := 3000
const RING_TICKS := 900
const INLINE_PATCH := 8000

var cfg := {
	"name": "", "max_players": 5, "code": "", "mods": "", "game_ver": "",
	"time_mode": "host", "join_in_progress": true, "ready_required": false, "allow_coruler": true,
	"lag_cap_ticks": 160, "ai_grace_ms": 3000, "link_timeout_ms": 10000, "ff_days_per_step": 10, "ff_ms": 100,
	"chat_len": 300,
	# true — мир считает только хост: после шага он сам рассылает изменившиеся разделы (разницей),
	# гости шаг не пересчитывают. Так устроена игра (ход с итогом нейросети). false — все считают
	# по одним правилам, сверка ловит расхождения (как у Factorio).
	"authority": false,
	# true — время двигает сама игра хоста (ход, перемотка, реальное время); сессия только
	# фиксирует прожитое: record_step(days). Иначе шаги идут по таймеру скорости.
	"external_time": false,
	"push_min_ms": 0,              # не чаще (мс) рассылать изменения мира (склейка шагов)
	# Пределы сообщений игры и модов (M_APP) от одного гостя; нарушение рвёт его звено.
	"app_max_unpack": 4 << 20,     # байт после распаковки одного сообщения
	"app_window": 1024,            # насколько номер может уйти вперёд от принятого
	"app_msgs_per_s": 50.0,        # сообщений в секунду (ведро в 2 секунды)
	"app_bytes_per_s": 524288.0,   # байт после распаковки в секунду
	"app_burst_bytes": 6 << 20,    # ведро байт (не меньше app_max_unpack)
	# Лечение разделов (M_RESYNC): не чаще раза в resync_gap_ms и не больше resync_burst подряд, ведро пополняется
	# раз в resync_refill_ms.
	"resync_gap_ms": 250, "resync_burst": 6, "resync_refill_ms": 5000,
}
var phase := "lobby"             # lobby | playing
var peers := {}                  # id → peer
var roster := {}                 # key → {id, name, seat, role, cseq, ai_pending}  (живёт, пока партия)
var listener
var send_to: Callable            # (endpoint, bytes) для UDP
var on_event: Callable           # (kind, data) — наблюдатель: тесты, окно игры
var on_app: Callable             # (from_id, type, data) — сообщение протокола игры/мода для хоста
var _apps := {}                  # ключ игрока → AppChannel (живёт и через переподключения)
var stats := {"steps": 0, "patches": 0, "worlds": 0, "replays": 0, "resyncs": 0, "dup_actions": 0, "rejected": 0, "desync_reports": 0}

var _next_id := 2
var _pending_actions: Array = []
var _pending_events: Array = []
var _pending_news: Array = []
var _pending_ai: Array = []
var _next_news_id := 1
var _log := {}                   # t → байты шага
var _ring := {}                  # t → суммы
var _next_step_ms := 0
var _ff_left := 0
var _lobby_v := 0
var _lobby_sent_v := -1
var _lobby_sent_ms := 0
var _time_sent_v := -1
var _snap_tick := -1
var _snap_bytes := PackedByteArray()
var _snap_raw := 0
var _xfer_id := 1
var _views := {}                 # вид → {data: {раздел: данные}, hash: {раздел: сумма}} (режим власти хоста)
var _last_push_ms := -100000
var _push_due := false
var _skip_advance := false
var _last_ping_ms := 0
var _chat: Array = []
var _chat_rate := {}
var _waiting_note_ms := 0
var host_name := "?"
var host_key := "host"
var host_seat := -1
var pin := "":                   # PIN приглашения; гость без него не пройдёт рукопожатие
	set(v):
		pin = v
		if listener != null:
			listener.pin = v


func _init(adapter_, cfg_: Dictionary = {}) -> void:
	adapter = adapter_
	cfg.merge(cfg_, true)
	my_id = HOST_ID
	time.mode = str(cfg["time_mode"])
	listener = Handshake.Listener.new()
	listener.admit = Callable(self, "_admit")
	listener.on_link = Callable(self, "_attach")
	listener.send_to = func(ep, b): if send_to.is_valid(): send_to.call(ep, b)
	listener.link_tune = link_tune
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	world_seed = rng.randi()


func _emit(kind: String, data: Dictionary = {}) -> void:
	if on_event.is_valid():
		on_event.call(kind, data)


# ------------------------------------------------------------------ транспорт

func on_datagram(endpoint: String, data: PackedByteArray, now_ms: int) -> void:
	listener.on_datagram(endpoint, data, now_ms)


# Звено, созданное транспортом (WebSocket): info — то, что прислал клиент. Возврат: решение.
func admit_stream(info: Dictionary, link, now_ms: int) -> Dictionary:
	var d: Dictionary = _admit("ws", info, now_ms)
	if d.get("ok", false):
		_attach(d.get("ctx"), link, "ws")
	return d


# ------------------------------------------------------------------ допуск

func _humans_online() -> int:
	var n := 1
	for id in peers:
		if peers[id]["state"] != "gone" and peers[id]["state"] != "away":
			n += 1
	return n


func _admit(_endpoint, info: Dictionary, now_ms: int) -> Dictionary:
	var key := str(info.get("key", ""))
	if key == "" or key.length() > 64:
		return {"ok": false, "code": Proto.ERR_CODE}
	if int(info.get("proto", 0)) != Proto.VERSION:
		return {"ok": false, "code": Proto.ERR_VERSION}
	if str(cfg["mods"]) != "" and str(info.get("mods", "")) != str(cfg["mods"]):
		return {"ok": false, "code": Proto.ERR_MODS}
	if str(cfg["code"]) != "" and str(info.get("code", "")) != str(cfg["code"]):
		return {"ok": false, "code": Proto.ERR_CODE}
	var known: Dictionary = roster.get(key, {})
	var reconnect := not known.is_empty()
	if not reconnect:
		if _humans_online() >= int(cfg["max_players"]):
			return {"ok": false, "code": Proto.ERR_FULL}
		if phase == "playing" and not bool(cfg["join_in_progress"]):
			return {"ok": false, "code": Proto.ERR_STARTED}
	var id: int
	if reconnect:
		id = int(known["id"])
		var old = peers.get(id)
		if old != null and old.get("link") != null:
			_close_link(old)
	else:
		id = _next_id
		_next_id += 1
		roster[key] = {"id": id, "name": str(info.get("name", "?")).substr(0, 24), "seat": -1, "role": "spectator", "cseq": 0}
	var mode := "lobby"
	if phase == "playing":
		mode = "world"
		var last_tick := int(info.get("last_tick", -1))
		if reconnect and bool(info.get("has_world", false)) and last_tick >= 0 and tick - last_tick < LOG_TICKS - 5 \
				and _log.has(last_tick + 1) and (last_tick == tick or _log.has(tick)) \
				and _ring.has(last_tick) and int(info.get("core", -1)) == int(_ring[last_tick]["c"]):
			mode = "replay"
	var welcome := {"id": id, "tick": tick, "seed": world_seed, "phase": phase, "mode": mode, "authority": bool(cfg["authority"]),
		"last_cseq": int(roster[key]["cseq"]), "time": time.to_dict(), "host": cfg["name"], "reconnect": reconnect}
	return {"ok": true, "welcome": welcome, "ctx": {"key": key, "id": id, "mode": mode, "last_tick": int(info.get("last_tick", -1)), "reconnect": reconnect, "name": str(info.get("name", ""))}}


func _attach(ctx: Dictionary, link, endpoint) -> void:
	var id: int = ctx["id"]
	var key: String = ctx["key"]
	var r: Dictionary = roster[key]
	if ctx.get("name", "") != "":
		r["name"] = str(ctx["name"]).substr(0, 24)
	var p := {"id": id, "key": key, "link": link, "endpoint": endpoint, "state": "play" if ctx["mode"] != "world" else "sync",
		"rtt": 0.0, "reported": tick, "ready": false, "rate": 0.0, "rate_ms": 0, "frag": Frag.new(), "xfer": null,
		"away_ms": 0, "ai_set": false, "last_resync_ms": -10000,
		"app_t": _now, "app_msgs": float(cfg["app_msgs_per_s"]) * 2.0, "app_bytes": float(maxi(int(cfg["app_burst_bytes"]), int(cfg["app_max_unpack"]))),
		"resync_tokens": float(cfg["resync_burst"]), "resync_t": _now}
	if peers.has(id):
		p["ready"] = bool(peers[id].get("ready", false))
	peers[id] = p
	link.on_message = func(t: int, body: PackedByteArray): _on_message(p, t, body)
	if ctx.get("reconnect", false) and r["seat"] >= 0 and phase == "playing":
		_pending_events.append({"k": "ai", "seat": r["seat"], "on": false})
	_lobby_v += 1
	_send_lobby(p)
	_send_time(p)
	if not _apps.has(key):
		var ch := AppChannel.new()
		ch.max_unpack = int(cfg["app_max_unpack"])
		ch.max_window = int(cfg["app_window"])
		_apps[key] = ch
	else:
		_apps[key].resend(link)      # что не дошло до обрыва — снова, повторы гость отсеет
	if phase == "playing":
		if ctx["mode"] == "replay":
			_send_replay(p, int(ctx["last_tick"]))
		else:
			_send_world(p)
	_emit("peer_joined", {"id": id, "name": r["name"], "reconnect": ctx.get("reconnect", false), "mode": ctx["mode"]})


func _close_link(p: Dictionary) -> void:
	if p.get("link") != null:
		listener.drop(p["link"])
		p["link"].on_message = Callable()
		p["link"] = null


# ------------------------------------------------------------------ приём сообщений

func _on_message(p: Dictionary, type: int, body: PackedByteArray) -> void:
	match type:
		Proto.M_FRAG:
			var done: Array = p["frag"].feed(body)
			if not done.is_empty():
				_on_message(p, int(done[0]), done[1])
		Proto.M_LOBBY_CMD:
			_on_lobby_cmd(p["id"], body)
		Proto.M_CHAT:
			_on_chat(p["id"], body)
		Proto.M_ACTION:
			_on_action(p, body)
		Proto.M_TIME_CMD:
			_on_time_cmd(p["id"], body)
		Proto.M_REPORT:
			var r := Bytes.R.new(body)
			var t := r.varint()
			var hv := r.u32()
			if r.ok:
				p["reported"] = t
				p["report_ms"] = _now
				if _ring.has(t) and int(_ring[t]["c"]) != hv:
					stats["desync_reports"] += 1
		Proto.M_RESYNC:
			_on_resync(p, body)
		Proto.M_XFER_ACK:
			var r2 := Bytes.R.new(body)
			var xid := r2.varint()
			var cum := r2.varint()
			var bm := r2.u64()
			if p["xfer"] != null and r2.ok and p["xfer"].id == xid:
				p["xfer"].on_ack(cum, bm, _now)
		Proto.M_XFER_END:
			var r3 := Bytes.R.new(body)
			var xid2 := r3.varint()
			var ok := r3.u8() == 1
			if p["xfer"] != null and p["xfer"].id == xid2:
				p["xfer"].on_end(ok, _now)
				if ok:
					p["xfer"] = null
					if p["state"] == "sync":
						p["state"] = "play"
					_emit("world_delivered", {"id": p["id"]})
		Proto.M_PING:
			p["link"].send_unreliable(Proto.M_PONG, body)
		Proto.M_PONG:
			var r4 := Bytes.R.new(body)
			var sent := r4.varint()
			if r4.ok:
				p["rtt"] = float(_now - sent)
		Proto.M_APP:
			if not _app_budget(p, body):
				_drop_peer(p, "app_rate")
				return
			var ch2 = _apps[p["key"]]
			var ready: Array = ch2.on_msg(body)
			if ch2.violated:
				ch2.violated = false
				_drop_peer(p, "app_abuse")
				return
			for m in ready:
				_route_app(p["id"], m)
		Proto.M_APP_ACK:
			_apps[p["key"]].on_ack(body)
		Proto.M_BYE:
			_drop_peer(p, "bye")
		Proto.M_REPLAY:
			pass


var _now := 0


# ------------------------------------------------------------------ сообщения игры и модов

# Гость шлёт хосту; хост доставляет адресату (себе, одному гостю или всем, кроме автора).
# Автора ставит хост по настоящему отправителю.
func _route_app(from_id: int, m: Dictionary) -> void:
	var to := int(m.get("to", HOST_ID))
	var type := str(m.get("type", ""))
	if to == HOST_ID or to == 0:
		if on_app.is_valid():
			on_app.call(from_id, type, m.get("data"))
	if to != HOST_ID:
		_app_deliver(from_id, to, type, m.get("data"))


func _app_deliver(from_id: int, to: int, type: String, data) -> void:
	for id in peers:
		var p: Dictionary = peers[id]
		if (to == 0 and id != from_id) or id == to:
			var ch = _apps.get(p["key"])
			if ch != null:
				ch.send(p.get("link"), {"from": from_id, "to": to, "type": type, "data": data})


# Хост шлёт гостю (to — id) или всем (to = 0).
func app_send(to: int, type: String, data) -> void:
	_app_deliver(HOST_ID, to, type, data)


# ------------------------------------------------------------------ приказы

func _on_action(p: Dictionary, body: PackedByteArray) -> void:
	var d := Bytes.decode(body)
	if not d["ok"] or not (d["v"] is Dictionary):
		return
	var a: Dictionary = d["v"]
	var c := int(a.get("c", 0))
	var r: Dictionary = roster[p["key"]]
	if c <= int(r["cseq"]):
		stats["dup_actions"] += 1
		_ack_action(p, c, true, "dup")
		return
	r["cseq"] = c
	var res := _queue_action(p["id"], c, str(a.get("k", "")), a.get("g"), body.size())
	_ack_action(p, c, res["ok"], str(res.get("code", "")))


func _ack_action(p: Dictionary, c: int, ok: bool, code: String) -> void:
	if p.get("link") != null:
		p["link"].send_reliable(Proto.M_ACTION_RESULT, Bytes.encode({"c": c, "ok": ok, "code": code}))


func _queue_action(player_id: int, c: int, kind: String, args, size: int) -> Dictionary:
	var key := _key_of(player_id)
	var r: Dictionary = roster.get(key, {"seat": host_seat, "role": "player", "name": host_name})
	if phase != "playing":
		return {"ok": false, "code": Proto.ERR_ILLEGAL}
	if size > MAX_ACTION_BYTES or kind == "" or kind.length() > 40:
		stats["rejected"] += 1
		return {"ok": false, "code": Proto.ERR_ILLEGAL}
	var policy: String = "own" if kind.begins_with("mail.") else adapter.action_policy(kind)
	if policy == "host" and player_id != HOST_ID:
		stats["rejected"] += 1
		return {"ok": false, "code": Proto.ERR_HOST_ONLY}
	if policy != "free" and (int(r["seat"]) < 0 or not (str(r["role"]) in ["player", "coruler"])):
		stats["rejected"] += 1
		return {"ok": false, "code": Proto.ERR_ILLEGAL}
	if player_id != HOST_ID and not _rate_ok(player_id):
		stats["rejected"] += 1
		return {"ok": false, "code": Proto.ERR_RATE}
	_pending_actions.append({"p": player_id, "s": int(r["seat"]), "r": str(r["role"]), "c": c, "k": kind, "g": args})
	return {"ok": true, "code": ""}


# Ведра на гостя: сообщений и байт (по заявленному размеру после распаковки). false — лимит пробит.
func _app_budget(p: Dictionary, body: PackedByteArray) -> bool:
	var size: int = AppChannel.claimed_size(body)
	if size < 0:
		return false
	var dt := float(_now - int(p["app_t"])) / 1000.0
	p["app_t"] = _now
	var msgs: float = float(cfg["app_msgs_per_s"])
	var per_s: float = float(cfg["app_bytes_per_s"])
	var cap_b: float = float(maxi(int(cfg["app_burst_bytes"]), int(cfg["app_max_unpack"])))
	p["app_msgs"] = minf(float(p["app_msgs"]) + dt * msgs, msgs * 2.0) - 1.0
	p["app_bytes"] = minf(float(p["app_bytes"]) + dt * per_s, cap_b) - float(size)
	return float(p["app_msgs"]) >= 0.0 and float(p["app_bytes"]) >= 0.0


func _rate_ok(id: int) -> bool:
	var e: Dictionary = _chat_rate.get("a%d" % id, {"t": _now, "n": 0.0})
	var dt := float(_now - int(e["t"])) / 1000.0
	var n := maxf(float(e["n"]) - dt * 20.0, 0.0) + 1.0
	_chat_rate["a%d" % id] = {"t": _now, "n": n}
	return n <= 40.0


func _key_of(id: int) -> String:
	for k in roster:
		if int(roster[k]["id"]) == id:
			return k
	return ""


# Приказ самого хоста — тем же путём, что и у гостей.
func host_action(kind: String, args = null) -> Dictionary:
	var c := int(roster.get(host_key, {}).get("cseq", 0)) + 1
	if not roster.has(host_key):
		roster[host_key] = {"id": HOST_ID, "name": host_name, "seat": host_seat, "role": "player", "cseq": 0}
	roster[host_key]["cseq"] = c
	roster[host_key]["seat"] = host_seat
	return _queue_action(HOST_ID, c, kind, args, Bytes.encode(args).size())


# ------------------------------------------------------------------ лобби

func _on_lobby_cmd(id: int, body: PackedByteArray) -> void:
	var d := Bytes.decode(body)
	if not d["ok"] or not (d["v"] is Dictionary):
		return
	lobby_cmd(id, d["v"])


# Команда лобби. Для хоста зовётся напрямую: lobby_cmd(1, {...}).
func lobby_cmd(id: int, cmd: Dictionary) -> Dictionary:
	var key := _key_of(id)
	if id == HOST_ID and not roster.has(host_key):
		roster[host_key] = {"id": HOST_ID, "name": host_name, "seat": host_seat, "role": "player", "cseq": 0}
		key = host_key
	if key == "":
		return {"ok": false}
	var r: Dictionary = roster[key]
	var res := {"ok": true, "code": ""}
	match str(cmd.get("op", "")):
		"seat":
			res = _choose_seat(id, key, int(cmd.get("seat", -1)), str(cmd.get("role", "player")))
		"ready":
			if peers.has(id):
				peers[id]["ready"] = bool(cmd.get("on", true))
			elif id == HOST_ID:
				_host_ready = bool(cmd.get("on", true))
		"name":
			r["name"] = str(cmd.get("name", "")).substr(0, 24)
		"rules":
			if id != HOST_ID:
				return {"ok": false, "code": Proto.ERR_HOST_ONLY}
			for k in ["time_mode", "join_in_progress", "ready_required", "allow_coruler", "max_players"]:
				if cmd.has(k):
					cfg[k] = cmd[k]
			time.mode = str(cfg["time_mode"])
			time.version += 1
		"kick":
			if id != HOST_ID:
				return {"ok": false, "code": Proto.ERR_HOST_ONLY}
			var target = peers.get(int(cmd.get("id", 0)))
			if target != null:
				_notice(target, Proto.ERR_KICKED)
				_drop_peer(target, "kicked")
		"start":
			if id != HOST_ID:
				return {"ok": false, "code": Proto.ERR_HOST_ONLY}
			res = start_game()
		_:
			return {"ok": false, "code": Proto.ERR_ILLEGAL}
	_lobby_v += 1
	return res


var _host_ready := true


func _choose_seat(id: int, key: String, seat: int, role: String) -> Dictionary:
	var r: Dictionary = roster[key]
	if role == "spectator" or seat < 0:
		_release_seat(key)
		r["seat"] = -1
		r["role"] = "spectator"
		return {"ok": true}
	var holder := ""
	for k in roster:
		if k != key and int(roster[k]["seat"]) == seat and str(roster[k]["role"]) == "player":
			holder = k
	if role == "player" and holder != "":
		return {"ok": false, "code": Proto.ERR_SEAT_TAKEN}
	if role == "coruler" and (holder == "" or not bool(cfg["allow_coruler"])):
		return {"ok": false, "code": Proto.ERR_ILLEGAL}
	if role != "player" and role != "coruler":
		return {"ok": false, "code": Proto.ERR_ILLEGAL}
	_release_seat(key)
	r["seat"] = seat
	r["role"] = role
	if id == HOST_ID:
		host_seat = seat
	if phase == "playing":
		_pending_events.append({"k": "seat", "seat": seat, "id": id, "key": seat_tag(key), "name": r["name"], "role": role, "ai": false})
	return {"ok": true}


func _release_seat(key: String) -> void:
	var r: Dictionary = roster[key]
	if int(r["seat"]) >= 0 and phase == "playing" and str(r["role"]) == "player":
		_pending_events.append({"k": "seat", "seat": int(r["seat"]), "id": 0})


func lobby_state() -> Dictionary:
	var players: Array = [{"id": HOST_ID, "name": host_name, "seat": host_seat, "role": "player" if host_seat >= 0 else "spectator",
		"ready": _host_ready, "ai": false, "ping": 0, "host": true, "away": false}]
	for k in roster:
		var r: Dictionary = roster[k]
		if int(r["id"]) == HOST_ID:
			continue
		var p = peers.get(int(r["id"]))
		players.append({"id": r["id"], "name": r["name"], "seat": r["seat"], "role": r["role"],
			"ready": bool(p["ready"]) if p != null else false, "ai": p == null or p["state"] == "away",
			"ping": int(p["rtt"]) if p != null else 0, "host": false, "away": p == null or p["state"] == "away"})
	return {"v": _lobby_v, "phase": phase, "name": cfg["name"], "code": cfg["code"], "players": players,
		"rules": {"time_mode": cfg["time_mode"], "max": cfg["max_players"], "join": cfg["join_in_progress"],
			"ready": cfg["ready_required"], "coruler": cfg["allow_coruler"]}}


func _send_lobby(p: Dictionary) -> void:
	if p.get("link") == null:
		return
	var st := lobby_state()
	st["countries"] = adapter.countries()
	Frag.send(p["link"], Proto.M_LOBBY, Bytes.encode(st))


func _broadcast_lobby() -> void:
	var st := lobby_state()
	var data := Bytes.encode(st)
	for id in peers:
		var p: Dictionary = peers[id]
		if p.get("link") != null:
			Frag.send(p["link"], Proto.M_LOBBY, data)
	adapter.on_roster_changed(st["players"])
	_emit("lobby", st)


# ------------------------------------------------------------------ чат

func _on_chat(id: int, body: PackedByteArray) -> void:
	var d := Bytes.decode(body)
	if not d["ok"] or not (d["v"] is Dictionary):
		return
	chat(id, str(d["v"].get("text", "")))


func chat(id: int, text: String) -> bool:
	text = text.strip_edges().substr(0, int(cfg["chat_len"]))
	if text == "":
		return false
	var e: Dictionary = _chat_rate.get("c%d" % id, {"t": _now, "n": 0.0})
	var n := maxf(float(e["n"]) - float(_now - int(e["t"])) / 1000.0 * 0.5, 0.0) + 1.0
	_chat_rate["c%d" % id] = {"t": _now, "n": n}
	if n > 6.0:
		var p0 = peers.get(id)
		if p0 != null:
			_notice(p0, Proto.ERR_RATE)
		return false
	var key := _key_of(id)
	var nm: String = str(roster[key]["name"]) if key != "" else host_name
	var line := {"from": id, "name": nm, "text": text, "t": _now}
	_chat.append(line)
	if _chat.size() > 100:
		_chat.pop_front()
	var b := Bytes.encode(line)
	for pid in peers:
		var p: Dictionary = peers[pid]
		if p.get("link") != null and p["state"] != "gone":
			p["link"].send_reliable(Proto.M_CHAT, b)
	adapter.on_chat(id, nm, text)
	return true


# ------------------------------------------------------------------ время

func _on_time_cmd(id: int, body: PackedByteArray) -> void:
	var d := Bytes.decode(body)
	if d["ok"] and d["v"] is Dictionary:
		time_cmd(id, str(d["v"].get("k", "")), d["v"].get("v"))


func time_cmd(id: int, kind: String, value = null) -> Dictionary:
	var key := _key_of(id)
	var nm: String = str(roster[key]["name"]) if key != "" else host_name
	var voters: Array = [HOST_ID]
	for pid in peers:
		if peers[pid]["state"] == "play" or peers[pid]["state"] == "sync":
			voters.append(pid)
	var res: Dictionary = time.command(id, nm, id == HOST_ID, kind, value, voters, _now)
	if not res["ok"]:
		var p = peers.get(id)
		if p != null:
			_notice(p, str(res["code"]))
	return res


func fast_forward(days: int) -> void:
	_ff_left = maxi(days, 0)


func _send_time(p: Dictionary) -> void:
	if p.get("link") != null:
		p["link"].send_reliable(Proto.M_TIME, Bytes.encode(time.to_dict()))


func _notice(p: Dictionary, code: String, args: Dictionary = {}) -> void:
	if p.get("link") != null:
		p["link"].send_reliable(Proto.M_NOTICE, Bytes.encode({"code": code, "args": args}))


# ------------------------------------------------------------------ новости и нейросеть

# Итог хода — в газету/хронику, один раз и с номером. kind: "news"|"chronicle"; text — уже готовый.
func publish_news(kind: String, text: String, extra: Dictionary = {}) -> int:
	var id := _next_news_id
	_next_news_id += 1
	var e := {"id": id, "kind": kind, "text": text, "day": adapter.current_day()}
	e.merge(extra)
	_pending_news.append(e)
	return id


# Итог нейросети — всем одинаковый. rid — номер запроса (один раз на запрос).
func publish_ai(rid: int, text: String, outcome: Dictionary = {}) -> void:
	_pending_ai.append({"rid": rid, "text": text, "outcome": outcome})


# ------------------------------------------------------------------ старт и шаги

func start_game() -> Dictionary:
	if phase == "playing":
		return {"ok": false, "code": Proto.ERR_ILLEGAL}
	if bool(cfg["ready_required"]):
		for id in peers:
			if peers[id]["state"] != "away" and not bool(peers[id]["ready"]):
				return {"ok": false, "code": "not_ready"}
	phase = "playing"
	seats = {}
	for k in roster:
		var r: Dictionary = roster[k]
		if int(r["seat"]) >= 0 and str(r["role"]) == "player":
			var away: bool = peers.has(int(r["id"])) and peers[int(r["id"])]["state"] == "away" or (not peers.has(int(r["id"])) and int(r["id"]) != HOST_ID)
			var ev := {"k": "seat", "seat": int(r["seat"]), "id": int(r["id"]), "key": seat_tag(k), "name": r["name"], "role": "player", "ai": away}
			_apply_event(ev)
	time.paused = false
	time.version += 1
	_next_step_ms = _now
	_snap_tick = -1
	_snaps = {}
	_views = {}
	for id in peers:
		var p: Dictionary = peers[id]
		if p.get("link") != null:
			p["state"] = "sync"
			_send_lobby(p)
			_send_world(p)
	_emit("started", {})
	return {"ok": true}


var _snaps := {}                 # вид → {tick, bytes, raw}


func _snapshot(view = "") -> Dictionary:
	var sn: Dictionary = _snaps.get(view, {})
	if sn.get("tick", -1) != tick or _snap_tick == -1:
		var raw: PackedByteArray = adapter.world_snapshot_view(view)
		sn = {"tick": tick, "raw": raw.size(), "bytes": raw.compress(Bytes.ZSTD)}
		_snaps[view] = sn
		_snap_tick = tick
	return sn


func _send_world(p: Dictionary) -> void:
	var view = _peer_view(p) if bool(cfg["authority"]) else ""
	var s := _snapshot(view)
	if bool(cfg["authority"]):
		# опорная копия вида = то, что гость получит: разницы дальше строятся от неё
		adapter.begin_views(tick)
		_views.erase(p["id"])
		_changed_for(view, p["id"])
	var xid := _xfer_id
	_xfer_id += 1
	var meta := {"as_of": tick, "seed": world_seed, "raw": s["raw"], "own": own_section_data(["mail", "seats"]),
		"time": time.to_dict(), "news_next": _next_news_id}
	var sender = Xfer.Sender.new(p["link"], xid, s["bytes"], meta)
	p["xfer"] = sender
	p["state"] = "sync"
	p["link"].send_reliable(Proto.M_WORLD, Bytes.encode({"as_of": tick, "xid": xid, "meta": meta}))
	stats["worlds"] += 1
	_emit("world_sent", {"id": p["id"], "bytes": s["bytes"].size(), "as_of": tick})


func _send_replay(p: Dictionary, last_tick: int) -> void:
	for t in range(last_tick + 1, tick + 1):
		_send_closure(p["link"], _log[t], false)
	stats["replays"] += 1
	p["state"] = "play"
	_emit("replay_sent", {"id": p["id"], "from": last_tick + 1, "to": tick})


func _slowest_lag() -> int:
	var worst := 0
	for id in peers:
		var p: Dictionary = peers[id]
		if p["state"] == "play":
			worst = maxi(worst, tick - int(p["reported"]))
	return worst


# Сколько приказов влезет в шаг: место под суммы разделов меряем по полному набору сумм.
func _step_budget_actions(head: Dictionary) -> Array:
	var fixed := Bytes.encode(head).size() + Bytes.encode(core_hashes(tick, true)).size() + 16
	var take: Array = []
	var size := fixed
	while not _pending_actions.is_empty():
		var sz := Bytes.encode(_pending_actions[0]).size() + 2
		if size + sz > MAX_CLOSURE:
			break
		size += sz
		take.append(_pending_actions.pop_front())
	return take


func _take_fitting(q: Array, budget: int) -> Array:
	var out: Array = []
	var size := 0
	while not q.is_empty():
		var sz := Bytes.encode(q[0]).size()
		if size + sz > budget and not out.is_empty():
			break
		size += sz
		out.append(q.pop_front())
	return out


func _do_step(days: int, iv: int) -> void:
	# события, новости и итоги нейросети тоже делим по размеру: в шаг — сколько влезет
	var c := {"t": tick + 1, "n": days, "iv": iv, "ev": _take_fitting(_pending_events, 300), "nw": _take_fitting(_pending_news, 300), "ai": _take_fitting(_pending_ai, 300)}
	c["a"] = _step_budget_actions(c)
	_skip_advance_now = _skip_advance
	var results := apply_closure(c)
	_skip_advance_now = false
	c["h"] = core_hashes(tick)
	var pushes := {}                 # вид → изменения
	if bool(cfg["authority"]):
		if _push_due or _now - _last_push_ms >= int(cfg["push_min_ms"]) or days == 0:
			_push_due = false
			_last_push_ms = _now
			adapter.begin_views(tick)
			for id in peers:
				var pp: Dictionary = peers[id]
				if pp.get("link") != null and (pp["state"] == "play" or pp["state"] == "sync"):
					pushes[id] = _changed_for(_peer_view(pp), id)
			c["p"] = true
		else:
			_push_due = true
	_ring[tick] = {"h": c["h"], "c": StateHash.short(c["h"])}
	if bool(cfg["authority"]):
		c.erase("h")                 # у каждого вида свои суммы — они едут с изменениями шага
	var bytes := encode_closure(c)
	_log[tick] = bytes
	if _log.has(tick - LOG_TICKS):
		_log.erase(tick - LOG_TICKS)
	if _ring.has(tick - RING_TICKS):
		_ring.erase(tick - RING_TICKS)
	stats["steps"] += 1
	for id in peers:
		var p: Dictionary = peers[id]
		if p.get("link") != null and (p["state"] == "play" or p["state"] == "sync"):
			_send_closure(p["link"], bytes, true)
			if c.has("p") and pushes.has(id):
				_send_push(p, pushes[id])
	# итог приказа — автору (в режиме власти хоста гость сам его не узнает)
	for r in results:
		var who = peers.get(int(r["p"]))
		if who != null and who.get("link") != null:
			var res: Dictionary = r["result"]
			who["link"].send_reliable(Proto.M_ACTION_RESULT, Bytes.encode({"c": r["c"], "ok": bool(res.get("ok", false)),
				"code": str(res.get("code", "")), "text": str(res.get("text", "")), "k": r["k"], "done": true, "t": tick}))
	_emit("step", {"t": tick, "n": days})


# Изменения шага для гостя: разница к тому, что он уже получил (опорная копия у каждого гостя своя),
# в его виде мира. Данные вида считаются один раз за шаг (кэш на всех гостей одного вида).
# Возврат: {delta: {раздел: разница}, hs: {раздел: сумма после шага}}.
var _step_cache := {}            # вид → {"t", "hs", "data"}


func _view_now(view) -> Dictionary:
	var c: Dictionary = _step_cache.get(view, {})
	if c.get("t", -1) != tick:
		var hs: Dictionary = adapter.hashes_view(view, tick, true)
		hs.merge(_own_sections())
		c = {"t": tick, "hs": hs, "data": {}}
		_step_cache[view] = c
	return c


func _changed_for(view, sid) -> Dictionary:
	var cur := _view_now(view)
	var hs: Dictionary = cur["hs"]
	var st: Dictionary = _views.get(sid, {"data": {}, "hash": {}})
	_views[sid] = st
	var changed: Array = []
	for n in adapter.section_names() + ["mail", "seats"]:
		if not st["hash"].has(n) or int(st["hash"][n]) != int(hs.get(n, -1)):
			changed.append(n)
	if changed.is_empty():
		return {"delta": {}, "hs": hs}
	var need: Array = changed.filter(func(n): return not cur["data"].has(n))
	if not need.is_empty():
		var got: Dictionary = adapter.section_data_view(view, need.filter(func(n): return n != "mail" and n != "seats"))
		got.merge(own_section_data(need))
		cur["data"].merge(got)
	var out := {}
	for n in changed:
		out[n] = Delta.diff(st["data"].get(n), cur["data"].get(n))
		st["data"][n] = cur["data"].get(n)
		st["hash"][n] = int(hs.get(n, -1))
	return {"delta": out, "hs": hs}


func _peer_view(p: Dictionary):
	var r: Dictionary = roster.get(p["key"], {})
	return adapter.view_of(int(r.get("seat", -1)))


# Изменения шага — гостю сразу за шагом: малые частями в потоке, большие — передачей без остановки.
func _send_push(p: Dictionary, push: Dictionary) -> void:
	var payload := Bytes.encode({"as_of": tick, "delta": push["delta"], "hs": push["hs"]})
	if payload.size() <= INLINE_PATCH or p["xfer"] != null:
		Frag.send(p["link"], Proto.M_PATCH, payload)
	else:
		var xid := _xfer_id
		_xfer_id += 1
		p["xfer"] = Xfer.Sender.new(p["link"], xid, payload.compress(Bytes.ZSTD), {"patch": true, "raw": payload.size()})
		p["link"].send_reliable(Proto.M_PATCH_BLOB, Bytes.encode({"as_of": tick, "xid": xid, "raw": payload.size()}))


# Обычный шаг едет избыточно (в каждом пакете, пока не подтверждён); большой (длинный рассказ
# нейросети, много новостей) — частями, надёжно и по порядку. Порядок шагов от этого не меняется.
func _send_closure(link, bytes: PackedByteArray, redundant: bool) -> void:
	if bytes.size() <= link.max_message() - 2:
		link.send_reliable(Proto.M_CLOSURE, bytes, redundant)
	else:
		Frag.send(link, Proto.M_CLOSURE, bytes)


# Время двигает игра хоста: она уже прожила days дней. Фиксируем шаг (приказы, что накопились,
# исполняются в нём же), рассылаем изменения.
func record_step(days: int, iv: int = 0) -> void:
	if phase != "playing":
		return
	_skip_advance = true
	_do_step(days, iv)
	_skip_advance = false


# ------------------------------------------------------------------ лечение

func _on_resync(p: Dictionary, body: PackedByteArray) -> void:
	var d := Bytes.decode(body)
	if not d["ok"] or not (d["v"] is Dictionary) or p["state"] != "play":
		return
	if _now - int(p["last_resync_ms"]) < int(cfg["resync_gap_ms"]):
		return
	p["last_resync_ms"] = _now
	var refill := float(_now - int(p["resync_t"])) / float(maxi(int(cfg["resync_refill_ms"]), 1))
	p["resync_t"] = _now
	p["resync_tokens"] = minf(float(p["resync_tokens"]) + refill, float(cfg["resync_burst"]))
	if float(p["resync_tokens"]) < 1.0:
		stats["rejected"] += 1
		return
	p["resync_tokens"] = float(p["resync_tokens"]) - 1.0
	var names: Array = []
	var known: Array = adapter.section_names() + ["mail", "seats"]
	for n in d["v"].get("names", []):
		if known.has(str(n)):
			names.append(str(n))
	if names.is_empty():
		return
	stats["resyncs"] += 1
	var mine: Array = []
	var own: Array = []
	for n in names:
		if n == "mail" or n == "seats":
			own.append(n)
		else:
			mine.append(n)
	var data: Dictionary = adapter.section_data_view(_peer_view(p), mine) if not mine.is_empty() else {}
	data.merge(own_section_data(own))
	if bool(cfg["authority"]):
		# лечим и опорную копию вида: следующая разница строится от того, что у гостя теперь есть
		var st: Dictionary = _views.get(p["id"], {"data": {}, "hash": {}})
		var hsv: Dictionary = _view_now(_peer_view(p))["hs"]
		for n in data:
			if st["data"].has(n):
				st["data"][n] = data[n]
				st["hash"][n] = int(hsv.get(n, -1))
	var payload := Bytes.encode({"as_of": tick, "data": data})
	if payload.size() <= INLINE_PATCH or p["xfer"] != null:
		Frag.send(p["link"], Proto.M_PATCH, payload)
	else:
		var xid := _xfer_id
		_xfer_id += 1
		p["xfer"] = Xfer.Sender.new(p["link"], xid, payload.compress(Bytes.ZSTD), {"patch": true, "raw": payload.size()})
		p["link"].send_reliable(Proto.M_PATCH_BLOB, Bytes.encode({"as_of": tick, "xid": xid, "raw": payload.size()}))
	stats["patches"] += 1
	_emit("patch_sent", {"id": p["id"], "names": names, "bytes": payload.size()})


# ------------------------------------------------------------------ уход игроков

func _drop_peer(p: Dictionary, why: String) -> void:
	if p["state"] == "away" or p["state"] == "gone":
		return
	p["state"] = "away"
	p["away_ms"] = _now
	p["xfer"] = null
	if p.get("link") != null:
		if why == "kicked":
			p["link"].send_reliable(Proto.M_BYE, Bytes.encode({"why": why}))
		_close_link(p)
	_lobby_v += 1
	_emit("peer_left", {"id": p["id"], "why": why})


# Хост закрывает партию: всем гостям - прощание (гости не переподключаются, а пишут «хост закрыл игру»).
func close_all(why: String = "host_left") -> void:
	for id in peers:
		var p: Dictionary = peers[id]
		if p.get("link") != null:
			p["link"].send_reliable(Proto.M_BYE, Bytes.encode({"why": why}))
			p["link"].poll(_now)


# ------------------------------------------------------------------ главный цикл

func update(now_ms: int) -> void:
	_now = now_ms
	time.expire(now_ms)
	var ids := peers.keys()
	for id in ids:
		var p: Dictionary = peers[id]
		var link = p.get("link")
		if link != null:
			link.poll(now_ms)
			if link.dead:
				_drop_peer(p, "timeout")
				continue
			if p["xfer"] != null:
				p["xfer"].poll(now_ms)
			if _apps.has(p["key"]):
				_apps[p["key"]].poll(link)
		elif p["state"] == "away" and not p["ai_set"] and now_ms - int(p["away_ms"]) >= int(cfg["ai_grace_ms"]):
			p["ai_set"] = true
			var r: Dictionary = roster[p["key"]]
			if phase == "playing" and int(r["seat"]) >= 0 and str(r["role"]) == "player":
				_pending_events.append({"k": "ai", "seat": int(r["seat"]), "on": true})
		if p["state"] != "away":
			p["ai_set"] = false
	if now_ms - _last_ping_ms >= 500:
		_last_ping_ms = now_ms
		for id in peers:
			var p2: Dictionary = peers[id]
			if p2.get("link") != null:
				p2["link"].send_unreliable(Proto.M_PING, Bytes.W.new().varint(now_ms).buf)
	if time.version != _time_sent_v:
		_time_sent_v = time.version
		for id in peers:
			_send_time(peers[id])
		adapter.on_time_state(time.to_dict())
	if _lobby_v != _lobby_sent_v and now_ms - _lobby_sent_ms >= 100:
		_lobby_sent_v = _lobby_v
		_lobby_sent_ms = now_ms
		_broadcast_lobby()
	if phase == "playing":
		_maybe_step(now_ms)


func _maybe_step(now_ms: int) -> void:
	if _slowest_lag() > int(cfg["lag_cap_ticks"]):
		if now_ms - _waiting_note_ms > 5000:
			_waiting_note_ms = now_ms
			_emit("waiting_for_slow", {"lag": _slowest_lag()})
		return
	var has_extra := not _pending_actions.is_empty() or not _pending_events.is_empty() or not _pending_news.is_empty() or not _pending_ai.is_empty()
	var days := 0
	var iv := 100
	if bool(cfg["external_time"]):
		if has_extra:
			_skip_advance = true
			_do_step(0, 0)
			_skip_advance = false
		return
	if _ff_left > 0:
		days = mini(_ff_left, int(cfg["ff_days_per_step"]))
		iv = int(cfg["ff_ms"])
	elif not time.paused:
		var sp := time.step_params()
		days = int(sp["days"])
		iv = int(sp["ms"])
	if days > 0:
		if now_ms >= _next_step_ms:
			_do_step(days, iv)
			_ff_left = maxi(_ff_left - days, 0)
			_next_step_ms = maxi(_next_step_ms + iv, now_ms - iv)
		elif has_extra and _next_step_ms - now_ms > 100:
			_do_step(0, 0)
	elif has_extra:
		var guard := 0
		while (not _pending_actions.is_empty() or not _pending_events.is_empty() or not _pending_news.is_empty() or not _pending_ai.is_empty()) and guard < 6:
			guard += 1
			_do_step(0, 0)


# ------------------------------------------------------------------ сохранение и продолжение

# Всё, кроме самого мира (его пишет игра): кто за какой страной, номера приказов, время, дела.
func save_state() -> Dictionary:
	var ro := {}
	for k in roster:
		ro[k] = roster[k].duplicate()
	return {"v": 1, "tick": tick, "seed": world_seed, "roster": ro, "cfg": cfg.duplicate(), "mail": mailbox.to_dict(),
		"time": time.to_dict(), "next_id": _next_id, "news_next": _next_news_id, "seats": seats.duplicate(true),
		"host_seat": host_seat}


# Продолжение: те же игроки и страны. Гости возвращаются по своим ключам.
func load_state(s: Dictionary) -> void:
	tick = int(s["tick"])
	world_seed = int(s["seed"])
	roster = {}
	for k in s["roster"]:
		var r: Dictionary = (s["roster"][k] as Dictionary).duplicate()
		r["id"] = int(r["id"])
		r["seat"] = int(r["seat"])
		r["cseq"] = int(r["cseq"])
		roster[k] = r
	for k in ["time_mode", "join_in_progress", "ready_required", "allow_coruler", "max_players"]:
		if s["cfg"].has(k):
			cfg[k] = s["cfg"][k]
	mailbox.load_dict(s["mail"])
	time.load_dict(s["time"])
	time.paused = true
	_next_id = int(s["next_id"])
	_next_news_id = int(s["news_next"])
	host_seat = int(s.get("host_seat", -1))
	phase = "lobby"
	seats = {}
	for k in s["seats"]:
		seats[int(k)] = s["seats"][k]
	_lobby_v += 1
