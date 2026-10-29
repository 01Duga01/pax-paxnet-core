extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ПЕРЕДАЧА БОЛЬШИХ ДАННЫХ (мир целиком, крупные куски мира) без остановки игры.
#
# Данные режутся на куски; куски идут «одноразовыми» записями в остаток пакета (надёжные
# сообщения игры — шаги, приказы — всегда впереди), получатель подтверждает «всё до N + битовая
# карта следующих 64»; пропавшее досылается выборочно. Окно растёт, пока доходит, и сжимается
# при потерях. Игра в это время идёт: шаги мира для получателя копятся в очереди, а не теряются.

const Bytes = preload("res://mods/paxnet_core/core/Bytes.gd")
const Crc32 = preload("res://mods/paxnet_core/core/Crc32.gd")
const Proto = preload("res://mods/paxnet_core/core/Proto.gd")

const CHUNK_DATAGRAM := 1000
const CHUNK_STREAM := 16000


class Sender extends RefCounted:
	var link
	var id: int
	var data: PackedByteArray
	var chunk: int
	var count: int
	var meta
	var done := false
	var failed := false
	var cum := 0                 # всё до этого номера подтверждено
	var acked := {}              # номер → true (выше cum)
	var sent_at := {}            # номер → когда ушёл
	var cwnd := 8.0
	var max_cwnd := 192.0
	var ssthresh := 96.0
	var bytes_per_sec := 600000.0
	var _credit := 0.0
	var _last_ms := -1
	var _begun := false
	var _last_cut_ms := -100000
	var started_ms := -1
	var finished_ms := -1
	var resent := 0
	var on_done: Callable

	func _init(link_, id_: int, data_: PackedByteArray, meta_ = null) -> void:
		link = link_
		id = id_
		data = data_
		meta = meta_
		chunk = CHUNK_STREAM if link.reliable_only else CHUNK_DATAGRAM
		count = maxi(1, int(ceil(float(data.size()) / float(chunk))))
		if link.reliable_only:
			bytes_per_sec = 4000000.0
			cwnd = 64.0

	func progress() -> float:
		return float(mini(cum + acked.size(), count)) / float(count)

	func poll(now_ms: int) -> void:
		if done or failed:
			return
		if not _begun:
			_begun = true
			started_ms = now_ms
			var w := Bytes.W.new().varint(id).varint(data.size()).varint(count).varint(chunk).u32(Crc32.of(data)).variant(meta)
			link.send_reliable(Proto.M_XFER_BEGIN, w.buf)
		if _last_ms < 0:
			_last_ms = now_ms
		_credit = minf(_credit + float(now_ms - _last_ms) * bytes_per_sec / 1000.0, bytes_per_sec * 0.25 + chunk)
		_last_ms = now_ms
		var rto: float = link.rto_ms() * 1.5 if not link.reliable_only else 1.0e9
		# что в полёте
		var in_flight := sent_at.size()
		var timed_out := false
		var i := cum
		var budget_scan := 0
		while i < count and budget_scan < 4096:
			budget_scan += 1
			if acked.has(i):
				i += 1
				continue
			var t = sent_at.get(i)
			var want := false
			if t == null:
				want = in_flight < int(cwnd)
			elif float(now_ms - int(t)) > rto:
				want = true
				timed_out = true
				resent += 1
			if want:
				if _credit < 1.0 or link.pending_oneshots() > 24:
					break
				if t == null:
					in_flight += 1
				var from := i * chunk
				var part := data.slice(from, mini(from + chunk, data.size()))
				var w2 := Bytes.W.new().varint(id).varint(i).raw(part)
				if link.send_oneshot(Proto.M_XFER_CHUNK, w2.buf):
					_credit -= float(part.size()) + 10.0
					sent_at[i] = now_ms
				else:
					break
			i += 1
		# Потеря сжимает окно не чаще раза за RTT и не ниже 12 кусков: при 5% потерь иначе окно схлопывается в ноль.
		if timed_out and now_ms - _last_cut_ms > int(link.rto_ms()):
			_last_cut_ms = now_ms
			ssthresh = maxf(cwnd * 0.7, 12.0)
			cwnd = maxf(ssthresh, 12.0)

	func on_ack(cum_: int, bitmap: int, now_ms: int) -> void:
		var grew := 0
		if cum_ > cum:
			for k in range(cum, mini(cum_, count)):
				if sent_at.has(k):
					sent_at.erase(k)
					grew += 1
				acked.erase(k)
			cum = cum_
		for b in 64:
			if bitmap & (1 << b):
				var idx := cum + 1 + b
				if idx < count and not acked.has(idx):
					acked[idx] = true
					sent_at.erase(idx)
					grew += 1
		while acked.has(cum):
			acked.erase(cum)
			sent_at.erase(cum)
			cum += 1
		if grew > 0:
			cwnd = minf(cwnd + (float(grew) if cwnd < ssthresh else float(grew) / maxf(cwnd, 1.0)), max_cwnd)

	func on_end(ok: bool, now_ms: int) -> void:
		if ok:
			done = true
			finished_ms = now_ms
			if on_done.is_valid():
				on_done.call(id, true)
		else:
			# сумма не сошлась: начинаем сначала
			cum = 0
			acked.clear()
			sent_at.clear()
			_begun = false
			cwnd = 8.0


