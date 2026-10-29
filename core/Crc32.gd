extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# CRC-32 (IEEE) для кадров рукопожатия и контрольных сумм передачи.

static var _table := PackedInt64Array()


static func _init_table() -> void:
	_table.resize(256)
	for i in 256:
		var c := i
		for _k in 8:
			c = (0xEDB88320 ^ (c >> 1)) if (c & 1) else (c >> 1)
		_table[i] = c


static func of(data: PackedByteArray, from: int = 0, to: int = -1) -> int:
	if _table.is_empty():
		_init_table()
	if to < 0 or to > data.size():
		to = data.size()
	var c := 0xFFFFFFFF
	for i in range(from, to):
		c = _table[(c ^ data[i]) & 0xFF] ^ (c >> 8)
	return c ^ 0xFFFFFFFF
