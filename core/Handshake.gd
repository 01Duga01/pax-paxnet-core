extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# РУКОПОЖАТИЕ UDP (как у Factorio/QUIC: хост не хранит ничего, пока клиент не докажет адрес).
#
#   клиент → HELLO(nonce_c, proto)                    (дополнен нулями: ответ не больше запроса)
#   хост   → CHALLENGE(nonce_c, окно времени, cookie) cookie = HMAC(секрет хоста, адрес|nonce_c|окно)
#   клиент → CONNECT(nonce_c, окно, cookie, секрет под RSA, info под секретом)
#                                                     info: имя, ключ игрока, моды, код входа, токен возврата…
#   хост   → ACCEPT(conn_id, welcome под секретом) | REJECT(код)
#
# CHALLENGE несёт открытый RSA-ключ хоста; клиент выдумывает секрет (32 байта) и шлёт его под этим ключом.
# Из секрета — ключ звена (подпись и AES-шифр пакетов, см. Cipher.gd) и ключ шифра info/welcome: ретранслятор
# и сеть видят только шифртекст. Повтор CONNECT (потерялся ACCEPT) получает тот же ACCEPT. Кадр: [0xA6][тип][тело][crc32].

const Bytes = preload("res://mods/paxnet_core/core/Bytes.gd")
const Crc32 = preload("res://mods/paxnet_core/core/Crc32.gd")
const Hmac = preload("res://mods/paxnet_core/core/Hmac.gd")
const Proto = preload("res://mods/paxnet_core/core/Proto.gd")
const Cipher = preload("res://mods/paxnet_core/core/Cipher.gd")
const UdpLink = preload("res://mods/paxnet_core/core/UdpLink.gd")

const WINDOW_MS := 10000
const PIN_TOTAL := 24          # длина PIN приглашения (см. Relay.PIN_LEN); последние FP_LEN знаков - отпечаток ключа хоста
const HELLO_SIZE := 400        # не меньше CHALLENGE (в нём открытый ключ): ответ не больше запроса


const Fr = preload("res://mods/paxnet_core/core/HsFrames.gd")


# ===================================================================== хост

