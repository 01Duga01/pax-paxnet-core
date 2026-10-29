extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
## Канал через ретранслятор игры. Network.relay_pipe(first) открывает wss до
## mp.paxuniverse.ru (порт 443, через прокси и VPN) и подписывает соединение лицензией игрока - моду
## сокеты не нужны. Получаем готовый канал датаграмм: хост = 1, гости = 2.., 0 - всем гостям.
## Доставка по нему надёжная и по порядку, поэтому повторов и подтверждений поверх нет.
##
## first: хост - {"op": "host", "name", "public", "max", "ai", "preset", "host_name", "code"},
##        гость - {"op": "join", "code"}.
## Сигналы канала: lobby_ready(code, rules), refused(why), peer_connected(id), peer_disconnected(id).


## Что нашлось при последнем открытии канала - показывается в лобби, если канала нет.
static var last_detail: String = ""


## Объект сети игры, у которого есть relay_pipe(), иначе null. Порядок: имя Network (как в
## чейнджлоге 0.32.4), Pax.net / Pax.service("network"), известные пути, затем любой узел в /root
## и /root/Pax, у которого есть relay_pipe().
static func game_network(from: Node) -> Object:
	var cands: Array = []
	var direct: Variant = _direct_target()
	if direct is Object:
		cands.append(direct)
	var pax: Node = from.get_node_or_null("/root/Pax")
	if pax != null:
		var n0: Variant = pax.get("net")
		if n0 is Object:
			cands.append(n0)
		for m in ["service", "get_service"]:
			if pax.has_method(m):
				var n1: Variant = pax.call(m, "network")
				if n1 is Object:
					cands.append(n1)
	for path in ["/root/Network", "/root/PaxNetwork", "/root/Pax/Network"]:
		var n2: Node = from.get_node_or_null(path)
		if n2 != null:
			cands.append(n2)
	var root: Node = from.get_tree().root if from.is_inside_tree() else null
	if root != null:
		cands.append_array(root.get_children())
	if pax != null:
		cands.append_array(pax.get_children())
	for c in cands:
		if is_instance_valid(c) and c is Object and (c as Object).has_method("relay_pipe"):
			return c
	return null


## Скрипт с прямым вызовом Network.relay_pipe() - или null, если в игре нет имени Network.
static func _direct_script() -> Script:
	# путь литералом: песочница игры пускает load() только с "res://mods/<id>/…"
	var s: Variant = load("res://mods/paxnet_core/transport/GameRelay.gd")
	if s is Script and (s as Script).can_instantiate():
		return s as Script
	return null


static func _direct_target() -> Variant:
	var s: Script = _direct_script()
	return s.call("target") if s != null else null


## Открыть канал. factory (тесты, свой путь) - Callable(first) -> Object; иначе relay_pipe игры.
static func open(from: Node, first: Dictionary, factory: Callable) -> Object:
	if factory.is_valid():
		var p0: Variant = factory.call(first)
		return _settle(p0)
	var gn: Object = game_network(from)
	var p: Variant = null
	if gn != null:
		keep_awake(from, true)
		p = gn.call("relay_pipe", first)
		var opened: Object = _settle(p)
		if opened != null:
			_awake_pipes[opened.get_instance_id()] = true
		elif _awake_pipes.is_empty():
			keep_awake(from, false)
		if opened == null:
			last_detail = "relay_pipe() → %s" % [type_string(typeof(p)) if not (p is Object) else (p as Object).get_class()]
			print("[paxnet] relay_pipe returned no pipe: ", last_detail)
		else:
			last_detail = ""
		return opened
	else:
		# Network - глобальный класс со static relay_pipe(): has_method() его не видит, зовём напрямую
		var s: Script = _direct_script()
		if s == null:
			last_detail = _describe(from)
			print("[paxnet] relay_pipe not found: ", last_detail)
			return null
		p = s.call("open", first)
	var res: Object = _settle(p)
	if res == null:
		last_detail = "relay_pipe() → %s" % [type_string(typeof(p)) if not (p is Object) else (p as Object).get_class()]
		print("[paxnet] relay_pipe returned no pipe: ", last_detail)
	else:
		last_detail = ""
	return res


## Короткая сводка для лобби: есть ли имя Network и какие узлы есть в /root.
static func _describe(from: Node) -> String:
	var parts: Array = []
	parts.append("Network: " + ("yes" if _direct_script() != null else "no"))
	if from.is_inside_tree():
		var names: Array = []
		for ch in from.get_tree().root.get_children():
			names.append(str((ch as Node).name))
		parts.append("/root: " + ", ".join(PackedStringArray(names)).left(160))
	return "; ".join(PackedStringArray(parts))


## relay_pipe() может сначала подождать (подпись соединения, wss) и вернуть канал позже - тогда
## call() отдаёт не канал, а «обещание» с сигналом completed. Такое оборачиваем в Pending: он
## ведёт себя как канал (пакетов нет, сигналы те же) и подменяется настоящим, когда тот готов.
static func _settle(p: Variant) -> Object:
	if not (p is Object):
		return null
	var o: Object = p
	if is_pipe(o):
		return o
	if o.has_signal("completed"):
		return Pending.new(o)
	return null


static func is_pipe(o: Object) -> bool:
	return o != null and o.has_method("put_packet") and o.has_method("get_packet")


