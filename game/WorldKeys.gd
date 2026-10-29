extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# РАЗДЕЛЫ МИРА ИГРЫ ДЛЯ СВЕРКИ И ЛЕЧЕНИЯ. Раздел — ключ верхнего уровня записи мира, той самой, что
# пишет сейв (src/save/SaveGame.gd collect_world). Так раздел значит одно и то же у хоста, у гостя
# и в файле сохранения, а «повёрнутый» к стране гостя мир (Seats.rotate_m) — та же запись.
#
# Живое применение (без перезагрузки сцены, без мигания) повторяет src/save/SaveGame.gd _restore_*
# для отдельного ключа. Ключ без живого применения ставится перезагрузкой мира — редко и с паузой
# между перезагрузками (NetService). Список проверен по SaveGame.gd версии 0.32.3.

const ResourcesScript = preload("res://src/economy/Resources.gd")
const EconomyScript = preload("res://src/economy/Economy.gd")
const FeatureStateScript = preload("res://src/core/FeatureState.gd")
# Поле версии формата ключей в записи мира (src/save/KeyMigration.gd FORMAT_FIELD). Константой:
# песочница модов не пускает preload этого скрипта игры.
const KEY_FORMAT_FIELD := "key_format"

# Своё у каждого игрока: вид, журнал, ассистент, метки на карте, сетевые пометки. Не сверяются.
const PERSONAL := ["mods", "focus", "diary", "name_ai", "assistant_ai", "chosen_contacts", "marks", "connection",
	"comms", "saved", KEY_FORMAT_FIELD, "мп_orders", "rhythm", "feed_talks", "lorebook", "hints_radiation"]

# Своё у страны игрока: в сетевой игре свою страну ведёт сам игрок (приказы, законы, исследования,
# казна, мобилизация), хост видит её державой в своём мире. Эти разделы не «лечатся» от хоста —
# иначе откатывались бы действия гостя; одинаковость для всех держится общими разделами (державы,
# области, армии, войны), куда страна гостя входит.
const OWN := ["orders", "next_id", "laws", "next_law", "rule_power", "research", "next_development", "blueprints",
	"deliveries", "course", "deeds", "next_deed", "war_home", "head_of_it", "overthrows", "patience", "resources",
	"parameters", "developed", "threads", "next_thread", "stage_routes", "successful_orders", "stage_s_day",
	"log_stage", "made_done", "important", "requests", "finds", "our_invented_equipment", "kind_player",
	"ours_faction_data", "capital", "assignments", "next_assignment", "stores", "economy_of", "economics",
	"name_ai", "cruelty", "explored_provinces", "scouted", "successes"]

# Области: в записи мира — весь объект провинций (живого применения нет); владельцы сверяются и
# лечатся отдельным разделом «owners» через стабильный API (set_province_owner).
const VIA_OWNERS := ["provinces", "provinces_bodies"]

# Тяжёлые разделы: сверяются раз в несколько шагов.
const HEAVY := {"world": 4, "factions": 2, "factions_other": 4, "economy_of": 2, "economics": 4, "deposits": 8,
	"history": 4, "flights": 2, "armies": 1, "important": 4}


static func section_names(world: Dictionary) -> Array:
	var out: Array = []
	for k in world:
		var key := str(k)
		if PERSONAL.has(key) or OWN.has(key) or VIA_OWNERS.has(key) or key.begins_with("_"):
			continue
		out.append(key)
	out.append("owners")
	out.sort()
	return out


static func _dup(v):
	return v.duplicate(true) if v is Dictionary or v is Array else v


