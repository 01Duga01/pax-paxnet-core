extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# HMAC-SHA256: подпись пакетов и cookie рукопожатия (шифр пакетов - в Cipher.gd).

const BLOCK := 64


static func _sha(data: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(data)
	return h.finish()


static var _crypto: Crypto = Crypto.new()


# HMAC-SHA256 встроенной функцией движка (в разы быстрее своей на GDScript и не усиливает перегрузку хоста).
static func mac(key: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, key, data)


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