class Listener extends RefCounted:
	var secret := PackedByteArray()
	var pin := ""                # PIN приглашения ("" — комната без защиты от посредника)
	var rsa: CryptoKey = null
	var pem := PackedByteArray()
	var send_to: Callable        # (endpoint: String, bytes) -> void
	var admit: Callable          # (endpoint, info: Dictionary, now_ms) -> {ok, code, welcome, ctx}
	var on_link: Callable        # (ctx, link: UdpLink, endpoint) -> void
	var mtu := 1200
	var link_tune := {}          # настройки нового звена от транспорта
	var _entries := {}           # conn_id -> {link, endpoint, ctx}
	var _by_endpoint := {}       # endpoint -> {nonce, accept, conn}
	var _rng := RandomNumberGenerator.new()
	# Дорогое (приватная операция RSA) ограничено: общее ведро и счётчик неудач на адрес.
	var _rsa_tokens := 40.0
	var _rsa_ms := 0
	var _bad := {}               # endpoint -> [неудач, начало окна, мс]

	func _rsa_allowed(endpoint: String, now_ms: int) -> bool:
		var b: Array = _bad.get(endpoint, [0, now_ms])
		if now_ms - int(b[1]) > 10000:
			b = [0, now_ms]
		if int(b[0]) >= 4:
			return false
		_rsa_tokens = minf(_rsa_tokens + float(now_ms - _rsa_ms) / 1000.0 * 20.0, 40.0)
		_rsa_ms = now_ms
		if _rsa_tokens < 1.0:
			return false
		_rsa_tokens -= 1.0
		return true

	func _fail(endpoint: String, now_ms: int) -> void:
		if _bad.size() > 2048:
			_bad.clear()
		var b: Array = _bad.get(endpoint, [0, now_ms])
		if now_ms - int(b[1]) > 10000:
			b = [0, now_ms]
		b[0] = int(b[0]) + 1
		_bad[endpoint] = b

	func _init() -> void:
		_rng.randomize()
		secret.resize(32)
		for i in 32:
			secret[i] = _rng.randi() & 255
		rsa = Cipher.host_key()
		pem = Cipher.public_pem(rsa)

	func _cookie(endpoint: String, nonce_c: int, window: int) -> PackedByteArray:
		var m := Bytes.W.new().text(endpoint).u64(nonce_c).u32(window).buf
		return Hmac.tag(secret, m, 16)

	func on_datagram(endpoint: String, data: PackedByteArray, now_ms: int) -> void:
		if data.is_empty():
			return
		if data[0] == UdpLink.MAGIC:
			_on_link_packet(endpoint, data, now_ms)
		elif data[0] == Fr.MAGIC:
			_on_handshake(endpoint, data, now_ms)

	func _on_link_packet(endpoint: String, data: PackedByteArray, now_ms: int) -> void:
		if data.size() < 6:
			return
		var conn := data.decode_u32(1)
		var e = _entries.get(conn)
		if e == null:
			return
		var link = e["link"]
		var before: int = link.stats["recv_packets"]
		link.receive(data, now_ms)
		if link.stats["recv_packets"] > before and e["endpoint"] != endpoint:
			# NAT сменил порт — подпись верна, значит это тот же клиент
			_by_endpoint.erase(e["endpoint"])
			e["endpoint"] = endpoint

	func _on_handshake(endpoint: String, data: PackedByteArray, now_ms: int) -> void:
		var p := Fr.parse(data)
		if p.is_empty():
			return
		var r: Bytes.R = p["r"]
		match int(p["type"]):
			Proto.H_HELLO:
				var proto := r.u8()
				var nonce_c := r.u64()
				if not r.ok:
					return
				if proto != Proto.VERSION:
					send_to.call(endpoint, Fr.frame(Proto.H_REJECT, Bytes.W.new().text(Proto.ERR_VERSION).buf))
					return
				var window := now_ms / WINDOW_MS
				var w := Bytes.W.new().u64(nonce_c).u32(window).raw(_cookie(endpoint, nonce_c, window)).bytes(pem)
				send_to.call(endpoint, Fr.frame(Proto.H_CHALLENGE, w.buf))
			Proto.H_CONNECT:
				var nonce_c2 := r.u64()
				var window2 := r.u32()
				var cookie := r.raw_n(16)
				var wrapped := r.bytes()
				var sealed_info := r.bytes()
				if not r.ok:
					return
				var cur := now_ms / WINDOW_MS
				if window2 != cur and window2 != cur - 1:
					return
				if not Hmac.equal(cookie, _cookie(endpoint, nonce_c2, window2)):
					return
				var known = _by_endpoint.get(endpoint)
				if known != null and known["nonce"] == nonce_c2:
					send_to.call(endpoint, known["accept"])   # ACCEPT потерялся
					return
				if not _rsa_allowed(endpoint, now_ms):
					return
				var sec := Cipher.unwrap_secret(rsa, wrapped)
				if sec.is_empty():
					_fail(endpoint, now_ms)
					return
				sec = Cipher.bind(sec, pin)
				var plain = Cipher.open_mac(sec, "pax-hs-c", sealed_info)
				if plain == null:
					_fail(endpoint, now_ms)
					return
				var info = Bytes.R.new(plain).variant()
				if not (info is Dictionary):
					_fail(endpoint, now_ms)
					return
				var d: Dictionary = admit.call(endpoint, info, now_ms)
				if not d.get("ok", false):
					send_to.call(endpoint, Fr.frame(Proto.H_REJECT, Bytes.W.new().text(str(d.get("code", "code"))).buf))
					return
				if known != null:
					_entries.erase(known["conn"])
				var conn := 0
				while conn == 0 or _entries.has(conn):
					conn = Cipher.random_bytes(4).decode_u32(0)
				var key := Fr.link_key(cookie, nonce_c2, sec)
				var link := UdpLink.new(conn, key)
				link.set_role(true)
				link.mtu = mtu
				Fr.tune(link, link_tune)
				var ent := {"link": link, "endpoint": endpoint, "ctx": d.get("ctx")}
				link.send_fn = func(b: PackedByteArray): send_to.call(ent["endpoint"], b)
				var acc := Fr.frame(Proto.H_ACCEPT, Bytes.W.new().u32(conn).bytes(Cipher.seal_mac(sec, "pax-hs-s", Bytes.W.new().variant(d.get("welcome", {})).buf)).buf)
				_entries[conn] = ent
				_by_endpoint[endpoint] = {"nonce": nonce_c2, "accept": acc, "conn": conn}
				send_to.call(endpoint, acc)
				on_link.call(d.get("ctx"), link, endpoint)

	# Забыть звено (игрок ушёл).
	func drop(link) -> void:
		for conn in _entries.keys():
			if _entries[conn]["link"] == link:
				_by_endpoint.erase(_entries[conn]["endpoint"])
				_entries.erase(conn)


