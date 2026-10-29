extends Node
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ТОЧКА ВХОДА БИБЛИОТЕКИ ДЛЯ ДРУГИХ МОДОВ. Узел /root/PaxNetLib; ещё до входа в дерево он лежит в
# метаданных корня: get_tree().root.get_meta("paxnet_lib"). Мод-потребитель пишет в mod.json
# "depends": ["paxnet_core"] и берёт отсюда всё нужное - свои preload чужих файлов ему не нужны:
#
#   var lib: Node = Pax.get_tree().root.get_meta("paxnet_lib", null)
#   var net: Node = lib.new_session()            # net/Session.gd: host / join / send / message
#   var Bytes: Script = lib.script_of("Bytes")   # любой скрипт ядра по имени

const NODE_NAME: String = "PaxNetLib"
const META: String = "paxnet_lib"

const Proto = preload("res://mods/paxnet_core/core/Proto.gd")
const Bytes = preload("res://mods/paxnet_core/core/Bytes.gd")
const SharedRng = preload("res://mods/paxnet_core/core/SharedRng.gd")
const StateHash = preload("res://mods/paxnet_core/core/StateHash.gd")
const Relay = preload("res://mods/paxnet_core/transport/Relay.gd")
const RelayPipe = preload("res://mods/paxnet_core/transport/RelayPipe.gd")
const Session = preload("res://mods/paxnet_core/net/Session.gd")
const NetOverlay = preload("res://mods/paxnet_core/ui/NetOverlay.gd")

## Скрипты, которые библиотека отдаёт по имени (для наследования и new()).
const SCRIPTS: Dictionary = {
	"Proto": "res://mods/paxnet_core/core/Proto.gd",
	"Bytes": "res://mods/paxnet_core/core/Bytes.gd",
	"SharedRng": "res://mods/paxnet_core/core/SharedRng.gd",
	"StateHash": "res://mods/paxnet_core/core/StateHash.gd",
	"Delta": "res://mods/paxnet_core/core/Delta.gd",
	"Crc32": "res://mods/paxnet_core/core/Crc32.gd",
	"Hmac": "res://mods/paxnet_core/core/Hmac.gd",
	"Adapter": "res://mods/paxnet_core/core/Adapter.gd",
	"BasicAdapter": "res://mods/paxnet_core/net/BasicAdapter.gd",
	"HostSession": "res://mods/paxnet_core/core/HostSession.gd",
	"GuestSession": "res://mods/paxnet_core/core/GuestSession.gd",
	"Mailbox": "res://mods/paxnet_core/core/Mailbox.gd",
	"TimeAuthority": "res://mods/paxnet_core/core/TimeAuthority.gd",
	"Relay": "res://mods/paxnet_core/transport/Relay.gd",
	"RelayPipe": "res://mods/paxnet_core/transport/RelayPipe.gd",
	"PipeHost": "res://mods/paxnet_core/transport/PipeHost.gd",
	"PipeGuest": "res://mods/paxnet_core/transport/PipeGuest.gd",
	"Session": "res://mods/paxnet_core/net/Session.gd",
	"NetOverlay": "res://mods/paxnet_core/ui/NetOverlay.gd",
}

## PaxMod библиотеки: настройки и перевод.
var mod: Object = null
## Фабрика канала для всех новых сессий (тесты): Callable(first: Dictionary) -> Object.
var pipe_factory: Callable = Callable()
## Из сейва хоста (партия в мире игры): те же игроки, страны и код.
var world_resume: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Скрипт библиотеки по имени из SCRIPTS (null - нет такого).
func script_of(name: String) -> Script:
	if not SCRIPTS.has(name):
		return null
	match name:
		"Proto":
			return Proto
		"Bytes":
			return Bytes
		"SharedRng":
			return SharedRng
		"StateHash":
			return StateHash
		"Relay":
			return Relay
		"RelayPipe":
			return RelayPipe
		"Session":
			return Session
		"NetOverlay":
			return NetOverlay
	return _load_named(name)


# Остальные - лениво: литеральные пути (песочница пускает load() только так).
func _load_named(name: String) -> Script:
	var s: Variant = null
	match name:
		"Delta":
			s = load("res://mods/paxnet_core/core/Delta.gd")
		"Crc32":
			s = load("res://mods/paxnet_core/core/Crc32.gd")
		"Hmac":
			s = load("res://mods/paxnet_core/core/Hmac.gd")
		"Adapter":
			s = load("res://mods/paxnet_core/core/Adapter.gd")
		"BasicAdapter":
			s = load("res://mods/paxnet_core/net/BasicAdapter.gd")
		"HostSession":
			s = load("res://mods/paxnet_core/core/HostSession.gd")
		"GuestSession":
			s = load("res://mods/paxnet_core/core/GuestSession.gd")
		"Mailbox":
			s = load("res://mods/paxnet_core/core/Mailbox.gd")
		"TimeAuthority":
			s = load("res://mods/paxnet_core/core/TimeAuthority.gd")
		"PipeHost":
			s = load("res://mods/paxnet_core/transport/PipeHost.gd")
		"PipeGuest":
			s = load("res://mods/paxnet_core/transport/PipeGuest.gd")
	return s as Script if s is Script else null