## Открытые каналы игры (id объекта → true): пока они есть, узел сети игры не спит на паузе.
static var _awake_pipes: Dictionary = {}
static var _awake_node: WeakRef = null


## Мод может ставить игру на паузу, пока открыто его окно, а лобби живёт как раз в этом окне. Узел
## сети игры на паузе не обрабатывается: wss не соединяется, комната не создаётся. На время сеанса
## переводим его в PROCESS_MODE_ALWAYS и возвращаем прежний режим, когда каналов больше нет.
static func keep_awake(from: Node, on: bool) -> void:
	var n: Node = null
	if from != null and from.is_inside_tree():
		var gn: Object = game_network(from)
		if gn is Node:
			n = gn as Node
	if n == null and _awake_node != null:
		var w: Variant = _awake_node.get_ref()
		if w is Node:
			n = w as Node
	if n == null:
		return
	if on:
		_awake_node = weakref(n)
		if not n.has_meta("paxnet_mode"):
			n.set_meta("paxnet_mode", int(n.process_mode))
		n.process_mode = Node.PROCESS_MODE_ALWAYS
	elif n.has_meta("paxnet_mode"):
		n.process_mode = int(n.get_meta("paxnet_mode")) as Node.ProcessMode
		n.remove_meta("paxnet_mode")


## Канал, которого ещё нет: ждёт completed от relay_pipe() и дальше передаёт всё настоящему.
class Pending extends RefCounted:
	signal lobby_ready(code: Variant, rules: Variant)
	signal refused(why: Variant)
	signal peer_connected(id: Variant)
	signal peer_disconnected(id: Variant)

	var real: Object = null
	var closed: bool = false
	## «Обещание» держим сами: без ссылки оно освобождается и completed не придёт никогда.
	var _state: Object = null
	var _target: int = 0
	var _queue: Array = []

	func _init(state: Object) -> void:
		_state = state
		state.connect("completed", _on_done)

	func _on_done(res: Variant = null) -> void:
		_state = null
		if closed:
			if res is Object and (res as Object).has_method("close"):
				(res as Object).call("close")
			return
		if not (res is Object) or not _pipe_like(res as Object):
			refused.emit("relay_pipe unavailable")
			return
		real = res as Object
		for sg in ["lobby_ready", "refused", "peer_connected", "peer_disconnected"]:
			if real.has_signal(sg):
				real.connect(sg, Callable(self, "_fwd_" + sg))
		for q in _queue:
			var item: Array = q
			real.call("set_target_peer", int(item[0]))
			real.call("put_packet", item[1])
		_queue.clear()

	static func _pipe_like(o: Object) -> bool:
		return o.has_method("put_packet") and o.has_method("get_packet")

	func _fwd_lobby_ready(c: Variant = null, r: Variant = null) -> void:
		lobby_ready.emit(c, r)

	func _fwd_refused(w: Variant = null) -> void:
		refused.emit(w)

	func _fwd_peer_connected(id: Variant = 0) -> void:
		peer_connected.emit(id)

	func _fwd_peer_disconnected(id: Variant = 0) -> void:
		peer_disconnected.emit(id)

	func poll() -> void:
		if real != null and real.has_method("poll"):
			real.call("poll")

	func set_target_peer(to: int) -> void:
		_target = to
		if real != null:
			real.call("set_target_peer", to)

	func put_packet(b: PackedByteArray) -> int:
		if real != null:
			return int(real.call("put_packet", b))
		_queue.append([_target, b])
		return OK

	func get_available_packet_count() -> int:
		return int(real.call("get_available_packet_count")) if real != null else 0

	func get_packet_peer() -> int:
		return int(real.call("get_packet_peer")) if real != null else 0

	func get_packet() -> PackedByteArray:
		if real == null:
			return PackedByteArray()
		var raw: Variant = real.call("get_packet")
		return raw if raw is PackedByteArray else PackedByteArray()

	func close() -> void:
		closed = true
		_queue.clear()
		if real != null and real.has_method("close"):
			real.call("close")
		real = null


## Подключить сигналы канала к обработчикам prefix + имя_сигнала.
static func wire(p: Object, target: Object, prefix: String) -> void:
	for sg in ["lobby_ready", "refused", "peer_connected", "peer_disconnected"]:
		if p.has_signal(sg) and target.has_method(prefix + sg):
			p.connect(sg, Callable(target, prefix + sg))
	# канал-узел самого мода тоже должен работать на паузе
	if p is Node:
		(p as Node).process_mode = Node.PROCESS_MODE_ALWAYS


static func poll(p: Object) -> void:
	if p != null and p.has_method("poll"):
		p.call("poll")


static func send(p: Object, to: int, bytes: PackedByteArray) -> void:
	if p == null:
		return
	p.call("set_target_peer", to)
	p.call("put_packet", bytes)


## Следующий пакет: [от кого, байты] или [] - пакетов нет.
static func recv(p: Object) -> Array:
	if p == null or int(p.call("get_available_packet_count")) <= 0:
		return []
	var from: int = int(p.call("get_packet_peer"))
	var raw: Variant = p.call("get_packet")
	if not (raw is PackedByteArray):
		return [from, PackedByteArray()]
	return [from, raw]


static func close(p: Object) -> void:
	if p == null:
		return
	if p.has_method("close"):
		p.call("close")
	if _awake_pipes.erase(p.get_instance_id()) and _awake_pipes.is_empty():
		keep_awake(null, false)
