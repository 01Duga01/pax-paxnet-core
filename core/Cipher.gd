extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ШИФРОВАНИЕ ЗВЕНА. Дёшево и быстро: тяжёлое (RSA-1024) — один раз на вход, всё остальное — AES-128-CBC
# встроенного AESContext (случайный IV на пакет) и HMAC-SHA256, которым звено и так подписано.
#
#   хост    : RSA-1024 (ключ живёт один процесс, нужен на часы, не на годы), пара на процесс; открытый ключ едет в CHALLENGE;
#   гость   : случайный секрет на 32 байта, шлёт его хосту под RSA; из секрета — ключ звена и ключ рукопожатия;
#   дальше  : info (ключ игрока, имя) и welcome шифруются секретом, пакеты звена — AES-CBC + подпись (шифруй, потом подписывай).
#
# Ретранслятор и сеть между сторонами видят только шифртекст. От посредника, подменяющего открытый ключ на лету,
# защищает PIN приглашения (12 знаков, 60 бит): он есть у хоста и приглашённых, но не уходит на ретранслятор.
# Секрет гостя «привязывается» к PIN (bind) до выводa всех ключей. Комнаты без PIN (общий код по сиду) от
# активного посредника не защищены — секретом поделиться нечем.

const Hmac = preload("res://mods/paxnet_core/core/Hmac.gd")

const BLOCK := 16
const RSA_BITS := 1024
const KEY_LEN := 16              # AES-128
const SECRET_LEN := 32
const MAC_LEN := 16

static var _host_key: CryptoKey = null
static var _rng: Crypto = Crypto.new()


## Ключевая пара хоста (одна на процесс: генерация RSA дорогая).
static func host_key() -> CryptoKey:
	if _host_key == null:
		_host_key = _rng.generate_rsa(RSA_BITS)
	return _host_key


const FP_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const FP_LEN := 12


## Отпечаток открытого ключа хоста (60 бит, знаки алфавита кодов). Едет в приглашении: гость сверяет ключ хоста,
## поэтому ретранслятор не может подставить свой ключ, а перебирать PIN по перехваченным данным нечем.
static func fingerprint(pem: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(pem)
	var d: PackedByteArray = h.finish()
	var s := ""
	for i in FP_LEN:
		s += FP_ALPHABET[int(d[i]) & 31]
	return s


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


## Секрет, привязанный к PIN приглашения. PIN не уходит ни на ретранслятор, ни в сеть: кто подменил открытый
## ключ, PIN не знает и не может ни прочитать, ни подписать ничего. Пустой PIN — без защиты от активного посредника.
static func bind(secret: PackedByteArray, pin: String) -> PackedByteArray:
	if pin == "":
		return secret
	return Hmac.mac(secret, ("pax-pin|" + pin).to_utf8_buffer())


static func derive(key: PackedByteArray, label: String) -> PackedByteArray:
	return Hmac.mac(key, label.to_utf8_buffer())


## Ключ AES-128 из ключа звена или секрета.
static func derive_aes(key: PackedByteArray, label: String) -> PackedByteArray:
	return derive(key, label).slice(0, KEY_LEN)


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
	var out: PackedByteArray = seal(derive_aes(secret, label + "-enc"), plain)
	out.append_array(Hmac.tag(derive(secret, label + "-mac"), out, MAC_LEN))
	return out


static func open_mac(secret: PackedByteArray, label: String, blob: PackedByteArray) -> Variant:
	if blob.size() < 2 * BLOCK + MAC_LEN:
		return null
	var body: PackedByteArray = blob.slice(0, blob.size() - MAC_LEN)
	if not Hmac.equal(Hmac.tag(derive(secret, label + "-mac"), body, MAC_LEN), blob.slice(blob.size() - MAC_LEN)):
		return null
	return open(derive_aes(secret, label + "-enc"), body)
