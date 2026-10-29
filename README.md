# PaxNet — мод-библиотека сетевой игры для Pax Universe

https://paxnet.isroot.in/

Сетевое ядро PaxNet (`pax_netcode`), переделанное под песочницу модов и оформленное как библиотека.
Другие моды берут из неё комнаты, лобби, сообщения и синхронизацию мира. Сама библиотека игру не
меняет: партию открывает мод, которому она нужна.

- **Комнаты** на ретрансляторе игры: код (`D3EF5YXQ`), ссылка `https://mp.paxuniverse.ru/j/КОД`,
  `paxuniverse://join/КОД`. Порт, роутер и VPN не нужны.
- **Лобби**: места и соправители, готовность, правила, чат, выгнать игрока.
- **Время партии**: пауза и скорость. Решает хост или голосование; видно, кто поставил паузу.
- **Сообщения мода** доходят ровно один раз и по порядку, даже через обрыв связи. Крупные
  сообщения сжимаются и идут частями.
- **Переподключение тем же игроком**: короткий обрыв канала незаметен, звено продолжается по
  подписи. После долгого обрыва или перезапуска игрок возвращается на своё место, а мир досылается.
- **Одна правда о мире**: шаги хоста идут по порядку, сверка по суммам разделов, тихое лечение
  только разошедшихся разделов, передача мира без остановки игры.
- **Общий счётчик случайностей** (PCG32) и **общий код комнаты** по сиду. Они одинаковы у всех
  игроков на любой машине.

Лицензия — **Mozilla Public License 2.0** (файл `LICENSE`). В начале каждого файла кода стоит
уведомление MPL. Изменённые файлы библиотеки распространяются под MPL 2.0. Ваш мод, который
только использует библиотеку, может иметь любую лицензию.

## Подключение к своему моду

`mod.json` вашего мода:

```json
"depends": ["paxnet_core"]
```

Библиотека создаёт узел `/root/PaxNetLib`. Ещё до входа узла в дерево он доступен через метаданные
корня, поэтому его можно брать уже в `_mod_loaded`:

```gdscript
extends PaxMod

var net: Node = null

func _world_ready(game: PaxGame) -> void:
	var lib: Node = Pax.get_tree().root.get_meta("paxnet_lib", null)
	if lib == null:
		log_warning("PaxNet library is not enabled")
		return
	net = lib.call("new_session")
	net.connect("message", _on_net)
	net.connect("changed", _on_net_changed)
	net.connect("failed", func(code: String) -> void: game.toast(tr_key("paxnet_err_" + code)))

func host_game() -> void:
	var err: String = str(net.call("host", "Имя игрока", null, {"max_players": 4}))
	# код и приглашение появятся, когда статус станет "lobby": net.code(), net.invite_link()

func join_game(code_or_link: String) -> void:
	net.call("join", code_or_link, "Имя игрока")

func _on_net(from_id: int, type: String, data: Variant) -> void:
	if type == "my_mod.move":
		pass   # from_id: 1 - хост, 2.. - гости

func shoot() -> void:
	net.call("broadcast", "my_mod.move", {"x": 10, "y": 20})   # всем, кроме себя
```

Свои `preload` чужих файлов не нужны: песочница пускает `load()`/`preload()` только с путём своего
мода. Любой скрипт библиотеки отдаёт `lib.script_of("Имя")` — `Bytes`, `SharedRng`, `StateHash`,
`Delta`, `Crc32`, `Hmac`, `Adapter`, `BasicAdapter`, `HostSession`, `GuestSession`, `Mailbox`,
`TimeAuthority`, `Relay`, `RelayPipe`, `PipeHost`, `PipeGuest`, `Session`, `NetOverlay` — для `new()` и
статических функций.

Свой мир для сверки — объект-адаптер. Сессия зовёт его методы по имени, поэтому наследовать
`core/Adapter.gd` не обязательно. Скопируйте в свой мод набор методов из его контракта: разделы,
суммы, данные разделов, применение, снимок мира, страны, вывод игроку. Пустые реализации там уже
написаны.

### API узла `PaxNetLib`

