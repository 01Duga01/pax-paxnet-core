extends PaxMod
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# PaxNet - мод-библиотека сетевой игры для других модов: комнаты на ретрансляторе игры по коду и
# приглашению, лобби, время, сообщения ровно один раз через обрывы, переподключение, сверка мира по
# суммам и тихое лечение по разделам. Сам по себе игру не меняет: партию открывает мод, которому она
# нужна (mod.json: "depends": ["paxnet"]). Устройство и API - README.md.

const PaxNetLib = preload("res://mods/paxnet/net/PaxNetLib.gd")

var lib: Node = null


func _mod_loaded() -> void:
	var root: Window = Pax.get_tree().root
	# F6 перезагружает код мода: старый узел библиотеки (и его партии) уходит
	var old: Variant = root.get_meta(PaxNetLib.META, null)
	if old is Node and is_instance_valid(old):
		(old as Node).queue_free()
	lib = PaxNetLib.new()
	lib.name = PaxNetLib.NODE_NAME
	lib.set("mod", self)
	root.set_meta(PaxNetLib.META, lib)
	root.add_child.call_deferred(lib)
	# газета гостя и приглашение в Discord - только когда идёт партия в мире игры (world_service)
	hook("report_ready", Callable(self, "_on_report"))
	hook("discord_presence", Callable(self, "_on_discord"))
	Pax.register_command("paxnet", Callable(self, "_cmd"), "paxnet [state | host name | join code name | start | leave]")


func _world_ready(game: PaxGame) -> void:
	var svc: Node = _world()
	if svc != null:
		attach_overlay(svc, game)


## Окно состояния партии мира на HUD игры (один раз).
func attach_overlay(svc: Node, game: Object = null) -> void:
	var g: Object = game if game != null else (Pax.get("game") as Object)
	if g == null or not g.has_method("hud_layer"):
		return
	var hud: Variant = g.call("hud_layer")
	if not (hud is Node) or (hud as Node).get_node_or_null("PaxNetOverlay") != null:
		return
	var o: CanvasLayer = lib.call("overlay", svc, hud)
	o.name = "PaxNetOverlay"


func _world() -> Node:
	if lib == null or not is_instance_valid(lib):
		return null
	return lib.call("world_service_if_any")


# Газета хода у гостя: только то, что хост уже напечатал (без повторов и несбывшегося).
func _on_report(d: Dictionary) -> void:
	var svc: Node = _world()
	if svc == null or not bool(svc.call("is_guest")):
		return
	var rep: Variant = d.get("report")
	if rep is Dictionary and (rep as Dictionary).has("newspaper"):
		var seen_all: Dictionary = svc.get("news_seen")
		var seen: Dictionary = {}
		var clean: Array = []
		for item in (rep as Dictionary)["newspaper"]:
			var key: String = "n%d" % hash(item)
			if not seen.has(key) and not seen_all.has(key):
				seen[key] = true
				seen_all[key] = true
				clean.append(item)
		(rep as Dictionary)["newspaper"] = clean


# Приглашение в Discord: кнопка «Войти» ведёт по коду комнаты.
func _on_discord(d: Dictionary) -> void:
	var svc: Node = _world()
	if svc == null or not bool(svc.call("is_host")) or str(svc.call("room_code")) == "":
		return
	var act: Variant = d.get("activity")
	if act is Dictionary:
		(act as Dictionary)["buttons"] = [{"label": tr_key("paxnet_join_button"), "url": str(svc.call("invite_link"))}]


# Сохранение у хоста: кто за какой страной, номера приказов, код комнаты - продолжение с теми же игроками.
func _save_state(_game: PaxGame) -> Dictionary:
	var svc: Node = _world()
	if svc == null or not bool(svc.call("is_host")) or svc.get("session") == null:
		return {}
	var session: Object = svc.get("session")
	var st: Dictionary = session.call("save_state")
	st["code"] = str(svc.call("room_code"))
	return {"session": st}


func _game_loaded(_game: PaxGame, state: Dictionary) -> void:
	if state.get("session") is Dictionary and lib != null:
		lib.set("world_resume", state["session"])
		var svc: Node = _world()
		if svc != null:
			svc.set("resume_state", state["session"])


# Консоль разработчика (F8): партия в мире игры для проверки.
func _cmd(args0: Variant = []) -> String:
	var args: Array = []
	if args0 is String:
		args = Array((args0 as String).split(" ", false))
	elif args0 is Array:
		args = args0
	var svc: Node = lib.call("world_service") if lib != null else null
	if svc == null:
		return "paxnet: world service unavailable"
	if args.is_empty() or str(args[0]) == "state":
		return JSON.stringify(svc.call("state"))
	match str(args[0]):
		"host":
			var e: String = str(svc.call("host_open", str(args[1]) if args.size() > 1 else tr_key("paxnet_default_name")))
			return e if e != "" else "ok"
		"join":
			var e2: String = str(svc.call("guest_join", str(args[1]) if args.size() > 1 else "", str(args[2]) if args.size() > 2 else tr_key("paxnet_default_name")))
			return e2 if e2 != "" else "ok"
		"start":
			return JSON.stringify(svc.call("host_start"))
		"leave":
			svc.call("leave")
			return "ok"
	return "paxnet [state | host name | join code name | start | leave]"
