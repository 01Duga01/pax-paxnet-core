extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Хеш состояния для сверки миров. Родной hash() Godot у словарей зависит от порядка вставки
# (проверено), а у двух копий мира порядок разный, поэтому свой: словарь — сумма хешей пар
# (не зависит от порядка), массив — по порядку. Числа с плавающей точкой округляются до 1e-6:
# последний бит не повод для «расхождения».
#
# Скорость: _mix развёрнут по месту, разбор типа — цепочкой if (match по sizeof здесь стоит
# в шесть раз дороже). Значения те же до бита — хеш не имеет права поехать, иначе две версии
# библиотеки перестанут сходиться по сети.

const MASK := 0x7FFFFFFFFFFFFFFF
const FLOAT_STEP := 0.000001
const K := 0x100000001B3
const TAIL := 0x7FFFFFFFF


# Оставлен для совместимости: снаружи им никто не пользуется, внутри всё развёрнуто.
static func _mix(h: int, x: int) -> int:
	h = (h ^ x) * K
	h ^= (h >> 29) & TAIL
	return h


# Хеш одного значения, 63 бита.
static func of(v, depth: int = 0) -> int:
	if depth > 48:
		return 7
	var t := typeof(v)
	if t == TYPE_INT:
		var h: int = (4 ^ v) * K
		return h ^ ((h >> 29) & TAIL)
	if t == TYPE_DICTIONARY:
		var sum := 0
		for k in v:
			var m: int = (of(k, depth + 1) ^ of(v[k], depth + 1)) * K
			sum += m ^ ((m >> 29) & TAIL)
		if (v as Dictionary).is_empty():
			return 13
		var h: int = (13 ^ sum) * K
		return h ^ ((h >> 29) & TAIL)
	if t == TYPE_STRING:
		var h: int = (10 ^ hash(v)) * K
		return h ^ ((h >> 29) & TAIL)
	if t == TYPE_FLOAT:
		if is_nan(v):
			return 5
		if is_inf(v):
			return 6 if v > 0.0 else 8
		var h: int = (9 ^ (int(roundf(v / FLOAT_STEP)) if absf(v) < 1.0e9 else hash(v))) * K
		return h ^ ((h >> 29) & TAIL)
	if t == TYPE_ARRAY:
		var h := 11
		for e in v:
			var m: int = (h ^ of(e, depth + 1)) * K
			h = m ^ ((m >> 29) & TAIL)
		return h
	if t == TYPE_BOOL:
		return 2 if v else 3
	if t == TYPE_NIL:
		return 1
	if t == TYPE_STRING_NAME:
		var h: int = (10 ^ hash(String(v))) * K
		return h ^ ((h >> 29) & TAIL)
	if t == TYPE_PACKED_BYTE_ARRAY:
		var h: int = (12 ^ hash(v)) * K
		return h ^ ((h >> 29) & TAIL)
	if t == TYPE_PACKED_INT32_ARRAY or t == TYPE_PACKED_INT64_ARRAY \
			or t == TYPE_PACKED_STRING_ARRAY or t == TYPE_PACKED_FLOAT32_ARRAY \
			or t == TYPE_PACKED_FLOAT64_ARRAY:
		var h := 11
		for e in v:
			var m: int = (h ^ of(e, depth + 1)) * K
			h = m ^ ((m >> 29) & TAIL)
		return h
	if t == TYPE_VECTOR2:
		var m: int = (14 ^ of(v.x)) * K
		var h: int = (m ^ ((m >> 29) & TAIL) ^ of(v.y)) * K
		return h ^ ((h >> 29) & TAIL)
	if t == TYPE_VECTOR3:
		var m1: int = (15 ^ of(v.x)) * K
		var a1: int = m1 ^ ((m1 >> 29) & TAIL)
		var m2: int = (a1 ^ of(v.y)) * K
		var a2: int = m2 ^ ((m2 >> 29) & TAIL)
		var m3: int = (a2 ^ of(v.z)) * K
		return m3 ^ ((m3 >> 29) & TAIL)
	if t == TYPE_COLOR:
		var m1: int = (16 ^ of(v.r)) * K
		var a1: int = m1 ^ ((m1 >> 29) & TAIL)
		var m2: int = (a1 ^ of(v.g)) * K
		var a2: int = m2 ^ ((m2 >> 29) & TAIL)
		var m3: int = (a2 ^ of(v.b)) * K
		var a3: int = m3 ^ ((m3 >> 29) & TAIL)
		var m4: int = (a3 ^ of(v.a)) * K
		return m4 ^ ((m4 >> 29) & TAIL)
	if t == TYPE_VECTOR2I:
		var m1: int = (17 ^ v.x) * K
		var h: int = (m1 ^ ((m1 >> 29) & TAIL) ^ v.y) * K
		return h ^ ((h >> 29) & TAIL)
	return 0   # объекты и вызовы мир не описывают


# Короткая метка для сети — 32 бита.
static func short(v) -> int:
	var h := of(v)
	return (h ^ (h >> 32)) & 0xFFFFFFFF
