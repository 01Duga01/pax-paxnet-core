extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# КАНАЛ СООБЩЕНИЙ ИГРЫ И МОДОВ между двумя сторонами (хост ↔ один гость). Поверх надёжного звена,
# но переживает и переподключение: каждое сообщение с номером, получатель подтверждает «всё до N»,
# неподтверждённое после возврата шлётся снова, повтор отсеивается по номеру. Так сообщение
# доходит ровно один раз, даже если связь рвалась посередине (раньше: «приказ отдан, но не исполнен»).
# Большие сообщения сжимаются и едут частями (Frag).

const Bytes = preload("res://mods/paxnet_core/core/Bytes.gd")
const Proto = preload("res://mods/paxnet_core/core/Proto.gd")
const Frag = preload("res://mods/paxnet_core/core/Frag.gd")

const COMPRESS_FROM := 4096
const MAX_UNPACK := 4 << 20      # предел размера после распаковки (хост берёт свой из cfg)
const MAX_WINDOW := 1024         # насколько вперёд от in_seq принимаем номера не по порядку

var next_seq := 1
var out := {}                    # seq → тело (готовое к отправке)
var in_seq := 0                  # всё до этого номера уже отдано игре
var _hold := {}                  # пришедшие раньше времени
var _acked_sent := -1
var max_unpack := MAX_UNPACK
var max_window := MAX_WINDOW
var violated := false            # собеседник нарушил предел: звено пора рвать


func send(link, payload: Dictionary) -> int:
	var seq := next_seq
	next_seq += 1
	payload["s"] = seq
	var raw := Bytes.encode(payload)
	var body := PackedByteArray([0])
	if raw.size() >= COMPRESS_FROM:
		body = PackedByteArray([1])
		var w := Bytes.W.new().varint(raw.size())
		body.append_array(w.buf)
		body.append_array(raw.compress(Bytes.ZSTD))
	else:
		body.append_array(raw)
	out[seq] = body
	if link != null:
		Frag.send(link, Proto.M_APP, body)
	return seq


# После переподключения: всё неподтверждённое — заново, по порядку.
func resend(link) -> void:
	var ks := out.keys()
	ks.sort()
	for s in ks:
		Frag.send(link, Proto.M_APP, out[s])
	_acked_sent = -1


func on_ack(body: PackedByteArray) -> void:
	var r := Bytes.R.new(body)
	var upto := r.varint()
	if not r.ok:
		return
	for s in out.keys():
		if int(s) <= upto:
			out.erase(s)


# Заявленный размер сообщения после распаковки (дёшево, без распаковки). -1 — заголовок битый.
static func claimed_size(body: PackedByteArray) -> int:
	if body.is_empty():
		return 0
	if body[0] != 1:
		return body.size() - 1
	var r := Bytes.R.new(body, 1)
	var size := r.varint()
	return size if r.ok else -1


# Пришло сообщение. Возвращает список готовых по порядку (повторы отброшены).
func on_msg(body: PackedByteArray) -> Array:
	if body.is_empty():
		return []
	var raw: PackedByteArray
	if body[0] == 1:
		var r := Bytes.R.new(body, 1)
		var size := r.varint()
		if not r.ok or size > max_unpack:
			violated = true
			return []
		raw = body.slice(r.pos).decompress(size, Bytes.ZSTD)
		if raw.size() != size:
			return []
	else:
		if body.size() - 1 > max_unpack:
			violated = true
			return []
		raw = body.slice(1)
	var d := Bytes.decode(raw)
	if not d["ok"] or not (d["v"] is Dictionary):
		return []
	var m: Dictionary = d["v"]
	var s := int(m.get("s", 0))
	if s <= in_seq or _hold.has(s):
		return []
	if s - in_seq > max_window:
		violated = true
		return []
	_hold[s] = m
	var ready: Array = []
	while _hold.has(in_seq + 1):
		in_seq += 1
		ready.append(_hold[in_seq])
		_hold.erase(in_seq)
	return ready


func poll(link) -> void:
	if link != null and in_seq != _acked_sent:
		_acked_sent = in_seq
		link.send_unreliable(Proto.M_APP_ACK, Bytes.W.new().varint(in_seq).buf)
