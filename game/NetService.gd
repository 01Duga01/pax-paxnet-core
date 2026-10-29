extends "res://mods/paxnet_core/net/Session.gd"
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# СЕТЕВАЯ ПАРТИЯ В МИРЕ PAX UNIVERSE (стратегия). Живёт в /root/PaxNetWorld и переживает
# перезагрузку сцены (вход в мир хоста, лечение «перезагрузкой»). Мир считает хост (authority), время
# двигает игра хоста (external_time): ход, перемотка, реальное время. Гостям уходят изменившиеся
# разделы записи мира в их виде (GameAdapter, WorldKeys). Окно состояния - ui/NetOverlay.gd.
#
# В оригинальном PaxNet служба подменяла узел сети игры (replace_service) и сама открывала UDP-порт.
# В библиотеке узел сети игры остаётся игровым: связь идёт его же каналом relay_pipe(), а партию
# открывает мод, которому она нужна: PaxNetLib.world_service().host_open(...) / guest_join(...).

const GameAdapter = preload("res://mods/paxnet_core/game/GameAdapter.gd")
const Mailbox = preload("res://mods/paxnet_core/core/Mailbox.gd")

signal lobby_changed
signal connection_lost(why: String)
signal app_message(from_id: int, type: String, data: Variant)
signal state_changed(state: Dictionary)

const NODE_NAME: String = "PaxNetWorld"
const RELOAD_GAP_MS: int = 30000
const MSG_CHAT: String = "paxnet.chat"
const MSG_DEAL: String = "paxnet.deal"
## Торговля в два шага: хост просит отдающего списать сумму (MSG_DEBIT), тот отвечает (MSG_PAID), и только потом
## получатель получает деньги. Так деньги не появляются из воздуха, пока отдающий честен.
const MSG_DEBIT: String = "paxnet.deal_debit"
const MSG_PAID: String = "paxnet.deal_paid"
const MAX_PENDING_DEBITS: int = 64

## PaxMod библиотеки: настройки (ключ игрока) и перевод.
var mod: Object = null
## Из сейва хоста: те же игроки и страны, тот же код комнаты.
var resume_state: Dictionary = {}
## Хост: ждём подтверждения списания. id → {pid, to, from, amt}.
var _debits: Dictionary = {}
var _debit_seq: int = 0
var settings: Dictionary = {"time_mode": "host", "join_in_progress": true, "allow_coruler": true, "max_players": 5}
var progress_what: String = ""
var progress_ratio: float = 1.0
var news_seen: Dictionary = {}
var _last_reload_ms: int = -RELOAD_GAP_MS
var _reload_pending: bool = false


static func get_or_create(tree: SceneTree) -> Node:
	var n: Node = tree.root.get_node_or_null(NODE_NAME)
	if n == null:
		var s: Variant = load("res://mods/paxnet_core/game/NetService.gd")
		n = (s as Script).new() as Node
		n.name = NODE_NAME
		tree.root.add_child.call_deferred(n)
	return n


func _ready() -> void:
	super._ready()
	message.connect(_on_message)
	changed.connect(_emit_state)
	failed.connect(func(c: String) -> void: connection_lost.emit(c))


func _pax() -> Node:
	return get_tree().root.get_node_or_null("/root/Pax") if is_inside_tree() else null


func _game() -> Object:
	var p: Node = _pax()
	if p == null:
		return null
	var g: Variant = p.get("game")
	return g as Object if g is Object else null


# Постоянный ключ игрока (место в партии держится за ним; хранится в настройках мода).
func _key() -> String:
	if player_key != "":
		return player_key
	var k: String = str(mod.call("get_setting", "player_key", "")) if mod != null else ""
	if k == "":
		var c: Crypto = Crypto.new()
		k = c.generate_random_bytes(16).hex_encode()
		if mod != null:
			mod.call("set_setting", "player_key", k)
	player_key = k
	return k


# ------------------------------------------------------------------ хост

func host_open(display_name_: String, rules: Dictionary = {}) -> String:
	var cfg: Dictionary = {"authority": true, "external_time": true, "push_min_ms": 500,
		"time_mode": str(rules.get("time_mode", settings["time_mode"])),
		"join_in_progress": bool(rules.get("join_in_progress", settings["join_in_progress"])),
		"allow_coruler": bool(rules.get("allow_coruler", settings["allow_coruler"])),
		"max_players": int(rules.get("max_players", settings["max_players"])), "mods": str(rules.get("mods", "")),
		"preset": "paxnet_world", "want_code": str(resume_state.get("code", "")), "want_pin": str(resume_state.get("pin", ""))}
	var ad: Object = GameAdapter.new()
	ad.set("service", self)
	var err: String = host(display_name_, ad, cfg)
	if err != "":
		return err
	var p: Node = _pax()
	if p != null and p.has_signal("world_stepped") and not p.is_connected("world_stepped", _on_world_stepped):
		p.connect("world_stepped", _on_world_stepped)
	return ""


