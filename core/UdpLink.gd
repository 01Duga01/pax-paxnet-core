extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# НАДЁЖНОСТЬ ПОВЕРХ UDP (по духу — как в Factorio: ничего не ждём, всё повторяем сами).
#
# Один UdpLink — одно соединение «хост ↔ гость». Умеет три вида сообщений:
#   reliable   — доставляется ровно один раз и по порядку. Потерянное шлётся снова: быстро (если
#                пришло подтверждение более новых пакетов) или по таймеру RTO. Флаг redundant
#                кладёт сообщение в КАЖДЫЙ исходящий пакет, пока оно не подтверждено (так едут
#                шаги мира и приказы: потеря пакета лечится следующим, не дожидаясь RTT);
#   unreliable — «последнее значение»: на тип сообщения одна ячейка, старое вытесняется
#                (пульс, пинг, статус), опоздавшее старое не отдаётся;
#   oneshot    — одноразовое без повторов (куски больших передач: повтором занимается Xfer).
#
# Заголовок пакета: magic u8 | flags u8 (бит 0 — поле ack действительно) | conn u32 | seq u32 | ack u32 | ack_bits u32 (бит i — получен
# пакет ack-1-i) | IV (16) | записи, зашифрованные AES-128-CBC (с дополнением до 16) | подпись HMAC-SHA256
# (8 байт) по всему пакету. Ключи шифра и подписи выводятся из ключа звена (см. Cipher.gd); заголовок открыт.
#
# Время передаётся снаружи (now_ms), сокетов здесь нет: ядро одинаково работает на настоящем
# UDP, в симуляторе сети тестов и (в виде StreamLink) поверх WebSocket.

const Bytes = preload("res://mods/paxnet_core/core/Bytes.gd")
const Hmac = preload("res://mods/paxnet_core/core/Hmac.gd")
const Cipher = preload("res://mods/paxnet_core/core/Cipher.gd")

const MAGIC := 0xA7
const HEADER := 18              # magic 1 | conn 4 | flags 1 | seq 4 | ack 4 | ack_bits 4
const TAG := 16
const ENC_OVERHEAD := 32         # IV (16) + дополнение шифра (до 16)
const REC_RELIABLE := 1
const REC_SLOT := 2
const REC_ONESHOT := 3

var conn_id := 0
var key := PackedByteArray()
var tx_key := PackedByteArray()      # подпись исходящих; у хоста и гостя разная (зеркалить пакет нельзя)
var rx_key := PackedByteArray()
var tx_enc := PackedByteArray()
var rx_enc := PackedByteArray()
var mtu := 1200
var send_fn: Callable            # (PackedByteArray) -> void
var on_message: Callable         # (type: int, body: PackedByteArray) -> void
var timeout_ms := 10000
var keepalive_ms := 250
var ack_delay_ms := 15
var redundant_gap_ms := 40
var min_rto_ms := 60
var max_rto_ms := 2500
var oneshot_share := 0.6         # какую долю пакета можно отдать кускам передач
var reliable_only := false       # транспорт сам надёжен (WebSocket): без подтверждений и повторов

# --- состояние ---
var srtt_ms := 0.0
var rttvar_ms := 0.0
var recv_loss := 0.0
var dead := false
var last_recv_ms := 0
var stats := {"sent_packets": 0, "recv_packets": 0, "dup_packets": 0, "retransmits": 0, "bad_packets": 0,
	"sent_bytes": 0, "recv_bytes": 0}

var _seq := 0
var _next_msg := 1
var _out := {}                   # id -> {id,type,body,redundant,last,pkt,tries}
var _sent := {}                  # seq -> {t, ids}
var _hi_acked := -1
var _have_hi_acked := false
var _recv_hi := -1
var _recv_bits := 0
var _next_in := 1
var _hold := {}                  # id -> [type, body]
var _slots := {}                 # type -> body
var _slot_seq := {}              # type -> seq последнего принятого
var _oneshots: Array = []
var _ack_due := -1
var _last_send_ms := 0
var _ever_sent := false
var _last_redundant_ms := -100000
var max_packets_per_poll := 6


func _init(conn: int = 0, key_: PackedByteArray = PackedByteArray()) -> void:
	conn_id = conn
	key = key_
	set_role(false, false)


