extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Хеш состояния для сверки миров. Родной hash() Godot у словарей зависит от порядка вставки
# (проверено), а у двух копий мира порядок разный, поэтому свой: словарь — сумма хешей пар
# (не зависит от порядка), массив — по порядку. Числа с плавающей точкой округляются до 1e-6:
# последний бит не повод для «расхождения».

const MASK := 0x7FFFFFFFFFFFFFFF
const FLOAT_STEP := 0.000001


static func _mix(h: int, x: int) -> int:
	h = (h ^ x) * 0x100000001B3
	h ^= (h >> 29) & 0x7FFFFFFFF
	return h


# Хеш одного значения, 63 бита.
static func of(v, depth: int = 0) -> int:
	if depth > 48:
		return 7
	match typeof(v):
		TYPE_NIL:
			return 1
		TYPE_BOOL:
			return 2 if v else 3
		TYPE_INT:
			return _mix(4, v)
		TYPE_FLOAT:
			if is_nan(v):
				return 5
			if is_inf(v):
				return 6 if v > 0.0 else 8
			return _mix(9, int(roundf(v / FLOAT_STEP)) if absf(v) < 1.0e9 else hash(v))
		TYPE_STRING, TYPE_STRING_NAME:
			return _mix(10, hash(String(v)))
		TYPE_ARRAY:
			var h := 11
			for e in v:
				h = _mix(h, of(e, depth + 1))
			return h
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			var h2 := 11
			for e in v:
				h2 = _mix(h2, of(e, depth + 1))
			return h2
		TYPE_PACKED_BYTE_ARRAY:
			return _mix(12, hash(v))
		TYPE_DICTIONARY:
			var sum := 0
			for k in v:
				sum += _mix(of(k, depth + 1), of(v[k], depth + 1))
			return _mix(13, sum) if v.size() > 0 else 13
		TYPE_VECTOR2:
			return _mix(_mix(14, of(v.x)), of(v.y))
		TYPE_VECTOR3:
			return _mix(_mix(_mix(15, of(v.x)), of(v.y)), of(v.z))
		TYPE_COLOR:
			return _mix(_mix(_mix(_mix(16, of(v.r)), of(v.g)), of(v.b)), of(v.a))
		TYPE_VECTOR2I:
			return _mix(_mix(17, v.x), v.y)
	return 0   # объекты и вызовы мир не описывают


# Короткая метка для сети — 32 бита.
static func short(v) -> int:
	var h := of(v)
	return (h ^ (h >> 32)) & 0xFFFFFFFF
