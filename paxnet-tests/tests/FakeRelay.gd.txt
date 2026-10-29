extends RefCounted
## Виртуальный ретранслятор: комнаты по коду, каналы с задержкой, надёжная доставка по порядку
## (как relay_pipe игры). Можно оборвать канал игрока.

var rooms: Dictionary = {}          # code -> {host: Pipe, peers: {id: Pipe}, next: int}
var latency_ms: int = 40
var codes_made: int = 0
var log_on: bool = false


func factory() -> Callable:
	return func(first: Dictionary) -> Object: return open(first)


func open(first: Dictionary) -> Object:
	var p: Pipe = Pipe.new()
	p.relay = self
	if str(first.get("op", "")) == "host":
		var code: String = str(first.get("code", ""))
		if code == "" or (rooms.has(code) and not (rooms[code]["host"] as Pipe).closed):
			codes_made += 1
			var al: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
			code = "TESTAB" + al[(codes_made / 32) % 32] + al[codes_made % 32]
		p.id = 1
		p.code = code
		var room: Dictionary = rooms.get(code, {"peers": {}, "next": 2})
		room["host"] = p
		rooms[code] = room
		p.later(func() -> void: p.lobby_ready.emit(code, {}))
	else:
		var c: String = str(first.get("code", ""))
		if not rooms.has(c) or (rooms[c]["host"] as Pipe).closed:
			p.later(func() -> void: p.refused.emit("no such room"))
			return p
		var r: Dictionary = rooms[c]
		p.id = int(r["next"])
		r["next"] = p.id + 1
		p.code = c
		(r["peers"] as Dictionary)[p.id] = p
		p.later(func() -> void:
			p.lobby_ready.emit(c, {})
			(r["host"] as Pipe).peer_connected.emit(p.id))
	return p


func deliver(from: Pipe, to: int, b: PackedByteArray) -> void:
	if not rooms.has(from.code):
		return
	var r: Dictionary = rooms[from.code]
	var at: int = Time.get_ticks_msec() + latency_ms
	if from.id == 1:
		var targets: Array = []
		if to == 0:
			targets = (r["peers"] as Dictionary).values()
		elif (r["peers"] as Dictionary).has(to):
			targets = [(r["peers"] as Dictionary)[to]]
		for t in targets:
			(t as Pipe).inbox.append([at, 1, b])
	else:
		var h: Pipe = r["host"]
		if not h.closed:
			h.inbox.append([at, from.id, b])


## Оборвать канал игрока (ретранслятор потерял его соединение).
func cut(p: Pipe) -> void:
	p.closed = true
	if not rooms.has(p.code):
		return
	var r: Dictionary = rooms[p.code]
	if p.id == 1:
		for g in (r["peers"] as Dictionary).values():
			(g as Pipe).later(func() -> void: (g as Pipe).peer_disconnected.emit(1))
		rooms.erase(p.code)
	else:
		(r["peers"] as Dictionary).erase(p.id)
		var h: Pipe = r["host"]
		h.later(func() -> void: h.peer_disconnected.emit(p.id))
		p.later(func() -> void: p.peer_disconnected.emit(1))


class Pipe extends RefCounted:
	signal lobby_ready(code: Variant, rules: Variant)
	signal refused(why: Variant)
	signal peer_connected(id: Variant)
	signal peer_disconnected(id: Variant)
	var relay: Object = null
	var id: int = 0
	var code: String = ""
	var closed: bool = false
	var target: int = 0
	var inbox: Array = []
	var _ready: Array = []
	var _later: Array = []
	var cur_peer: int = 0

	func later(f: Callable) -> void:
		# в том же порядке, что и данные: сначала дойдёт отправленное раньше
		inbox.append([Time.get_ticks_msec() + int(relay.get("latency_ms")) if relay != null else 0, -1, f])

	func poll() -> void:
		var now: int = Time.get_ticks_msec()
		if closed:
			# оборванный канал данных больше не отдаёт - только сигналы
			_ready.clear()
			inbox = inbox.filter(func(e: Array) -> bool: return int(e[1]) == -1)
		while not inbox.is_empty() and int((inbox[0] as Array)[0]) <= now:
			var e: Array = inbox.pop_front()
			if int(e[1]) == -1:
				if _ready.is_empty():
					(e[2] as Callable).call()
				else:
					_later.append(e[2])
			else:
				_ready.append(e)
		if _ready.is_empty() and not _later.is_empty():
			var l: Array = _later.duplicate()
			_later.clear()
			for f in l:
				(f as Callable).call()

	func set_target_peer(t: int) -> void:
		target = t

	func put_packet(b: PackedByteArray) -> int:
		if closed:
			return ERR_UNAVAILABLE
		relay.call("deliver", self, target, b)
		return OK

	func get_available_packet_count() -> int:
		return 0 if closed else _ready.size()

	func get_packet_peer() -> int:
		return int((_ready[0] as Array)[1]) if not _ready.is_empty() else 0

	func get_packet() -> PackedByteArray:
		if _ready.is_empty():
			return PackedByteArray()
		var e: Array = _ready.pop_front()
		return e[2]

	func close() -> void:
		if not closed:
			relay.call("cut", self)
		closed = true
