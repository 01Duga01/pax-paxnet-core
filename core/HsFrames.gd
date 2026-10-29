extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Кадры рукопожатия: сборка, разбор, ключ звена. Отдельно от Handshake.gd, чтобы вложенные классы видели статику.

const Bytes = preload("res://mods/paxnet/core/Bytes.gd")
const Crc32 = preload("res://mods/paxnet/core/Crc32.gd")
const Hmac = preload("res://mods/paxnet/core/Hmac.gd")

const MAGIC := 0xA6


static func frame(type: int, body: PackedByteArray) -> PackedByteArray:
	var f := PackedByteArray([MAGIC, type])
	f.append_array(body)
	var c := Crc32.of(f)
	var n := f.size()
	f.resize(n + 4)
	f.encode_u32(n, c)
	return f


# → {type, r: Reader} или {} если кадр повреждён.
static func parse(data: PackedByteArray) -> Dictionary:
	if data.size() < 6 or data[0] != MAGIC:
		return {}
	var n := data.size() - 4
	if Crc32.of(data, 0, n) != data.decode_u32(n):
		return {}
	return {"type": data[1], "r": Bytes.R.new(data.slice(0, n), 2)}


## Применить к звену настройки транспорта (только известные числовые поля).
static func tune(link: Object, t: Dictionary) -> void:
	for k in ["timeout_ms", "keepalive_ms", "ack_delay_ms", "redundant_gap_ms", "min_rto_ms", "max_rto_ms", "max_packets_per_poll"]:
		if t.has(k):
			link.set(k, int(t[k]))


static func link_key(cookie: PackedByteArray, nonce_c: int) -> PackedByteArray:
	var m := cookie.duplicate()
	m.append_array(Bytes.W.new().u64(nonce_c).buf)
	return Hmac.mac(m, "pax-link".to_utf8_buffer())