## Ключи по направлениям: хост шлёт ключом s2c, гость c2s; пакет, возвращённый отправителю, не пройдёт проверку.
## directional = false оставляет один общий ключ (тесты звена в одиночку).
func set_role(is_server: bool, directional: bool = true) -> void:
	if not directional:
		tx_key = key
		rx_key = key
		tx_enc = Cipher.derive_aes(key, "pax-pkt-enc")
		rx_enc = tx_enc
		return
	var out_dir := "s2c" if is_server else "c2s"
	var in_dir := "c2s" if is_server else "s2c"
	tx_key = Cipher.derive(key, "pax-mac-" + out_dir)
	rx_key = Cipher.derive(key, "pax-mac-" + in_dir)
	tx_enc = Cipher.derive_aes(key, "pax-enc-" + out_dir)
	rx_enc = Cipher.derive_aes(key, "pax-enc-" + in_dir)


func budget() -> int:
	return mtu - HEADER - TAG - ENC_OVERHEAD


# Самое большое сообщение, которое влезает в пакет.
func max_message() -> int:
	return budget() - 12


# --------------------------------------------------------------- отправка (очереди)

func send_reliable(type: int, body: PackedByteArray = PackedByteArray(), redundant: bool = false) -> bool:
	if reliable_only:
		_emit_stream(REC_RELIABLE, type, body)
		return true
	if body.size() > max_message():
		push_error("[paxnet] UdpLink: message %d too large (%d)" % [type, body.size()])
		return false
	var id := _next_msg
	_next_msg += 1
	_out[id] = {"id": id, "type": type, "body": body, "redundant": redundant, "last": -1, "pkt": -1, "tries": 0}
	return true


func send_unreliable(type: int, body: PackedByteArray = PackedByteArray()) -> void:
	if reliable_only:
		_emit_stream(REC_SLOT, type, body)
		return
	if body.size() <= max_message():
		_slots[type] = body


func send_oneshot(type: int, body: PackedByteArray) -> bool:
	if reliable_only:
		_emit_stream(REC_ONESHOT, type, body)
		return true
	if body.size() > max_message() or _oneshots.size() > 4096:
		return false
	_oneshots.append([type, body])
	return true


func pending_oneshots() -> int:
	return _oneshots.size()


func unacked_count() -> int:
	return _out.size()


func bytes_in_flight() -> int:
	var n := 0
	for id in _out:
		var m: Dictionary = _out[id]
		if m["last"] >= 0:
			n += m["body"].size() + 6
	return n


# Надёжный транспорт (WebSocket): каждое сообщение — отдельный кадр [вид u8][тип u8][тело].
func _emit_stream(kind: int, type: int, body: PackedByteArray) -> void:
	var f := PackedByteArray([kind, type])
	f.append_array(body)
	stats["sent_packets"] += 1
	stats["sent_bytes"] += f.size()
	_last_send_ms = _last_send_ms
	if send_fn.is_valid():
		send_fn.call(f)


func rto_ms() -> float:
	if srtt_ms <= 0.0:
		return 300.0
	return clampf(srtt_ms + 4.0 * rttvar_ms, float(min_rto_ms), float(max_rto_ms))


# --------------------------------------------------------------- приём

func receive(data: PackedByteArray, now_ms: int) -> void:
	if data.size() < HEADER + 2 * Cipher.BLOCK + TAG or data[0] != MAGIC:
		stats["bad_packets"] += 1
		return
	var sealed_end := data.size() - TAG
	if not Hmac.equal(Hmac.tag(rx_key, data.slice(0, sealed_end), TAG), data.slice(sealed_end)):
		stats["bad_packets"] += 1
		return
	var inner = Cipher.open(rx_enc, data.slice(HEADER, sealed_end))
	if inner == null:
		stats["bad_packets"] += 1
		return
	var plain: PackedByteArray = data.slice(0, HEADER)
	plain.append_array(inner)
	var body_end := plain.size()
	var r := Bytes.R.new(plain, 1)
	if r.u32() != conn_id:
		stats["bad_packets"] += 1
		return
	var flags := r.u8()
	var seq := r.u32()
	var ack := r.u32()
	var bits := r.u32()
	if dead:
		return
	last_recv_ms = now_ms
	stats["recv_bytes"] += data.size()
	if _is_dup(seq):
		stats["dup_packets"] += 1
		_ack_due = now_ms if _ack_due < 0 else _ack_due
		return
	stats["recv_packets"] += 1
	if _ack_due < 0:
		_ack_due = now_ms
	if flags & 1:
		_process_acks(ack, bits, now_ms)
	while r.pos < body_end and r.ok:
		var kind := r.u8()
		match kind:
			REC_RELIABLE:
				var id := r.varint()
				var t := r.u8()
				var b := r.bytes()
				if r.ok:
					_deliver_reliable(id, t, b)
			REC_SLOT:
				var t2 := r.u8()
				var b2 := r.bytes()
				if r.ok:
					var prev = _slot_seq.get(t2)
					if prev == null or _seq_diff(seq, prev) > 0:
						_slot_seq[t2] = seq
						_call(t2, b2)
			REC_ONESHOT:
				var t3 := r.u8()
				var b3 := r.bytes()
				if r.ok:
					_call(t3, b3)
			_:
				r.ok = false
	if not r.ok:
		stats["bad_packets"] += 1


