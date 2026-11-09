extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Двоичный кодек протокола: varint, строки, значения Variant в компактном виде.
# Свой, а не var_to_bytes: размер известен, глубина и объём ограничены (данные приходят от чужих
# игроков), объекты и скрипты не декодируются никогда.
#
# Скорость: горячий путь развёрнут по месту без промежуточных вызовов (u8/varint/f64), а разбор
# типа идёт цепочкой if, а не match: на этом движке match по typeof стоит ~0.6 мкс, цепочка if ~0.1.
# Формат байт не меняется ни на байт.

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
		var n := buf.size()
		buf.resize(n + 2)
		buf.encode_u16(n, v & 0xFFFF)
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
			buf.append(T_NIL)
			return self
		var t := typeof(v)
		if t == TYPE_INT:
			buf.append(T_INT)
			var x: int = v
			if x < 0:                       # зигзаг, как в svarint(); переполнение — ноль
				x = ((-x - 1) << 1) | 1
			else:
				x = x << 1
			if x < 0:
				x = 0
			while x >= 0x80:
				buf.append((x & 0x7F) | 0x80)
				x >>= 7
			buf.append(x)
		elif t == TYPE_STRING:
			buf.append(T_STR)
			var b := (v as String).to_utf8_buffer()
			var n := b.size()
			while n >= 0x80:
				buf.append((n & 0x7F) | 0x80)
				n >>= 7
			buf.append(n)
			buf.append_array(b)
		elif t == TYPE_FLOAT:
			var n := buf.size()
			buf.resize(n + 9)
			buf[n] = T_FLOAT
			buf.encode_double(n + 1, v)
		elif t == TYPE_DICTIONARY:
			buf.append(T_DICT)
			var d: Dictionary = v
			varint(d.size())
			for k in d:
				variant(k, depth + 1)
				variant(d[k], depth + 1)
		elif t == TYPE_ARRAY:
			buf.append(T_ARRAY)
			var a: Array = v
			varint(a.size())
			for e in a:
				variant(e, depth + 1)
		elif t == TYPE_BOOL:
			buf.append(T_TRUE if v else T_FALSE)
		elif t == TYPE_NIL:
			buf.append(T_NIL)
		elif t == TYPE_STRING_NAME:
			buf.append(T_STR)
			var b2 := String(v).to_utf8_buffer()
			var n2 := b2.size()
			while n2 >= 0x80:
				buf.append((n2 & 0x7F) | 0x80)
				n2 >>= 7
			buf.append(n2)
			buf.append_array(b2)
		elif t == TYPE_PACKED_BYTE_ARRAY:
			buf.append(T_BYTES)
			var bb: PackedByteArray = v
			varint(bb.size())
			buf.append_array(bb)
		elif t == TYPE_VECTOR2:
			var n := buf.size()
			buf.resize(n + 9)
			buf[n] = T_V2
			buf.encode_float(n + 1, v.x)
			buf.encode_float(n + 5, v.y)
		elif t == TYPE_VECTOR3:
			var n := buf.size()
			buf.resize(n + 13)
			buf[n] = T_V3
			buf.encode_float(n + 1, v.x)
			buf.encode_float(n + 5, v.y)
			buf.encode_float(n + 9, v.z)
		elif t == TYPE_COLOR:
			var n := buf.size()
			buf.resize(n + 17)
			buf[n] = T_COLOR
			buf.encode_float(n + 1, v.r)
			buf.encode_float(n + 5, v.g)
			buf.encode_float(n + 9, v.b)
			buf.encode_float(n + 13, v.a)
		elif t == TYPE_PACKED_INT32_ARRAY or t == TYPE_PACKED_INT64_ARRAY \
				or t == TYPE_PACKED_STRING_ARRAY or t == TYPE_PACKED_FLOAT32_ARRAY \
				or t == TYPE_PACKED_FLOAT64_ARRAY:
			buf.append(T_ARRAY)
			varint(v.size())
			for e in v:
				variant(e, depth + 1)
		elif t == TYPE_VECTOR2I:
			buf.append(T_V2I)
			_v2i_field(v.x)
			_v2i_field(v.y)
		else:
			buf.append(T_NIL)   # объекты, вызовы, узлы по сети не ходят
		return self

	# Одно поле Vector2i: зигзаг + varint.
	func _v2i_field(x: int) -> void:
		if x < 0:
			x = ((-x - 1) << 1) | 1
		else:
			x = x << 1
		if x < 0:
			x = 0
		while x >= 0x80:
			buf.append((x & 0x7F) | 0x80)
			x >>= 7
		buf.append(x)