## {id, version} мода по его mod.json (через безопасный API PaxMod). Пусто, если прочитать не удалось.
static func read_manifest(m: Object) -> Dictionary:
	if m == null or not m.has_method("load_json"):
		return {}
	var d: Variant = m.call("load_json", "mod.json")
	if not (d is Dictionary):
		return {}
	var out: Dictionary = {}
	out["id"] = str((d as Dictionary).get("id", ""))
	out["version"] = str((d as Dictionary).get("version", ""))
	return out


## Версия библиотеки (из её mod.json). Её же сверяют хост и гость при входе.
func version() -> String:
	return Proto.version


## Новая сетевая партия. parent - куда повесить узел (по умолчанию - сюда, под /root/PaxNetLib).
## Ключ игрока общий для всех модов (хранится в настройках библиотеки).
## app - PaxMod вашего мода (передайте self): id и версию библиотека читает из его mod.json сама, и при входе хост и
## гость сверяют их: версия мода у обоих должна совпасть (иначе ошибка app_version).
func new_session(parent: Node = null, app: Object = null) -> Node:
	var s: Node = Session.new()
	s.set("player_key", player_key())
	var man: Dictionary = read_manifest(app)
	if not man.is_empty() and Proto.valid_version(str(man["version"])):
		s.set("app_id", str(man["id"]))
		s.set("app_version", str(man["version"]))
	s.set("pipe_factory", pipe_factory)
	if parent != null:
		parent.add_child(s)
	elif is_inside_tree():
		add_child(s)
	else:
		add_child.call_deferred(s)
	return s


## Партия в мире самой Pax Universe (стратегия): GameAdapter + NetService. Создаётся по требованию;
## null, если внутренности игры, на которые он опирается, недоступны в этой версии.
func world_service() -> Node:
	if not is_inside_tree():
		return null
	var s: Variant = load("res://mods/paxnet_core/game/NetService.gd")
	if not (s is Script) or not (s as Script).can_instantiate():
		push_warning("[paxnet] world service unavailable in this game version")
		return null
	var n: Node = get_tree().root.get_node_or_null("PaxNetWorld")
	if n == null:
		n = (s as Script).new() as Node
		n.name = "PaxNetWorld"
		n.set("mod", mod)
		n.set("pipe_factory", pipe_factory)
		n.set("resume_state", world_resume)
		get_tree().root.add_child(n)
		if mod != null and mod.has_method("attach_overlay"):
			mod.call("attach_overlay", n, null)
	return n


## Служба мира, если её уже создали (не создаёт).
func world_service_if_any() -> Node:
	return get_tree().root.get_node_or_null("PaxNetWorld") if is_inside_tree() else null


## Окно состояния для сессии: строка вверху, полоса передачи, понятная ошибка с кнопкой.
func overlay(session: Node, parent: Node) -> CanvasLayer:
	var o: CanvasLayer = NetOverlay.new()
	o.set("svc", session)
	o.set("mod", mod)
	parent.add_child(o)
	return o


## Постоянный ключ игрока (одинаков для всех модов на этой копии игры).
func player_key() -> String:
	var k: String = str(mod.call("get_setting", "player_key", "")) if mod != null else ""
	if k == "":
		k = Crypto.new().generate_random_bytes(16).hex_encode()
		if mod != null:
			mod.call("set_setting", "player_key", k)
	return k


# ------------------------------------------------------------------ готовые помощники

## Значение → байты (свой кодек: объекты не кодируются, глубина и длины ограничены).
func encode(v: Variant) -> PackedByteArray:
	return Bytes.encode(v)


## Байты → {ok, v}. Мусор от сети не роняет приём: ok = false.
func decode(b: PackedByteArray) -> Dictionary:
	return Bytes.decode(b)


## Случайности, одинаковые у всех игроков: (зерно, шаг, имя потока) → PCG32.
func rng(world_seed: int, tick: int = 0, stream: String = "") -> RefCounted:
	return SharedRng.at(world_seed, tick, stream)


## Хеш значения, не зависящий от порядка ключей словаря (сверка состояний), 32 бита.
func state_hash(v: Variant) -> int:
	return StateHash.short(v)


func parse_code(s: String) -> String:
	return Relay.parse_code(s)


func invite_link(code: String, pin: String = "") -> String:
	return Relay.invite_link(code, pin)


## PIN из приглашения («КОД#PIN» или ссылки).
func parse_pin(s: String) -> String:
	return Relay.parse_pin(s)


## Общий код комнаты по сиду (например, комната дня: lib.shared_code(lib.utc_day(), "my_mod/daily", "MM")).
func shared_code(seed: int, stream: String, prefix: String = "") -> String:
	return Relay.shared_code(seed, stream, prefix)


func utc_day() -> int:
	return Relay.utc_day()


## Голый канал ретранслятора для своего протокола (как в doom_2): first - {"op": "host", …} или
## {"op": "join", "code"}. Методы канала: put_packet, get_packet, get_packet_peer,
## get_available_packet_count, set_target_peer, poll, close; сигналы lobby_ready, refused,
## peer_connected, peer_disconnected. Помощники - script_of("RelayPipe"): wire, send, recv, poll, close.
func open_pipe(first: Dictionary) -> Object:
	return RelayPipe.open(self, first, pipe_factory)


## Что нашлось при последней неудачной попытке открыть канал (для журнала).
func pipe_detail() -> String:
	return RelayPipe.last_detail
