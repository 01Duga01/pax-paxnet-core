extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Двоичный кодек протокола: varint, строки, значения Variant в компактном виде.
# Свой, а не var_to_bytes: размер известен, глубина и объём ограничены (данные приходят от чужих
# игроков), объекты и скрипты не декодируются никогда.

const MAX_DEPTH := 48
## Значение FileAccess.COMPRESSION_ZSTD: числом, чтобы код не упоминал FileAccess (песочница модов).
const ZSTD := 2
## Значение FileAccess.COMPRESSION_DEFLATE.
const DEFLATE := 1
const T_NIL := 0
const T_FALSE := 1
const T_TRUE := 2
const T_INT := 3
const T_FLOAT := 4
const T_STR := 5
const T_BYTES := 6
const T_ARRAY := 7
const T_DICT := 8
const T_V2 := 9
const T_V3 := 10
const T_COLOR := 11
const T_V2I := 12


class W extends RefCounted:
	var buf := PackedByteArray()

	func size() -> int:
		return buf.size()

	func u8(v: int) -> W:
		buf.append(v & 0xFF)
		return self

	func u16(v: int) -> W:
		buf.append(v & 0xFF)
		buf.append((v >> 8) & 0xFF)
		return self

	func u32(v: int) -> W:
		var n := buf.size()
		buf.resize(n + 4)
		buf.encode_u32(n, v & 0xFFFFFFFF)
		return self

	func u64(v: int) -> W:
		var n := buf.size()
		buf.resize(n + 8)
		buf.encode_s64(n, v)
		return self

	func f32(v: float) -> W:
		var n := buf.size()
		buf.resize(n + 4)
		buf.encode_float(n, v)
		return self

	func f64(v: float) -> W:
		var n := buf.size()
		buf.resize(n + 8)
		buf.encode_double(n, v)
		return self

	# Беззнаковое число до 63 бит; отрицательное считается нулём.
	func varint(v: int) -> W:
		if v < 0:
			v = 0
		while v >= 0x80:
			buf.append((v & 0x7F) | 0x80)
			v >>= 7
		buf.append(v)
		return self

	func svarint(v: int) -> W:
		return varint((v << 1) if v >= 0 else (((-v - 1) << 1) | 1))

	func text(s: String) -> W:
		var b := s.to_utf8_buffer()
		varint(b.size())
		buf.append_array(b)
		return self

	func bytes(b: PackedByteArray) -> W:
		varint(b.size())
		buf.append_array(b)
		return self

	func raw(b: PackedByteArray) -> W:
		buf.append_array(b)
		return self

	func variant(v, depth: int = 0) -> W:
		if depth >= MAX_DEPTH:
			u8(T_NIL)
			return self
		match typeof(v):
			TYPE_NIL:
				u8(T_NIL)
			TYPE_BOOL:
				u8(T_TRUE if v else T_FALSE)
			TYPE_INT:
				u8(T_INT)
				svarint(v)
			TYPE_FLOAT:
				u8(T_FLOAT)
				f64(v)
			TYPE_STRING, TYPE_STRING_NAME:
				u8(T_STR)
				text(String(v))
			TYPE_PACKED_BYTE_ARRAY:
				u8(T_BYTES)
				bytes(v)
			TYPE_ARRAY:
				u8(T_ARRAY)
				varint((v as Array).size())
				for e in v:
					variant(e, depth + 1)
			TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
			TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
				u8(T_ARRAY)
				varint(v.size())
				for e in v:
					variant(e, depth + 1)
			TYPE_DICTIONARY:
				u8(T_DICT)
				varint((v as Dictionary).size())
				for k in v:
					variant(k, depth + 1)
					variant(v[k], depth + 1)
			TYPE_VECTOR2:
				u8(T_V2)
				f32(v.x)
				f32(v.y)
			TYPE_VECTOR3:
				u8(T_V3)
				f32(v.x)
				f32(v.y)
				f32(v.z)
			TYPE_COLOR:
				u8(T_COLOR)
				f32(v.r)
				f32(v.g)
				f32(v.b)
				f32(v.a)
			TYPE_VECTOR2I:
				u8(T_V2I)
				svarint(v.x)
				svarint(v.y)
			_:
				u8(T_NIL)   # объекты, вызовы, узлы по сети не ходят
		return self


