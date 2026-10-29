extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# КОДЫ КОМНАТ И ПРИГЛАШЕНИЯ ретранслятора Pax Universe. Код - 4..12 знаков алфавита без похожих букв
# (например «D3EF5YXQ»). Приглашения: https://mp.paxuniverse.ru/j/КОД и paxuniverse://join/КОД - их
# понимает и сама игра. Общий код по сиду: одинаков у всех игроков (комната дня, турнир, сервер мода).

const SharedRng = preload("res://mods/paxnet/core/SharedRng.gd")

const CODE_ALPHABET: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const LINK_PREFIX: String = "https://mp.paxuniverse.ru/j/"
const PREFIXES: Array = ["https://mp.paxuniverse.ru/j/", "http://mp.paxuniverse.ru/j/", "mp.paxuniverse.ru/j/",
	"paxuniverse://join/", "pax://join/"]
const MIN_LEN: int = 4
const MAX_LEN: int = 12


## Код из того, что ввёл игрок: «ABCD2345», «PAX-…», ссылка или paxuniverse://join/КОД. "" - не код.
static func parse_code(s0: String) -> String:
	var s: String = s0.strip_edges()
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


static func invite_link(code: String) -> String:
	return (LINK_PREFIX + code) if code != "" else ""


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