| Метод | Что делает |
|---|---|
| `new_session(parent = null) -> Node` | новая партия (`net/Session.gd`); ключ игрока общий для всех модов |
| `world_service() -> Node` | партия в мире самой игры (стратегия): `game/NetService.gd` + `GameAdapter` |
| `overlay(session, parent) -> CanvasLayer` | строка состояния, полоса передачи, понятная ошибка с кнопкой |
| `open_pipe(first) -> Object` | голый канал ретранслятора для своего протокола (как в doom_2) |
| `script_of(name) -> Script` | скрипт библиотеки по имени |
| `encode(v)` / `decode(bytes)` | двоичный кодек: объекты не кодируются, глубина и длины ограничены |
| `rng(seed, tick, stream)` | PCG32, одинаковый у всех: `frand()`, `irange(a, b)`, `chance(p)`, `pick(arr)` |
| `state_hash(v)` | хеш значения, не зависящий от порядка ключей (32 бита) |
| `parse_code(s)`, `invite_link(code)` | разбор ввода игрока и ссылка-приглашение |
| `shared_code(seed, stream, prefix)`, `utc_day()` | общий код комнаты, например комнаты дня |
| `player_key()` | постоянный ключ игрока: по нему хост узнаёт вернувшегося |

### API сессии (`net/Session.gd`)

| | |
|---|---|
| `host(name, adapter = null, cfg = {}) -> String` | открыть комнату. `cfg`: `max_players`, `time_mode` (`host`/`vote`), `join_in_progress`, `allow_coruler`, `ready_required`, `room_name`, `public`, `preset`, `want_code`; режим ядра: `authority`, `external_time`, `push_min_ms`, `mods` |
| `join(code_or_link, name, adapter = null, extra = {}) -> String` | войти. `extra.mods` сверяется с `cfg.mods` хоста |
| `start()` | хост начинает партию; гости получают мир |
| `send(to, type, data)` / `broadcast(type, data)` | сообщение ровно один раз; `to`: 1 — хост, 0 — всем, кроме себя |
| `action(kind, args)` | приказ через шаг мира: у всех в одном порядке |
| `chat(text)`, `time_cmd(kind, value)`, `set_ready(on)`, `choose_seat(seat, coruler)`, `kick(id)`, `lobby_cmd(cmd)` | лобби и время |
| `leave()`, `rejoin()`, `request_full_world()` | уйти; войти снова; получить мир целиком |
| `role`, `status`, `code()`, `invite_link()`, `players()`, `my_id()`, `rtt_ms()`, `time_state()`, `state()`, `last_notice` | состояние |
| сигналы `changed`, `message(from, type, data)`, `event(kind, data)`, `failed(code)` | |

`status`: `connecting` → `lobby` → `syncing` → `playing`; `reconnecting` во время обрыва; `failed` —
ошибка связи (есть кнопка «Войти снова»); `closed` — хост закрыл партию или выгнал игрока.
Причина лежит в `last_notice` = `{what, do, code}`. `what` и `do` — ключи перевода библиотеки
(`paxnet_err_<код>` и `paxnet_err_<код>_do`): что случилось и что нажать.

Без адаптера (`BasicAdapter`) работают лобби, время, чат и сообщения. Мира для сверки при этом нет.
Свой мир описывается контрактом `core/Adapter.gd`: разделы, суммы, данные разделов, применение,
снимок мира.

## Как устроено

```
 мод ──► Session ──► HostSession / GuestSession ──► PipeHost / PipeGuest ──► RelayPipe ──► Network.relay_pipe() игры
          (узел)        (ядро: звено, рукопожатие,     (адрес гостя для         (поиск сети игры,     (wss до mp.paxuniverse.ru,
                         лобби, время, шаги, сверка,    ядра = "pipe#<номер>")    ожидание канала,      подпись лицензией игрока)
                         лечение, передача мира)                                  работа на паузе)
```

| Папка | Что в ней |
|---|---|
| `core/` | ядро на чистом GDScript, не зависит от игры и сети: кодек, хеш состояния, HMAC, PCG32, звено с надёжностью (`UdpLink`), рукопожатие, передача больших данных (`Xfer`), сессии хоста и гостя, время, почта между игроками, канал сообщений |
| `transport/` | канал ретранслятора игры (`RelayPipe`, `GameRelay`), транспорты сессий (`PipeHost`, `PipeGuest`), коды и приглашения (`Relay`) |
| `net/` | точка входа для модов (`PaxNetLib`), партия (`Session`), адаптер без мира (`BasicAdapter`) |
| `game/` | партия в мире Pax Universe: `NetService`, `GameAdapter`, `WorldKeys` (разделы записи сейва) |
| `ui/` | `NetOverlay`: окно состояния любой сессии |