class R extends RefCounted:
	var buf: PackedByteArray
	var pos := 0
	var ok := true
	var nodes_left := -1            # бюджет разбора значений; -1 - без предела
	var _size := 0                  # buf.size() кэширован: горячий цикл не дёргает движок

	func _init(b: PackedByteArray = PackedByteArray(), start: int = 0) -> void:
		buf = b
		pos = start
		_size = b.size()

	func left() -> int:
		return _size - pos

	func _need(n: int) -> bool:
		if n < 0 or pos + n > _size:
			ok = false
			return false
		return true

	func u8() -> int:
		if pos >= _size:
			ok = false
			return 0
		var v: int = buf[pos]
		pos += 1
		return v

	func u16() -> int:
		if pos + 2 > _size:
			ok = false
			return 0
		var v: int = buf[pos] | (buf[pos + 1] << 8)
		pos += 2
		return v

	func u32() -> int:
		if pos + 4 > _size:
			ok = false
			return 0
		var v: int = buf.decode_u32(pos)
		pos += 4
		return v

	func u64() -> int:
		if pos + 8 > _size:
			ok = false
			return 0
		var v: int = buf.decode_s64(pos)
		pos += 8
		return v

	func f32() -> float:
		if pos + 4 > _size:
			ok = false
			return 0.0
		var v: float = buf.decode_float(pos)
		pos += 4
		return v

	func f64() -> float:
		if pos + 8 > _size:
			ok = false
			return 0.0
		var v: float = buf.decode_double(pos)
		pos += 8
		return v

	func varint() -> int:
		var v := 0
		var shift := 0
		var p := pos
		while true:
			if p >= _size or shift > 63:
				ok = false
				pos = p
				return 0
			var b: int = buf[p]
			p += 1
			v |= (b & 0x7F) << shift
			if b < 0x80:
				break
			shift += 7
		pos = p
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
	# Развёрнуто по длине последовательности: range() в цикле стоит дороже самих проверок.
	static func _valid_utf8(b: PackedByteArray) -> bool:
		var n := b.size()
		var i := 0
		while i < n:
			var c: int = b[i]
			if c < 0x80:
				i += 1
				continue
			if c < 0xC2:
				return false
			if c < 0xE0:
				if i + 2 > n or (b[i + 1] & 0xC0) != 0x80:
					return false
				i += 2
			elif c < 0xF0:
				if i + 3 > n or (b[i + 1] & 0xC0) != 0x80 or (b[i + 2] & 0xC0) != 0x80:
					return false
				i += 3
			elif c < 0xF5:
				if i + 4 > n or (b[i + 1] & 0xC0) != 0x80 or (b[i + 2] & 0xC0) != 0x80 \
						or (b[i + 3] & 0xC0) != 0x80:
					return false
				i += 4
			else:
				return false
		return true

	func raw_n(n: int) -> PackedByteArray:
		if not _need(n):
			return PackedByteArray()
		var b := buf.slice(pos, pos + n)
		pos += n
		return b

	func rest() -> PackedByteArray:
		var b := buf.slice(pos)
		pos = _size
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
		var p := pos
		if p >= _size:
			ok = false
			return null
		var t: int = buf[p]
		p += 1
		if t == T_INT:
			# varint + зигзаг без вызова svarint()
			var v := 0
			var shift := 0
			while true:
				if p >= _size or shift > 63:
					ok = false
					pos = p
					return 0
				var b: int = buf[p]
				p += 1
				v |= (b & 0x7F) << shift
				if b < 0x80:
					break
				shift += 7
			pos = p
			if v & 1:
				return -((v >> 1) & 0x3FFFFFFFFFFFFFFF) - 1
			return (v >> 1) & 0x3FFFFFFFFFFFFFFF
		if t == T_STR:
			# varint + slice + проверка + сборка String одним куском, без вызовов text()/varint()
			var n := 0
			var shift := 0
			while true:
				if p >= _size or shift > 63:
					ok = false
					pos = p
					return ""
				var bb: int = buf[p]
				p += 1
				n |= (bb & 0x7F) << shift
				if bb < 0x80:
					break
				shift += 7
			if n < 0 or p + n > _size:
				ok = false
				pos = p
				return ""
			var raw := buf.slice(p, p + n)
			p += n
			pos = p
			if not _valid_utf8(raw):
				ok = false
				return ""
			return raw.get_string_from_utf8()
		if t == T_NIL:
			pos = p
			return null
		if t == T_DICT:
			pos = p
			var n2 := varint()
			if n2 * 2 > left():
				ok = false
				return null
			var d := {}
			for i in n2:
				var k = variant(depth + 1)
				var val = variant(depth + 1)
				if not ok:
					return null
				d[k] = val
			return d
		if t == T_ARRAY:
			pos = p
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
		if t == T_FLOAT:
			if p + 8 > _size:
				ok = false
				pos = p
				return 0.0
			var f: float = buf.decode_double(p)
			pos = p + 8
			return f
		if t == T_TRUE:
			pos = p
			return true
		if t == T_FALSE:
			pos = p
			return false
		if t == T_BYTES:
			pos = p
			return bytes()
		if t == T_V2:
			var x := 0.0
			var y := 0.0
			if p + 4 <= _size:
				x = buf.decode_float(p)
				p += 4
				if p + 4 <= _size:
					y = buf.decode_float(p)
					p += 4
				else:
					ok = false
			else:
				ok = false
			pos = p
			return Vector2(x, y)
		if t == T_V3:
			var x3 := 0.0
			var y3 := 0.0
			var z3 := 0.0
			if p + 4 <= _size:
				x3 = buf.decode_float(p)
				p += 4
				if p + 4 <= _size:
					y3 = buf.decode_float(p)
					p += 4
					if p + 4 <= _size:
						z3 = buf.decode_float(p)
						p += 4
					else:
						ok = false
				else:
					ok = false
			else:
				ok = false
			pos = p
			return Vector3(x3, y3, z3)
		if t == T_COLOR:
			var r := 0.0
			var g := 0.0
			var bl := 0.0
			var al := 0.0
			if p + 4 <= _size:
				r = buf.decode_float(p)
				p += 4
				if p + 4 <= _size:
					g = buf.decode_float(p)
					p += 4
					if p + 4 <= _size:
						bl = buf.decode_float(p)
						p += 4
						if p + 4 <= _size:
							al = buf.decode_float(p)
							p += 4
						else:
							ok = false
					else:
						ok = false
				else:
					ok = false
			else:
				ok = false
			pos = p
			return Color(r, g, bl, al)
		if t == T_V2I:
			pos = p
			var ax := svarint()
			var ay := svarint()
			return Vector2i(ax, ay)
		ok = false
		pos = p
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