const MAX_SIZE := 128 << 20       # самая большая передача (мир, лечебный пакет), байт
const MAX_COUNT := 1 << 20


class Receiver extends RefCounted:
	var link
	var id: int
	var size: int
	var count: int
	var chunk: int
	var crc: int
	var meta
	var parts := {}
	var cum := 0
	var done := false
	var data := PackedByteArray()
	var on_done: Callable          # (id, data, meta)
	var _ack_dirty := true
	var _last_ack_ms := -1000

	func _init(link_, begin_body: PackedByteArray) -> void:
		link = link_
		var r := Bytes.R.new(begin_body)
		id = r.varint()
		size = r.varint()
		count = r.varint()
		chunk = r.varint()
		crc = r.u32()
		meta = r.variant()
		# Размеры приходят от отправителя (хост для гостя, гость для хоста): потолки против нехватки памяти.
		if not r.ok or count <= 0 or count > MAX_COUNT or size < 0 or size > MAX_SIZE or chunk <= 0 or chunk > 65536 \
				or count > size / chunk + 1 or (size > 0 and count < size / chunk):
			done = true

	func valid() -> bool:
		return not done or not data.is_empty() or size == 0

	func progress() -> float:
		return float(mini(cum + parts.size(), count)) / float(count)

	func on_chunk(body: PackedByteArray) -> void:
		if done:
			return
		var r := Bytes.R.new(body)
		var xid := r.varint()
		var idx := r.varint()
		if not r.ok or xid != id or idx >= count or idx < cum or parts.has(idx):
			_ack_dirty = true
			return
		parts[idx] = r.rest()
		_ack_dirty = true
		while parts.has(cum):
			cum += 1

	func poll(now_ms: int) -> void:
		if done:
			return
		if cum >= count and not _all_present():
			return
		if cum >= count:
			_finish(now_ms)
			return
		if _ack_dirty or now_ms - _last_ack_ms > 100:
			_send_ack()
			_ack_dirty = false
			_last_ack_ms = now_ms

	func _all_present() -> bool:
		return cum >= count

	func _send_ack() -> void:
		var bitmap := 0
		for b in 64:
			if parts.has(cum + 1 + b):
				bitmap |= (1 << b)
		link.send_unreliable(Proto.M_XFER_ACK, Bytes.W.new().varint(id).varint(cum).u64(bitmap).buf)

	func _finish(now_ms: int) -> void:
		var all := PackedByteArray()
		for i in count:
			all.append_array(parts[i])
		var ok := all.size() == size and Crc32.of(all) == crc
		link.send_reliable(Proto.M_XFER_END, Bytes.W.new().varint(id).u8(1 if ok else 0).buf)
		if ok:
			done = true
			data = all
			if on_done.is_valid():
				on_done.call(id, all, meta)
		else:
			parts.clear()
			cum = 0
			_ack_dirty = true