# Приём кадра у надёжного транспорта (WebSocket): [kind u8][type u8][body].
func receive_stream(data: PackedByteArray, now_ms: int) -> void:
	if data.size() < 2:
		return
	last_recv_ms = now_ms
	stats["recv_bytes"] += data.size()
	stats["recv_packets"] += 1
	_call(data[1], data.slice(2))


func _call(t: int, b: PackedByteArray) -> void:
	if on_message.is_valid():
		on_message.call(t, b)


static func _seq_diff(a: int, b: int) -> int:
	return ((a - b + 0x80000000) & 0xFFFFFFFF) - 0x80000000


func _is_dup(seq: int) -> bool:
	if _recv_hi < 0:
		_recv_hi = seq
		_recv_bits = 0
		return false
	var diff := _seq_diff(seq, _recv_hi)
	if diff > 0:
		recv_loss = lerpf(recv_loss, float(diff - 1) / float(diff), 0.05) if diff > 1 else lerpf(recv_loss, 0.0, 0.02)
		if diff > 32:
			_recv_bits = 0
		else:
			_recv_bits = ((_recv_bits << diff) | (1 << (diff - 1))) & 0xFFFFFFFF
		_recv_hi = seq
		return false
	if diff == 0:
		return true
	var d := -diff
	if d > 32:
		return true    # старше окна: считаем повтором (номер 32-битный, «круг» не наступит)
	var bit := 1 << (d - 1)
	if _recv_bits & bit:
		return true
	_recv_bits |= bit
	return false


func _process_acks(ack: int, bits: int, now_ms: int) -> void:
	var acked: Array = [ack]
	for i in 32:
		if bits & (1 << i):
			acked.append((ack - 1 - i) & 0xFFFFFFFF)
	for s in acked:
		var rec = _sent.get(s)
		if rec == null:
			continue
		_sent.erase(s)
		var sample := float(now_ms - int(rec["t"]))
		if srtt_ms <= 0.0:
			srtt_ms = sample
			rttvar_ms = sample / 2.0
		else:
			rttvar_ms = 0.75 * rttvar_ms + 0.25 * absf(srtt_ms - sample)
			srtt_ms = 0.875 * srtt_ms + 0.125 * sample
		for id in rec["ids"]:
			_out.erase(id)
		if not _have_hi_acked or _seq_diff(s, _hi_acked) > 0:
			_hi_acked = s
			_have_hi_acked = true
	# Давно не подтверждённые пакеты забываем (их сообщения повторятся по таймеру).
	if _sent.size() > 256:
		var limit := int(rto_ms() * 4.0) + 2000
		for s2 in _sent.keys():
			if now_ms - int(_sent[s2]["t"]) > limit or _seq_diff(_seq, s2) > 30000:
				_sent.erase(s2)


func _deliver_reliable(id: int, t: int, b: PackedByteArray) -> void:
	if id < _next_in or _hold.has(id):
		return
	if id - _next_in > 4096:
		return
	if id != _next_in:
		_hold[id] = [t, b]
		return
	_call(t, b)
	_next_in += 1
	while _hold.has(_next_in):
		var h: Array = _hold[_next_in]
		_hold.erase(_next_in)
		_next_in += 1
		_call(h[0], h[1])


# --------------------------------------------------------------- отправка (пакеты)

func poll(now_ms: int) -> void:
	if dead:
		return
	if last_recv_ms == 0:
		last_recv_ms = now_ms
	if now_ms - last_recv_ms > timeout_ms:
		dead = true
		return
	if reliable_only:
		return
	var guard := 0
	while guard < max_packets_per_poll and _should_send(now_ms):
		guard += 1
		_send_packet(now_ms)


