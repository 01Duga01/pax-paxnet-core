extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ШИФРОВАНИЕ ЗВЕНА. Дёшево и быстро: тяжёлое (RSA-2048) — один раз на вход, всё остальное — AES-256-CBC
# встроенного AESContext (случайный IV на пакет) и HMAC-SHA256, которым звено и так подписано.
#
#   хост    : RSA-пара на процесс; открытый ключ едет в CHALLENGE;
#   гость   : случайный секрет на 32 байта, шлёт его хосту под RSA; из секрета — ключ звена и ключ рукопожатия;
#   дальше  : info (ключ игрока, имя) и welcome шифруются секретом, пакеты звена — AES-CBC + подпись (шифруй, потом подписывай).
#
# Ретранслятор и сеть между сторонами видят только шифртекст. Против того, кто ПОДМЕНЯЕТ открытый ключ на лету
# (активный посредник), защиты нет: у сторон нет заранее известного общего секрета, а код комнаты знает и ретранслятор.

const Hmac = preload("res://mods/paxnet/core/Hmac.gd")

const BLOCK := 16
const RSA_BITS := 2048
const SECRET_LEN := 32
const MAC_LEN := 16

static var _host_key: CryptoKey = null
static var _rng: Crypto = Crypto.new()


## Ключевая пара хоста (одна на процесс: генерация RSA дорогая).
static func host_key() -> CryptoKey:
	if _host_key == null:
		_host_key = _rng.generate_rsa(RSA_BITS)
	return _host_key


static func public_pem(k: CryptoKey) -> PackedByteArray:
	return k.save_to_string(true).to_utf8_buffer()


static func random_bytes(n: int) -> PackedByteArray:
	return _rng.generate_random_bytes(n)


## Секрет гостя под открытый ключ хоста. Пусто — ключ не разобрался.
static func wrap_secret(pem: PackedByteArray, secret: PackedByteArray) -> PackedByteArray:
	var k := CryptoKey.new()
	if k.load_from_string(pem.get_string_from_utf8(), true) != OK:
		return PackedByteArray()
	return _rng.encrypt(k, secret)


## Хост достаёт секрет. Пусто — мусор или чужой ключ.
static func unwrap_secret(k: CryptoKey, wrapped: PackedByteArray) -> PackedByteArray:
	if wrapped.is_empty() or wrapped.size() > 512:
		return PackedByteArray()
	var s: PackedByteArray = _rng.decrypt(k, wrapped)
	return s if s.size() == SECRET_LEN else PackedByteArray()


static func derive(key: PackedByteArray, label: String) -> PackedByteArray:
	return Hmac.mac(key, label.to_utf8_buffer())


# ------------------------------------------------------------------ AES-CBC

## [IV 16][шифртекст]; дополнение PKCS7 (1..16 байт).
static func seal(enc_key: PackedByteArray, plain: PackedByteArray) -> PackedByteArray:
	var pad: int = BLOCK - plain.size() % BLOCK
	var data: PackedByteArray = plain.duplicate()
	var n: int = data.size()
	data.resize(n + pad)
	for i in pad:
		data[n + i] = pad
	var iv: PackedByteArray = _rng.generate_random_bytes(BLOCK)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, enc_key, iv)
	var ct: PackedByteArray = aes.update(data)
	aes.finish()
	var out: PackedByteArray = iv
	out.append_array(ct)
	return out


## Обратно; null — размер или дополнение неверны (подпись проверяют до вызова).
static func open(enc_key: PackedByteArray, sealed: PackedByteArray) -> Variant:
	if sealed.size() < 2 * BLOCK or sealed.size() % BLOCK != 0:
		return null
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, enc_key, sealed.slice(0, BLOCK))
	var data: PackedByteArray = aes.update(sealed.slice(BLOCK))
	aes.finish()
	var pad: int = data[data.size() - 1]
	if pad < 1 or pad > BLOCK or pad > data.size():
		return null
	return data.slice(0, data.size() - pad)


## Шифр + подпись для коротких блоков рукопожатия (info, welcome).
static func seal_mac(secret: PackedByteArray, label: String, plain: PackedByteArray) -> PackedByteArray:
	var out: PackedByteArray = seal(derive(secret, label + "-enc"), plain)
	out.append_array(Hmac.tag(derive(secret, label + "-mac"), out, MAC_LEN))
	return out


static func open_mac(secret: PackedByteArray, label: String, blob: PackedByteArray) -> Variant:
	if blob.size() < 2 * BLOCK + MAC_LEN:
		return null
	var body: PackedByteArray = blob.slice(0, blob.size() - MAC_LEN)
	if not Hmac.equal(Hmac.tag(derive(secret, label + "-mac"), body, MAC_LEN), blob.slice(blob.size() - MAC_LEN)):
		return null
	return open(derive(secret, label + "-enc"), body)