### Что изменено по сравнению с оригинальным PaxNet

**Песочница модов** (AGENTS.md, правило 8):

- Своих сокетов больше нет. `UdpSocket` (PacketPeerUDP), `WsSocket` (WebSocketPeer), UPnP в потоке,
  пробивка NAT и вход по `ip:порт` удалены. Связь идёт каналом игры `Network.relay_pipe()`, как в
  doom_2. Канал уже идёт по wss до mp.paxuniverse.ru (порт 443, через прокси и VPN) и подписан
  лицензией игрока. Новые транспорты `PipeHost` и `PipeGuest` дают ядру тот же интерфейс
  (`send_to` / `on_datagram` / `update`), поэтому сессии, звено, рукопожатие, сверка и передача мира
  не переписывались. Звено узнаётся по подписи на любом адресе. Поэтому гость, переоткрывший канал
  под новым номером, продолжает то же звено без нового рукопожатия: это проверено тестом.
- Узел сети игры больше не подменяется (`replace_service("network")`, `GameNetwork extends
  res://src/net/Network.gd`). Библиотека не может забрать у игры службу, через которую сама ходит в
  сеть. Кроме того, она не должна молча менять сетевую игру всем, кто её включил.
- Все `preload`/`load` записаны литералами с полным путём `res://mods/paxnet/…`. Путей с `..` нет.
- `FileAccess.COMPRESSION_ZSTD` заменён числом `Bytes.ZSTD` (= 2, сверено с движком 4.7).
- Четыре ошибки проверки оригинала:
  - `GameAdapter.gd:197` — строка `DirAccess.make_dir_recursive_absolute(...)` удалена: `save_it`
    сам создаёт папку;
  - `NetService.gd:61` — `ClassDB.class_exists("Crypto")` убран, просто `Crypto.new()`;
  - `WorldKeys.gd:13` (`load` и `game`) — `preload("res://src/save/KeyMigration.gd")` убран, поле
    вписано константой `KEY_FORMAT_FIELD := "key_format"`.

**Ошибки оригинала, найденные по дороге:**

- `NetService.gd` начинался с `\extends Node`. Это ошибка разбора: файл не компилировался вовсе.
- Пустой мир (адаптер без мира) при входе давал ошибку движка `decompress(0)`.
- Дело между игроками (`deal`) отправлялось гостю, но гость его не применял. Теперь применяет.
- `Proto.gd`: комментарий к `M_REPLAY` был склеен со строкой `M_APP_ACK`.
- `Relay.parse_target` принимал только 6-значные коды. Коды ретранслятора игры — 4..12 знаков
  (взято из doom_2).

**Прочее:**

- `SharedRng` смешивает имя потока через FNV-1a, а не через `hash()` (как в doom_2). Результат
  одинаков на любой версии движка. Последовательности отличаются от оригинала PaxNet.
- Ключи перевода переименованы с префиксом мода: `paxnet_…` (правило 3). Текст из кода вынесен
  (`%d мс` в окне, имена по умолчанию).
- Звено поверх надёжного канала настроено реже повторять: `min_rto 400 мс`, `keepalive 500 мс`,
  таймаут 15 с (`PipeHost.LINK_TUNE`).
- Хост при уходе прощается со всеми (`HostSession.close_all`). Гости пишут «хост закрыл игру» и не
  пытаются вернуться.

Из doom_2 взяты `RelayPipe.gd` и `GameRelay.gd` (поиск сети игры, ожидание канала-«обещания»,
работа на паузе) и разбор кодов из `Relay.gd`. Шутерная часть doom_2 (`DoomNet`, части сообщений,
таблица дня, цвета, рассылка 20 раз в секунду) не нужна: её заменяют сессии ядра. Таблицу дня
можно собрать из `shared_code(utc_day(), …)` и `open_pipe()`.
