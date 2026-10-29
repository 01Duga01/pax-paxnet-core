extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# КОДЫ КОМНАТ И ПРИГЛАШЕНИЯ ретранслятора Pax Universe. Код - 4..12 знаков алфавита без похожих букв
# (например «D3EF5YXQ»). Приглашения: https://mp.paxuniverse.ru/j/КОД и paxuniverse://join/КОД - их
# понимает и сама игра. Общий код по сиду: одинаков у всех игроков (комната дня, турнир, сервер мода).

const SharedRng = preload("res://mods/paxnet_core/core/SharedRng.gd")

const CODE_ALPHABET: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const LINK_PREFIX: String = "https://mp.paxuniverse.ru/j/"
const PREFIXES: Array = ["https://mp.paxuniverse.ru/j/", "http://mp.paxuniverse.ru/j/", "mp.paxuniverse.ru/j/",
	"paxuniverse://join/", "pax://join/"]
const MIN_LEN: int = 4
const MAX_LEN: int = 12
## PIN приглашения: 12 знаков секрета (кто вошёл) + 12 знаков отпечатка ключа хоста (кому доверять).
const PIN_SECRET_LEN: int = 12
const PIN_LEN: int = 24


## Код из того, что ввёл игрок: «ABCD2345», «PAX-…», ссылка или paxuniverse://join/КОД. "" - не код.
static func parse_code(s0: String) -> String:
	var s: String = s0.strip_edges().split("#")[0]
	for prefix in PREFIXES:
		var pre: String = str(prefix)
		if s.begins_with(pre):
			s = s.trim_prefix(pre).split("?")[0].split("/")[0]
	var up: String = s.to_upper().replace("PAX-", "").replace("-", "").replace(" ", "")
	if up.length() < MIN_LEN or up.length() > MAX_LEN:
		return ""
	for i in range(up.length()):
		if not CODE_ALPHABET.contains(up[i]):
			return ""
	return up


## PIN приглашения (после «#»): PIN_LEN знаков алфавита кодов. "" - нет или записан неверно.
static func parse_pin(s0: String) -> String:
	var parts: PackedStringArray = s0.strip_edges().split("#")
	if parts.size() < 2:
		return ""
	var up: String = parts[1].to_upper().replace("-", "").replace(" ", "")
	if up.length() != PIN_LEN:
		return ""
	for i in range(up.length()):
		if not CODE_ALPHABET.contains(up[i]):
			return ""
	return up


## Секретная часть PIN (60 бит). Случайность - от системы, не от PCG32 мода.
static func new_secret(random_bytes: PackedByteArray) -> String:
	var s: String = ""
	for i in range(PIN_SECRET_LEN):
		s += CODE_ALPHABET[int(random_bytes[i]) & 31]
	return s


## Ссылка-приглашение. PIN идёт после «#»: на сервер при открытии ссылки в браузере он не попадает.
static func invite_link(code: String, pin: String = "") -> String:
	if code == "":
		return ""
	return LINK_PREFIX + code + (("#" + pin) if pin != "" else "")


## Общий код комнаты: одинаков у всех, у кого совпали seed и stream (PCG32, не зависит от движка).
## prefix - до 4 знаков из алфавита, чтобы коды разных модов не пересекались; всего 8 знаков.
static func shared_code(seed: int, stream: String, prefix: String = "") -> String:
	var r: SharedRng = SharedRng.new()
	r.seed_with(seed, 0, stream)
	var s: String = ""
	for ch in prefix.to_upper().left(4):
		if CODE_ALPHABET.contains(ch):
			s += ch
	while s.length() < 8:
		s += CODE_ALPHABET[r.next_u32() % CODE_ALPHABET.length()]
	return s


## Общее число по сиду (например, сид забега дня): одинаково у всех.
static func shared_seed(seed: int, stream: String) -> int:
	var r: SharedRng = SharedRng.new()
	r.seed_with(seed, 0, stream)
	return int(r.next_u32() & 0x7FFFFFFF)


## Номер дня по UTC: для «комнаты дня» у всех игроков один и тот же.
static func utc_day() -> int:
	return int(Time.get_unix_time_from_system() / 86400.0)
