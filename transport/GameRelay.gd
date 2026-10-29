extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
## Прямой вызов ретранслятора игры - так, как его описывает чейнджлог Pax Universe 0.32.4:
## «Network.relay_pipe(): наш ретранслятор как готовый канал пакетов для своей сетевой игры».
## Network может быть и автозагрузкой с другим путём в дереве, и глобальным классом со static-методом -
## по имени Network доступно и то и другое. Файл отдельный и грузится через load(): если в игре
## имени Network нет, не компилируется только он, а мод работает дальше и пишет понятную ошибку.


## Объект Network (узел-автозагрузка или класс).
static func target() -> Variant:
	return Network


## Через call(): если relay_pipe() ждёт внутри (корутина), прямой вызов без await не компилируется,
## а call() отдаёт «обещание», которое RelayPipe дождётся сам.
static func open(first: Dictionary) -> Variant:
	var t: Variant = Network
	return (t as Object).call("relay_pipe", first)
