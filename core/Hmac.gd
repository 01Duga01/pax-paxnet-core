extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# HMAC-SHA256 на HashingContext: подпись пакетов и cookie рукопожатия. Шифрования нет — только
# защита от чужих (не с пути пакета) подделок.

const BLOCK := 64


static func _sha(data: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(data)
	return h.finish()


static func mac(key: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	if key.size() > BLOCK:
		key = _sha(key)
	var k := key.duplicate()
	k.resize(BLOCK)   # добивается нулями
	var ipad := PackedByteArray()
	var opad := PackedByteArray()
	ipad.resize(BLOCK)
	opad.resize(BLOCK)
	for i in BLOCK:
		ipad[i] = k[i] ^ 0x36
		opad[i] = k[i] ^ 0x5C
	ipad.append_array(data)
	var inner := _sha(ipad)
	opad.append_array(inner)
	return _sha(opad)


# Первые n байт подписи.
static func tag(key: PackedByteArray, data: PackedByteArray, n: int = 8) -> PackedByteArray:
	return mac(key, data).slice(0, n)


static func equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var d := 0
	for i in a.size():
		d |= a[i] ^ b[i]
	return d == 0