func _prepare_host(_cfg: Dictionary) -> void:
	if not resume_state.is_empty():
		session.call("load_state", resume_state)
	var g: Object = _game()
	if g != null:
		session.call("lobby_cmd", HOST_ID, {"op": "seat", "seat": int(adapter.call("seat_of_country", str(g.call("country")))), "role": "player"})


# Партия начинается (хост нажал «Начать»): гости получают мир.
func host_start() -> Dictionary:
	return start()


func host_seat() -> int:
	var g: Object = _game()
	if adapter == null or g == null:
		return -1
	return int(adapter.call("seat_of_country", str(g.call("country"))))


func player_of_seat(seat: int) -> String:
	if session == null:
		return ""
	if role == "host":
		var roster: Dictionary = session.get("roster")
		for k in roster:
			if int(roster[k]["seat"]) == seat:
				return str(roster[k]["id"])
	else:
		var seats: Dictionary = session.get("seats")
		if seats.has(seat):
			return str(seats[seat]["id"])
	return ""


# Игра хоста прожила дни (ход, перемотка, реальное время) - шаг сессии: гости получают изменения.
func _on_world_stepped(_game_obj: Variant, _from_day: int, days: int) -> void:
	if role == "host" and session != null and str(session.get("phase")) == "playing":
		session.call("record_step", days, 0)


func room_code() -> String:
	return code() if role == "host" else ""


# ------------------------------------------------------------------ гость

func guest_join(target: String, display_name_: String) -> String:
	var ad: Object = GameAdapter.new()
	ad.set("service", self)
	return join(target, display_name_, ad, {"mods": ""})


func guest_slot() -> String:
	var c: String = code()
	return "сеть_" + (c if c != "" else "прямая")


# ------------------------------------------------------------------ общее

func leave() -> void:
	var p: Node = _pax()
	if p != null and p.has_signal("world_stepped") and p.is_connected("world_stepped", _on_world_stepped):
		p.disconnect("world_stepped", _on_world_stepped)
	super.leave()


# Сообщение протокола игры/мода: доходит ровно раз, даже через обрыв (AppChannel).
func app_send(to: int, type: String, data: Variant) -> bool:
	return send(to, type, data)


func _process(d: float) -> void:
	super._process(d)
	var now: int = Time.get_ticks_msec()
	if _reload_pending and now - _last_reload_ms >= RELOAD_GAP_MS and adapter != null:
		_reload_pending = false
		_last_reload_ms = now
		adapter.call("flush_reload", guest_slot())


func reload_world_later() -> void:
	_reload_pending = true


func _emit_state() -> void:
	lobby_changed.emit()
	state_changed.emit(state())


func state() -> Dictionary:
	var st: Dictionary = super.state()
	st["progress"] = [progress_what, progress_ratio]
	return st


func _on_message(from_id: int, type: String, data: Variant) -> void:
	if type == MSG_DEAL and role == "guest" and from_id == HOST_ID and data is Dictionary:
		var d: Dictionary = data
		_deal_here(str(d.get("kind", "")), str(d.get("other", "")), d.get("terms", {}) if d.get("terms") is Dictionary else {}, bool(d.get("giver", false)))
		return
	if type == MSG_DEBIT and role == "guest" and from_id == HOST_ID and data is Dictionary:
		_on_debit_request(data)
		return
	if type == MSG_PAID and role == "host" and data is Dictionary:
		_on_debit_paid(from_id, data)
		return
	app_message.emit(from_id, type, data)


# ------------------------------------------------------------------ вызовы GameAdapter

func progress(what: String, r: float) -> void:
	progress_what = what
	progress_ratio = r
	if what == "" or r >= 1.0:
		progress_what = ""
	state_changed.emit(state())


func time_changed(_st: Dictionary) -> void:
	_changed()


func roster_changed(_players: Array) -> void:
	_changed()


func chat_line(from_id: int, name_: String, text: String) -> void:
	app_message.emit(from_id, MSG_CHAT, {"name": name_, "text": text})


# Новость шага: раз и с номером (повтор с тем же номером не печатается).
func show_news(e: Dictionary) -> void:
	var id: int = int(e.get("id", 0))
	if news_seen.has(id):
		return
	news_seen[id] = true
	var g: Object = _game()
	if g != null and str(e.get("text", "")) != "":
		g.call("toast", str(e["text"]))


