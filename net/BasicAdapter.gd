extends "res://mods/paxnet/core/Adapter.gd"
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# АДАПТЕР БЕЗ МИРА: для модов, которым нужны только лобби, состав, чат, время и сообщения
# (ровно один раз, через обрывы). Мира для сверки нет; «передача мира» при старте пустая и всегда
# удаётся. Свой мир - наследуйте core/Adapter.gd (контракт в его комментариях).

## Страны/места лобби: [{id, name}]. Пусто - места не выбираются.
var seat_list: Array = []


func countries() -> Array:
	return seat_list


func install_world(_bytes: PackedByteArray) -> bool:
	return true