# Сообщение пора (пере)послать: новое, быстрый повтор (ушедшее позже уже подтверждено) или RTO.
func _due(m: Dictionary, now_ms: int) -> bool:
	if m["last"] < 0:
		return true
	var since := now_ms - int(m["last"])
	if _have_hi_acked and m["pkt"] >= 0 and _seq_diff(_hi_acked, m["pkt"]) >= 3 and since >= 5:
		return true
	return float(since) >= rto_ms() * float(1 << mini(int(m["tries"]), 4))


func _has_redundant() -> bool:
	for id in _out:
		if _out[id]["redundant"]:
			return true
	return false


func _should_send(now_ms: int) -> bool:
	if not _oneshots.is_empty() or not _slots.is_empty():
		return true
	for id in _out:
		if _due(_out[id], now_ms):
			return true
	if now_ms - _last_send_ms >= redundant_gap_ms and _has_redundant():
		return true
	if _ack_due >= 0 and now_ms - _ack_due >= ack_delay_ms:
		return true
	return not _ever_sent or now_ms - _last_send_ms >= keepalive_ms


func _send_packet(now_ms: int) -> void:
	_ever_sent = true
	var w := Bytes.W.new()
	w.u8(MAGIC).u32(conn_id).u8(1 if _recv_hi >= 0 else 0)
	var seq := _seq
	_seq = (_seq + 1) & 0xFFFFFFFF
	w.u32(seq)
	var ack := _recv_hi if _recv_hi >= 0 else 0
	w.u32(ack).u32(_recv_bits)
	var room := mtu - TAG - ENC_OVERHEAD
	var ids: Array = []
	# 1. надёжные, которым пора: новые и потерянные — по порядку id
	var used := {}
	for id in _out:
		var m: Dictionary = _out[id]
		if not _due(m, now_ms):
			continue
		var need: int = m["body"].size() + 10
		if w.size() + need > room:
			break
		if m["last"] >= 0:
			stats["retransmits"] += 1
			m["tries"] += 1
		w.u8(REC_RELIABLE).varint(id).u8(m["type"]).bytes(m["body"])
		m["last"] = now_ms
		m["pkt"] = seq
		ids.append(id)
		used[id] = true
	# 1б. избыточные (шаги мира, приказы) — в остаток места, свежие первыми, не чаще redundant_gap:
	# потерянный пакет лечится следующим, не дожидаясь RTT; новое сообщение они не вытесняют никогда
	if now_ms - _last_redundant_ms >= redundant_gap_ms:
		var keys := _out.keys()
		var put := 0
		for k in range(keys.size() - 1, -1, -1):
			var id2 = keys[k]
			var m2: Dictionary = _out[id2]
			if not m2["redundant"] or used.has(id2) or m2["last"] < 0:
				continue
			var need2: int = m2["body"].size() + 10
			if w.size() + need2 > room or put >= 8:
				continue
			w.u8(REC_RELIABLE).varint(id2).u8(m2["type"]).bytes(m2["body"])
			m2["pkt"] = seq
			ids.append(id2)
			put += 1
		if put > 0:
			_last_redundant_ms = now_ms
	# 2. «последнее значение»
	for t in _slots.keys():
		var b: PackedByteArray = _slots[t]
		if w.size() + b.size() + 6 > room:
			continue
		w.u8(REC_SLOT).u8(t).bytes(b)
		_slots.erase(t)
	# 3. куски передач — в оставшуюся долю пакета
	var cap := room if ids.is_empty() else maxi(int(float(room) * oneshot_share), w.size())
	while not _oneshots.is_empty():
		var o: Array = _oneshots[0]
		var ob: PackedByteArray = o[1]
		if w.size() + ob.size() + 6 > cap:
			break
		_oneshots.pop_front()
		w.u8(REC_ONESHOT).u8(o[0]).bytes(ob)
	var head: PackedByteArray = w.buf.slice(0, HEADER)
	var packet: PackedByteArray = head
	packet.append_array(Cipher.seal(tx_enc, w.buf.slice(HEADER)))
	packet.append_array(Hmac.tag(tx_key, packet, TAG))
	_sent[seq] = {"t": now_ms, "ids": ids}
	_ack_due = -1
	_last_send_ms = now_ms
	stats["sent_packets"] += 1
	stats["sent_bytes"] += packet.size()
	if send_fn.is_valid():
		send_fn.call(packet)
