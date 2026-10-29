extends "res://mods/paxnet/core/Adapter.gd"
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# МИР PAX UNIVERSE ДЛЯ СЕТЕВОГО ЯДРА. Работает в режиме «мир считает хост» (authority) с внешним
# временем: ход/перемотку/реальное время двигает сама игра хоста (с итогом нейросети — повторить
# его у гостей нельзя), ядро фиксирует прожитое и рассылает гостям изменившиеся разделы мира в их
# виде (мир повёрнут к стране гостя — Seats.rotate_m, как в сетевой игре самой игры).
#
# Разделы — ключи записи мира сейва (WorldKeys.gd). Лечение — живое, по ключу, без перезагрузки
# сцены; то, что живьём не ставится, — перезагрузкой мира (редко, NetService).

const WorldKeys = preload("res://mods/paxnet/game/WorldKeys.gd")
const StateHash = preload("res://mods/paxnet/core/StateHash.gd")
const SeatsScript = preload("res://src/net/Seats.gd")
const SaveScript = preload("res://src/save/Save.gd")

var service                       # NetService
var _world := {}                  # запись мира хоста на шаге _world_tick (кэш на шаг)
var _world_tick := -1
var _views := {}                  # вид → повёрнутая запись (кэш на шаг)
var _seat_names: Array = []       # номер места → имя страны (порядок постоянен в партии)
var _reload_needed := {}          # раздел → данные, которые живьём не ставятся


func _pax():
	return Engine.get_main_loop().root.get_node_or_null("/root/Pax")


func _main() -> Node:
	var p = _pax()
	return p.game.main if p != null and p.game != null else null


# ------------------------------------------------------------------ страны и места

func countries() -> Array:
	if _seat_names.is_empty():
		var p = _pax()
		if p != null and p.game != null:
			var names: Array = []
			for f in p.game.factions():
				if f is Dictionary and str(f.get("name", "")) != "":
					names.append(str(f["name"]))
			names.sort()
			_seat_names = names
	var out: Array = []
	for i in _seat_names.size():
		out.append({"id": i, "name": _seat_names[i]})
	return out


func seat_of_country(name: String) -> int:
	countries()
	return _seat_names.find(name)


func country_of_seat(seat: int) -> String:
	countries()
	return str(_seat_names[seat]) if seat >= 0 and seat < _seat_names.size() else ""


# Вид мира: место гостя → [владелец-id, страна]. Вид хоста — его собственный мир (без поворота).
func view_of(seat: int):
	if service == null or seat < 0 or seat == service.host_seat():
		return ""
	return "%d" % seat


# ------------------------------------------------------------------ запись мира

func begin_views(tick: int) -> void:
	_world_tick = -1
	_views.clear()
	_world_for(tick)


func _world_for(tick: int) -> Dictionary:
	if _world_tick != tick or _world.is_empty():
		var m := _main()
		if m == null:
			return {}
		_world = m.save_game().collect_world()
		_world["owners"] = WorldKeys.owners_now()
		_world_tick = tick
		_views.clear()
	return _world


func _view_world(view, tick: int) -> Dictionary:
	var w := _world_for(tick)
	if str(view) == "":
		return w
	if not _views.has(view):
		var seat := int(view)
		var owner := str(service.player_of_seat(seat))
		var turned: Dictionary = SeatsScript.rotate_m(w.duplicate(true), owner, country_of_seat(seat))
		turned["owners"] = w["owners"]
		_views[view] = turned
	return _views[view]


func section_names() -> Array:
	var m := _main()
	if m == null:
		return []
	return WorldKeys.section_names(_world_for(max(_world_tick, 0)))


func section_period(name: String) -> int:
	return int(WorldKeys.HEAVY.get(name, 1))


func _hashes_of(w: Dictionary, tick: int, all: bool) -> Dictionary:
	var h := {}
	for n in WorldKeys.section_names(w):
		if all or tick % section_period(n) == 0:
			h[n] = StateHash.short(w.get(n))
	return h


func hashes(tick: int, all: bool = false) -> Dictionary:
	# Гость: его собственный мир (уже в его виде). Хост: свой.
	_world_tick = -1
	return _hashes_of(_world_for(tick), tick, all)


