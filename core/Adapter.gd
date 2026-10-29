extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# КОНТРАКТ МИРА. Сессия (HostSession/GuestSession) ничего не знает об игре: всё, что касается мира,
# она делает через этот объект. Для игры его реализует game/GameAdapter.gd, для тестов — ToyWorld.
#
# Главное требование: ОДИНАКОВЫЕ ВХОДЫ → ОДИНАКОВЫЙ МИР. Шаг мира у всех получает одно и то же
# (приказы в одном порядке, число дней, зерно случайностей). Если игра где-то недетерминирована,
# сверка по суммам это находит, а хост лечит нужные разделы.

# --- мир как набор разделов -----------------------------------------------------------------

# Имена разделов мира, которые сверяются и лечатся по отдельности.
func section_names() -> Array:
	return []


# Раз в сколько шагов проверять раздел (тяжёлые — реже). По умолчанию каждый шаг.
func section_period(_name: String) -> int:
	return 1


# Суммы разделов, которые положено проверить на этом шаге (all — все). name → число.
func hashes(_tick: int, _all: bool = false) -> Dictionary:
	return {}


# Содержимое разделов целиком: name → простые данные (числа, строки, массивы, словари).
func section_data(_names: Array) -> Dictionary:
	return {}


# Вписать присланные разделы в живой мир (лечение). Без перезагрузки сцены, без мигания.
func apply_sections(_data: Dictionary) -> void:
	pass


# Целый мир одним куском (вход в партию, возврат, большое расхождение).
func world_snapshot() -> PackedByteArray:
	return PackedByteArray()


func install_world(_bytes: PackedByteArray) -> bool:
	return false


# --- виды мира (режим власти хоста) -------------------------------------------------------
# В игре мир «повёрнут» к своей стране (Seats.rotate_m): у каждого гостя свой вид. view_of(seat)
# даёт ключ вида; разделы и суммы для гостя считаются в его виде. По умолчанию вид один на всех.

func view_of(_seat: int):
	return ""


func hashes_view(_view, tick: int, all: bool = false) -> Dictionary:
	return hashes(tick, all)


func section_data_view(_view, names: Array) -> Dictionary:
	return section_data(names)


# Целый мир в виде гостя (вход в партию). Обязан совпадать с section_data_view по всем разделам:
# от него хост строит разницы дальше.
func world_snapshot_view(_view) -> PackedByteArray:
	return world_snapshot()


# Вызывается хостом один раз перед расчётом видов на шаге (кэш снимка мира и т.п.).
func begin_views(_tick: int) -> void:
	pass


# --- ход игры --------------------------------------------------------------------------------

func current_day() -> int:
	return 0


# Продвинуть мир на days дней. Случайность — только из SharedRng.at(world_seed, tick, поток).
func advance(_days: int, _tick: int, _world_seed: int) -> void:
	pass


# Кто может отдавать такой приказ: "own" — владелец страны/соправитель; "free" — любой игрок;
# "host" — только хост.
func action_policy(_kind: String) -> String:
	return "own"


# Исполнить приказ. actor: {id, seat, role}. Возврат: {ok, code, text}. Вызывается у ВСЕХ.
func execute_action(_actor: Dictionary, _action: Dictionary, _ctx: Dictionary) -> Dictionary:
	return {"ok": false, "code": "illegal", "text": ""}


# Системное событие шага: {k: "ai", seat, on} — страну ведёт ИИ / вернулся игрок; {k: "seat", ...}.
func apply_event(_ev: Dictionary) -> void:
	pass


# Дело между игроками дошло до исполнения (согласие получено).
func apply_deal(_kind: String, _from_seat: int, _to_seat: int, _terms: Dictionary) -> Dictionary:
	return {"ok": true}


# Страна ведёт ИИ и ей пришло предложение: детерминированный ответ.
func auto_reply(_kind: String, _from_seat: int, _to_seat: int, _terms: Dictionary) -> bool:
	return false


# Страны, которые можно взять в партии: [{id, name}]
func countries() -> Array:
	return []


# --- вывод игроку (только отображение, на мир не влияет) ------------------------------------

func on_news(_entry: Dictionary) -> void:
	pass


func on_ai_result(_entry: Dictionary) -> void:
	pass


func on_action_result(_actor: Dictionary, _action: Dictionary, _result: Dictionary) -> void:
	pass


func on_chat(_from_id: int, _name: String, _text: String) -> void:
	pass


# Понятное сообщение: code из Proto.HUMAN, args — подробности.
func on_notice(_code: String, _args: Dictionary) -> void:
	pass


func on_roster_changed(_players: Array) -> void:
	pass


# Ход передачи мира: 0..1, what — "world" | "patch".
func on_progress(_what: String, _ratio: float) -> void:
	pass


func on_time_state(_state: Dictionary) -> void:
	pass
