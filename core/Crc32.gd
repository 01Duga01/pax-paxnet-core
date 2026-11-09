extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# CRC-32 (IEEE) для кадров рукопожатия и контрольных сумм передачи.
#
# Скорость: четыре таблицы (slicing-by-4), но читаем по 8 байт разом: одно decode_u64 и
# восемь обращений к таблицам вместо шестнадцати «прочитать байт + таблица». Таблицы строятся один раз.

static var _t: Array = []


static func _build() -> void:
	var t0 := PackedInt64Array()
	t0.resize(256)
	for i in 256:
		var c := i
		for _k in 8:
			c = (0xEDB88320 ^ (c >> 1)) if (c & 1) else (c >> 1)
		t0[i] = c
	_t = [t0]
	for j in 3:
		var prev: PackedInt64Array = _t[j]
		var cur := PackedInt64Array()
		cur.resize(256)
		for i in 256:
			var c: int = prev[i]
			cur[i] = t0[c & 0xFF] ^ (c >> 8)
		_t.append(cur)


static func of(data: PackedByteArray, from: int = 0, to: int = -1) -> int:
	if _t.is_empty():
		_build()
	var n := data.size()
	if to < 0 or to > n:
		to = n
	if from < 0:
		from = 0
	var t0: PackedInt64Array = _t[0]
	var t1: PackedInt64Array = _t[1]
	var t2: PackedInt64Array = _t[2]
	var t3: PackedInt64Array = _t[3]
	var c := 0xFFFFFFFF
	var i := from
	while i + 8 <= to:
		var w: int = data.decode_u64(i)
		c ^= w & 0xFFFFFFFF
		c = t3[c & 0xFF] ^ t2[(c >> 8) & 0xFF] ^ t1[(c >> 16) & 0xFF] ^ t0[(c >> 24) & 0xFF]
		c ^= (w >> 32) & 0xFFFFFFFF
		c = t3[c & 0xFF] ^ t2[(c >> 8) & 0xFF] ^ t1[(c >> 16) & 0xFF] ^ t0[(c >> 24) & 0xFF]
		i += 8
	while i < to:
		c = t0[(c ^ data[i]) & 0xFF] ^ (c >> 8)
		i += 1
	return c ^ 0xFFFFFFFF