func hashes_view(view, tick: int, all: bool = false) -> Dictionary:
	return _hashes_of(_view_world(view, tick), tick, all)


func section_data(names: Array) -> Dictionary:
	return section_data_view("", names)


func section_data_view(view, names: Array) -> Dictionary:
	var w := _view_world(view, max(_world_tick, 0))
	var out := {}
	for n in names:
		if w.has(n):
			out[n] = w[n]
	return out


func current_day() -> int:
	var p = _pax()
	return int(p.game.day()) if p != null and p.game != null else 0


# ------------------------------------------------------------------ лечение и вход

func apply_sections(data: Dictionary) -> void:
	var m := _main()
	if m == null:
		return
	var touched_map := false
	for n in data:
		if WorldKeys.apply_live(m, str(n), data[n]):
			touched_map = touched_map or n == "owners" or n == "armies"
		else:
			_reload_needed[n] = data[n]
	_world_tick = -1
	if touched_map:
		m.show_queue().map_changed()
	m.show_queue().mark("header")
	if not _reload_needed.is_empty() and service != null:
		service.reload_world_later()


# Записать накопленное «только перезагрузкой» в мир гостя и перезагрузить его (зовёт NetService).
func flush_reload(slot: String) -> bool:
	var m := _main()
	if m == null:
		return false
	var w: Dictionary = m.save_game().collect_world()
	w.merge(_reload_needed, true)
	_reload_needed.clear()
	return _write_and_open(slot, w)


func world_snapshot() -> PackedByteArray:
	return world_snapshot_view("")


func world_snapshot_view(view) -> PackedByteArray:
	var w := _view_world(view, max(_world_tick, 0)).duplicate(true)
	w.erase("owners")
	return JSON.stringify(w).to_utf8_buffer()


# Гость получил мир хоста (в своём виде): в свой сетевой слот и открыть — как «Загрузить».
func install_world(bytes: PackedByteArray) -> bool:
	var w = JSON.parse_string(bytes.get_string_from_utf8())
	if not (w is Dictionary):
		return false
	return _write_and_open(service.guest_slot(), w)


func _write_and_open(slot: String, w: Dictionary) -> bool:
	SaveScript.save_it(slot, w)        # папку слота save_it создаёт сам
	SaveScript.wait(slot)
	var m := _main()
	if m == null:
		return false
	_world_tick = -1
	m.mp_session().open_slot(slot)
	return true


# ------------------------------------------------------------------ ход, приказы, вывод

# Время двигает игра хоста (external_time): ядро зовёт advance только у гостя в режиме
# пересчёта, которого у игры нет.
func advance(_days: int, _tick: int, _world_seed: int) -> void:
	pass


func action_policy(kind: String) -> String:
	return "host" if kind == "game.cmd" else "own"


# Приказы игры идут её собственным путём (канал игры, ровно один раз — AppChannel); через шаг
# ядра — только дела между игроками (почта ядра).
func execute_action(_actor: Dictionary, _action: Dictionary, _ctx: Dictionary) -> Dictionary:
	return {"ok": false, "code": "illegal"}


func apply_deal(kind: String, from_seat: int, to_seat: int, terms: Dictionary) -> Dictionary:
	if service != null:
		return service.apply_deal(kind, country_of_seat(from_seat), country_of_seat(to_seat), terms)
	return {"ok": false}


func can_afford(seat: int, amount: float) -> bool:
	return service == null or service.can_afford(country_of_seat(seat), amount)


func on_news(e: Dictionary) -> void:
	if service != null:
		service.show_news(e)


func on_notice(code: String, args: Dictionary) -> void:
	if service != null:
		service.notice(code, args)


func on_progress(what: String, r: float) -> void:
	if service != null:
		service.progress(what, r)


func on_time_state(st: Dictionary) -> void:
	if service != null:
		service.time_changed(st)


func on_roster_changed(players: Array) -> void:
	if service != null:
		service.roster_changed(players)


func on_chat(from_id: int, name: String, text: String) -> void:
	if service != null:
		service.chat_line(from_id, name, text)