# Дело между игроками исполнено (почта ядра у всех одинакова). Каждая сторона меняет свою страну
# у себя: хост - сразу, гостю - сообщением (ровно раз).
func apply_deal(kind: String, from_country: String, to_country: String, terms: Dictionary) -> Dictionary:
	var g: Object = _game()
	if g == null:
		return {"ok": false}
	var me: String = str(g.call("country"))
	if kind == "trade":
		var amt: float = Mailbox.deal_amount(terms)
		if amt < 0.0:
			return {"ok": false, "code": "illegal"}
		return _trade(g, me, from_country, to_country, amt) if amt > 0.0 else {"ok": true}
	for side in [[from_country, to_country], [to_country, from_country]]:
		var who: String = str(side[0])
		var other: String = str(side[1])
		if who == me:
			_deal_here(kind, other, terms, who == from_country)
		elif role == "host":
			var seat: int = int(adapter.call("seat_of_country", who))
			var pid: String = player_of_seat(seat)
			if pid != "" and int(pid) != HOST_ID:
				send(int(pid), MSG_DEAL, {"kind": kind, "other": other, "terms": terms, "giver": who == from_country})
	return {"ok": true}


# Торговля: сначала списывает отдающий, потом получает получатель.
func _trade(g: Object, me: String, from_country: String, to_country: String, amt: float) -> Dictionary:
	if from_country == me:
		if not _treasury_ok(g, amt):
			return {"ok": false, "code": "illegal"}
		g.call("add_money", -amt)
		_credit(g, me, to_country, from_country, amt)
		return {"ok": true}
	if role != "host":
		return {"ok": false}
	var pid: String = player_of_seat(int(adapter.call("seat_of_country", from_country)))
	if pid == "" or int(pid) == HOST_ID:
		return {"ok": false, "code": "illegal"}
	if _debits.size() >= MAX_PENDING_DEBITS:
		_debits.erase(_debits.keys()[0])
	_debit_seq += 1
	_debits[_debit_seq] = {"pid": int(pid), "to": to_country, "from": from_country, "amt": amt}
	send(int(pid), MSG_DEBIT, {"id": _debit_seq, "amount": amt})
	return {"ok": true}


# Получатель получает деньги: хост сразу, гость - сообщением.
func _credit(g: Object, me: String, to_country: String, from_country: String, amt: float) -> void:
	if to_country == me:
		g.call("add_money", amt)
	elif role == "host":
		var pid: String = player_of_seat(int(adapter.call("seat_of_country", to_country)))
		if pid != "" and int(pid) != HOST_ID:
			send(int(pid), MSG_DEAL, {"kind": "trade", "other": from_country, "terms": {"amount": amt}, "giver": false})


# Гость: хост просит списать сумму сделки.
func _on_debit_request(d: Dictionary) -> void:
	var g: Object = _game()
	if g == null:
		return
	var amt: float = Mailbox.deal_amount({"amount": d.get("amount", -1.0)})
	var ok: bool = amt > 0.0 and _treasury_ok(g, amt)
	if ok:
		g.call("add_money", -amt)
	send(HOST_ID, MSG_PAID, {"id": int(d.get("id", -1)), "ok": ok})


# Хост: отдающий подтвердил списание (подтверждение принимается один раз и только от него).
func _on_debit_paid(from_id: int, d: Dictionary) -> void:
	var id: int = int(d.get("id", -1))
	var p: Dictionary = _debits.get(id, {})
	if p.is_empty() or int(p["pid"]) != from_id:
		return
	_debits.erase(id)
	var g: Object = _game()
	if g != null and bool(d.get("ok", false)):
		_credit(g, str(g.call("country")), str(p["to"]), str(p["from"]), float(p["amt"]))


func _treasury_ok(g: Object, amount: float) -> bool:
	return amount >= 0.0 and (not g.has_method("money") or float(g.call("money")) >= amount)


# Хватает ли казны у страны. Чужую казну хост не видит: проверяет только свою страну, остальное - отдающий у себя.
func can_afford(country_name: String, amount: float) -> bool:
	var g: Object = _game()
	if g == null or amount < 0.0:
		return false
	if country_name != str(g.call("country")) or not g.has_method("money"):
		return true
	return float(g.call("money")) >= amount


func _deal_here(kind: String, other: String, terms: Dictionary, giver: bool) -> void:
	var g: Object = _game()
	if g == null or other == "":
		return
	match kind:
		"war":
			if not bool(g.call("at_war", other)):
				g.call("declare_war", other)
		"peace", "alliance":
			g.call("change_relation", other, 0.3 if kind == "alliance" else 0.15)
		"trade":
			# сюда приходит только зачисление получателю; списание идёт отдельным шагом (MSG_DEBIT)
			var amt: float = Mailbox.deal_amount(terms)
			if amt > 0.0 and not giver:
				g.call("add_money", amt)