class R extends RefCounted:
	var buf: PackedByteArray
	var pos := 0
	var ok := true
	var nodes_left := -1            # бюджет разбора значений; -1 - без предела

	func _init(b: PackedByteArray = PackedByteArray(), start: int = 0) -> void:
		buf = b
		pos = start

	func left() -> int:
		return buf.size() - pos

	func _need(n: int) -> bool:
		if n < 0 or pos + n > buf.size():
			ok = false
			return false
		return true

	func u8() -> int:
		if not _need(1):
			return 0
		pos += 1
		return buf[pos - 1]

	func u16() -> int:
		if not _need(2):
			return 0
		pos += 2
		return buf[pos - 2] | (buf[pos - 1] << 8)

	func u32() -> int:
		if not _need(4):
			return 0
		pos += 4
		return buf.decode_u32(pos - 4)

	func u64() -> int:
		if not _need(8):
			return 0
		pos += 8
		return buf.decode_s64(pos - 8)

	func f32() -> float:
		if not _need(4):
			return 0.0
		pos += 4
		return buf.decode_float(pos - 4)

	func f64() -> float:
		if not _need(8):
			return 0.0
		pos += 8
		return buf.decode_double(pos - 8)

	func varint() -> int:
		var v := 0
		var shift := 0
		while true:
			if not _need(1) or shift > 63:
				ok = false
				return 0
			var b: int = buf[pos]
			pos += 1
			v |= (b & 0x7F) << shift
			if b < 0x80:
				break
			shift += 7
		return v

	func svarint() -> int:
		var u := varint()
		if u & 1:
			return -((u >> 1) & 0x3FFFFFFFFFFFFFFF) - 1
		return (u >> 1) & 0x3FFFFFFFFFFFFFFF

	func text() -> String:
		var n := varint()
		if not _need(n):
			return ""
		var raw := buf.slice(pos, pos + n)
		pos += n
		if not R._valid_utf8(raw):
			ok = false
			return ""
		return raw.get_string_from_utf8()

	func bytes() -> PackedByteArray:
		var n := varint()
		if not _need(n):
			return PackedByteArray()
		var b := buf.slice(pos, pos + n)
		pos += n
		return b

	# Допустимый UTF-8 без изысков: чужие байты не должны сыпать ошибки в журнал движка.
	static func _valid_utf8(b: PackedByteArray) -> bool:
		var i := 0
		var n := b.size()
		while i < n:
			var c: int = b[i]
			var extra := 0
			if c < 0x80:
				extra = 0
			elif c >= 0xC2 and c < 0xE0:
				extra = 1
			elif c >= 0xE0 and c < 0xF0:
				extra = 2
			elif c >= 0xF0 and c < 0xF5:
				extra = 3
			else:
				return false
			if i + extra > n - 1:
				return false
			for k in range(1, extra + 1):
				if (b[i + k] & 0xC0) != 0x80:
					return false
			i += extra + 1
		return true

	func raw_n(n: int) -> PackedByteArray:
		if not _need(n):
			return PackedByteArray()
		var b := buf.slice(pos, pos + n)
		pos += n
		return b

	func rest() -> PackedByteArray:
		var b := buf.slice(pos)
		pos = buf.size()
		return b

	func variant(depth: int = 0):
		if depth > MAX_DEPTH:
			ok = false
			return null
		if nodes_left >= 0:
			nodes_left -= 1
			if nodes_left < 0:
				ok = false
				return null
		var t := u8()
		if not ok:
			return null
		match t:
			T_NIL:
				return null
			T_FALSE:
				return false
			T_TRUE:
				return true
			T_INT:
				return svarint()
			T_FLOAT:
				return f64()
			T_STR:
				return text()
			T_BYTES:
				return bytes()
			T_ARRAY:
				var n := varint()
				if n > left():   # каждый элемент — минимум байт: защита от выдуманных длин
					ok = false
					return null
				var a := []
				a.resize(n)
				for i in n:
					a[i] = variant(depth + 1)
					if not ok:
						return null
				return a
			T_DICT:
				var n2 := varint()
				if n2 * 2 > left():
					ok = false
					return null
				var d := {}
				for i in n2:
					var k = variant(depth + 1)
					var v = variant(depth + 1)
					if not ok:
						return null
					d[k] = v
				return d
			T_V2:
				return Vector2(f32(), f32())
			T_V3:
				return Vector3(f32(), f32(), f32())
			T_COLOR:
				return Color(f32(), f32(), f32(), f32())
			T_V2I:
				return Vector2i(svarint(), svarint())
		ok = false
		return null


static func encode(v) -> PackedByteArray:
	return W.new().variant(v).buf


# Возвращает {"ok": bool, "v": значение}. Мусор от сети не должен ронять приём.
# max_nodes - сколько значений (элементов, ключей) разрешено разобрать; -1 без предела. Для сообщений от гостей
# предел обязателен: стоимость разбора считается по элементам, а не по байтам.
static func decode(b: PackedByteArray, max_nodes: int = -1) -> Dictionary:
	var r := R.new(b)
	r.nodes_left = max_nodes
	var v = r.variant()
	return {"ok": r.ok and r.left() == 0, "v": v}
