extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Большие надёжные сообщения (лобби со списком стран, малые лечебные куски мира) режутся на
# части по порядку; соединение надёжное и упорядоченное, поэтому собрать их просто.

const Bytes = preload("res://mods/paxnet/core/Bytes.gd")
const Proto = preload("res://mods/paxnet/core/Proto.gd")

static var _next_id := 1

var _mid := -1
var _type := 0
var _parts: Array = []
var _n := 0


static func send(link, type: int, body: PackedByteArray) -> bool:
	var room: int = link.max_message()
	if body.size() <= room - 2:
		return link.send_reliable(type, body)
	var chunk := room - 24
	var n := int(ceil(float(body.size()) / float(chunk)))
	if n > 4096:
		return false
	var mid := _next_id
	_next_id += 1
	for i in n:
		var w := Bytes.W.new().varint(mid).varint(i).varint(n).u8(type).raw(body.slice(i * chunk, mini((i + 1) * chunk, body.size())))
		link.send_reliable(Proto.M_FRAG, w.buf)
	return true


# Кусок пришёл. Возвращает [] пока не всё; иначе [type, body].
func feed(body: PackedByteArray) -> Array:
	var r := Bytes.R.new(body)
	var mid := r.varint()
	var i := r.varint()
	var n := r.varint()
	var type := r.u8()
	if not r.ok or n <= 0 or n > 4096 or i >= n:
		return []
	if mid != _mid:
		_mid = mid
		_type = type
		_n = n
		_parts = []
	if i != _parts.size():
		_mid = -1
		return []   # порядок гарантирует звено; иначе — мусор
	_parts.append(r.rest())
	if _parts.size() < _n:
		return []
	var all := PackedByteArray()
	for p in _parts:
		all.append_array(p)
	_mid = -1
	_parts = []
	return [_type, all]