# Записать раздел в живой мир. false — живого применения нет (нужна перезагрузка мира).
static func apply_live(main: Node, key: String, v) -> bool:
	var model = main.model
	match key:
		"day":
			model.sim.day = int(v)
		"turn":
			model.sim.turn = int(v)
		"resources":
			for k in v:
				model.sim.res[k] = float(v[k])
		"parameters":
			for k in v:
				model.sim.params[k] = float(v[k])
		"developed":
			model.developed = float(v)
		"head_of_it":
			if v is Dictionary:
				model.sim.leader = _dup(v)
		"overthrows":
			model.sim.overthrows = int(v)
		"patience":
			model.sim.patience = int(v)
		"laws":
			model.laws = _dup(v) if v is Array else []
			if main.has_method("hud_refresh"):
				main.hud_refresh().refresh_laws()
		"next_law":
			model.next_law = int(float(v))
		"rule_power":
			main.power.load_it(v if v is Dictionary else {})
		"research":
			model.research_list = _dup(v) if v is Array else []
		"next_development":
			model.next_research = int(v)
		"blueprints":
			model.blueprints = v if v is Array else []
		"deliveries":
			model.supplies = v if v is Array else []
		"course":
			model.course_state = _dup(v) if v is Dictionary else {}
			model._course_cache_day = -1
		"deeds":
			model.deeds = _dup(v) if v is Array else []
		"next_deed":
			model.next_deed = int(v)
		"armies":
			if v is Dictionary and model.armies != null:
				model.armies.from_save(v)
				main.show_queue().map_changed()
		"factions":
			if v is Array and model.factions_sim != null:
				model.factions_sim.load_it(v, main.save_game().collect_world().get("factions_other", {}))
		"factions_other":
			if v is Dictionary and model.factions_sim != null:
				model.factions_sim.load_it(model.factions_sim.save_it(), v)
		"stores":
			if v is Dictionary and model.resources != null:
				for name in v:
					if not model.resources.stock_.has(str(name)):
						model.resources.found(str(name), 0.0)
					var z: Dictionary = model.resources.stock(str(name))
					for k in v[name]:
						var zn = v[name][k]
						z[k] = _dup(zn) if zn is Dictionary else float(zn)
					ResourcesScript.to_new_keys(z, float(z.get("humans", 0.0)))
		"relations":
			if v is Dictionary and model.resources != null:
				for name in v:
					model.resources.relation_[name] = float(v[name])
		"extra_resources":
			if v is Dictionary and model.resources != null:
				model.resources.extra = _dup(v)
		"war_home":
			main.home_war = _dup(v) if v is Dictionary else main.home_war
		"seizures":
			model.captures = _dup(v) if v is Dictionary else {}
		"orders":
			if v is Array:
				model.orders = []
				for x in v:
					if x is Dictionary:
						var o: Dictionary = _dup(x)
						o["id"] = int(float(o.get("id", 0)))
						o["days"] = int(float(o.get("days", 0)))
						o["elapsed"] = int(float(o.get("elapsed", 0)))
						model.orders.append(o)
		"next_id":
			model.next_id = int(float(v))
		"economy_of":
			if v is Dictionary:
				model.economies = _dup(v)
				for t_h in model.economies:
					EconomyScript.reset_cache(model.economies[t_h])
		"economics":
			main.econ.load_save(v if v is Dictionary else {})
		"market":
			if v is Dictionary:
				main.market_state = _dup(v)
		"organizations":
			if v is Array:
				model.organization_list = _dup(v)
		"bases":
			if v is Array:
				model.base_list = _dup(v)
		"next_base":
			model._next_base = int(v)
		"operations":
			if v is Array:
				model.operation_list = _dup(v)
		"next_operation":
			model._next_operation = int(v)
		"flights":
			if v is Dictionary and model.flights != null:
				model.flights.from_save(v)
		"world":
			if v is Dictionary and model.world != null:
				model.world.load_it(v)
		"threats":
			model.threats = _dup(v) if v is Array else []
		"megastructures":
			model.megastructure_list = _dup(v) if v is Array else []
		"terraforming":
			model.terraforming = _dup(v) if v is Array else []
		"lines_supply":
			model.supply_line_list = _dup(v) if v is Array else []
		"built_megaprojects":
			model.built_megaprojects = _dup(v) if v is Array else []
		"infection":
			model.contamination = _dup(v) if v is Dictionary else {}
		"entities":
			model.entity_list = _dup(v) if v is Array else []
		"assignments":
			model.assignment_list = _dup(v) if v is Array else []
		"history":
			model.history = _dup(v) if v is Array else []
		"stations":
			model.stations = _dup(v) if v is Array else []
		"objects":
			model.objects = _dup(v) if v is Array else []
		"life":
			model.life = _dup(v) if v is Dictionary else {}
		"cruelty":
			model.cruelty = float(v)
		"we_nuclear":
			model.we_are_nuclear = bool(v)
		"secrecy":
			model.secrecy = clampf(float(v), 0.0, 1.0)
		"broken_treaties":
			model.broken_treaties = int(v)
		"mines":
			model.mines = _dup(v) if v is Array else []
		"next_mine":
			model.next_mine = int(float(v))
		"important":
			model.important = _dup(v) if v is Dictionary else {}
		"scouted":
			model.scouted = _dup(v) if v is Dictionary else {}
		"successes":
			model.successes = _dup(v) if v is Array else []
		"requests":
			model.requests = _dup(v) if v is Dictionary else {}
		"finds":
			model.finds = _dup(v) if v is Array else []
		"time_machine":
			model.time_machine_state = _dup(v) if v is Dictionary else {}
		"features":
			# личные состояния фич (personal) остаются свои
			var mine: Dictionary = FeatureStateScript.to_save(model.features)
			var merged: Dictionary = _dup(v) if v is Dictionary else {}
			var personal: Array = FeatureStateScript.personal_keys()
			for k in personal:
				if mine.has(k):
					merged[k] = mine[k]
			FeatureStateScript.from_save(model.features, {"features": merged})
		"owners":
			_apply_owners(v)
		_:
			return false
	return true


# Владельцы областей домашнего тела: {id: владелец}. Через стабильный API — карта перерисуется сама.
static func owners_now() -> Dictionary:
	var g = Engine.get_main_loop().root.get_node_or_null("/root/Pax")
	if g == null or g.game == null:
		return {}
	var game = g.game
	var body: String = str(game.home_body())
	var out := {}
	for id in range(1, int(game.province_count(body)) + 1):
		out[id] = str(game.province_owner(body, id))
	return out


static func _apply_owners(v) -> void:
	if not (v is Dictionary):
		return
	var g = Engine.get_main_loop().root.get_node_or_null("/root/Pax")
	if g == null or g.game == null:
		return
	var game = g.game
	var body: String = str(game.home_body())
	for id in v:
		var want := str(v[id])
		if str(game.province_owner(body, int(id))) != want:
			game.set_province_owner(body, int(id), want)