# ===================================================================== клиент

class Dialer extends RefCounted:
	var send_fn: Callable        # (bytes) -> void
	var info: Dictionary
	var on_connected: Callable   # (link, welcome)
	var on_failed: Callable      # (code)
	var state := "idle"
	var mtu := 1200
	var retry_ms := 250
	var give_up_ms := 8000
	var link_tune := {}          # настройки нового звена от транспорта
	var pin := ""                # PIN из приглашения
	var _nonce := 0
	var _cookie := PackedByteArray()
	var _window := 0
	var _secret := PackedByteArray()
	var _connect := PackedByteArray()   # готовые (секрет под RSA, info под секретом) для повторов CONNECT
	var _started := -1
	var _last := -100000
	var link

	func start(now_ms: int, info_: Dictionary) -> void:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		_nonce = rng.randi() << 31 ^ rng.randi()
		info = info_
		state = "hello"
		_started = now_ms
		_last = -100000

	func poll(now_ms: int) -> void:
		if state != "hello" and state != "connect":
			return
		if now_ms - _started > give_up_ms:
			state = "failed"
			if on_failed.is_valid():
				on_failed.call(Proto.ERR_NO_ROUTE)
			return
		if now_ms - _last < retry_ms:
			return
		_last = now_ms
		if state == "hello":
			var w := Bytes.W.new().u8(Proto.VERSION).u64(_nonce)
			while w.size() < HELLO_SIZE:
				w.u8(0)
			send_fn.call(Fr.frame(Proto.H_HELLO, w.buf))
		else:
			var w2 := Bytes.W.new().u64(_nonce).u32(_window).raw(_cookie).raw(_connect)
			send_fn.call(Fr.frame(Proto.H_CONNECT, w2.buf))

	func on_datagram(data: PackedByteArray, now_ms: int) -> void:
		if link != null:
			link.receive(data, now_ms)
			return
		var p := Fr.parse(data)
		if p.is_empty():
			return
		var r: Bytes.R = p["r"]
		match int(p["type"]):
			Proto.H_CHALLENGE:
				if state != "hello":
					return
				var n := r.u64()
				var win := r.u32()
				var ck := r.raw_n(16)
				var pub := r.bytes()
				if not r.ok or n != _nonce:
					return
				# Приглашение несёт отпечаток ключа хоста: чужой (подставленный) ключ отвергаем до отправки секрета.
				if pin.length() == PIN_TOTAL and Cipher.fingerprint(pub) != pin.substr(PIN_TOTAL - Cipher.FP_LEN):
					state = "failed"
					if on_failed.is_valid():
						on_failed.call(Proto.ERR_PIN)
					return
				var raw_secret := Cipher.random_bytes(Cipher.SECRET_LEN)
				var wrapped := Cipher.wrap_secret(pub, raw_secret)
				if wrapped.is_empty():
					return
				_secret = Cipher.bind(raw_secret, pin)
				_connect = Bytes.W.new().bytes(wrapped).bytes(Cipher.seal_mac(_secret, "pax-hs-c", Bytes.W.new().variant(info).buf)).buf
				_cookie = ck
				_window = win
				state = "connect"
				_last = -100000
				poll(now_ms)
			Proto.H_ACCEPT:
				if state != "connect":
					return
				var conn := r.u32()
				var sealed := r.bytes()
				if not r.ok:
					return
				var plain = Cipher.open_mac(_secret, "pax-hs-s", sealed)
				if plain == null:
					return
				var welcome = Bytes.R.new(plain).variant()
				state = "connected"
				link = UdpLink.new(conn, Fr.link_key(_cookie, _nonce, _secret))
				link.set_role(false)
				link.mtu = mtu
				Fr.tune(link, link_tune)
				link.send_fn = send_fn
				link.last_recv_ms = now_ms
				if on_connected.is_valid():
					on_connected.call(link, welcome)
			Proto.H_REJECT:
				if state == "failed" or state == "connected":
					return
				var code := r.text()
				state = "failed"
				if on_failed.is_valid():
					on_failed.call(code)
