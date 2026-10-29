extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ПРОТОКОЛ: номера сообщений и коды причин. Описание — в README мода («Протокол»).

## Версия протокола и библиотеки (semver). Гость и хост соединяются только при точном совпадении: формат пакетов и
## рукопожатия менялся без обратной совместимости. Меняйте вместе с "version" в mod.json.
const VERSION := "3.1.1"

# --- сообщения звена (после рукопожатия) ---
const M_LOBBY := 10          # хост → все: состояние лобби целиком (версия растёт)          reliable
const M_LOBBY_CMD := 11      # гость → хост: выбрать страну, готовность, имя, правила          reliable
const M_CHAT := 12           # любой → хост → все                                            reliable
const M_ACTION := 20         # гость → хост: приказ {cseq, kind, args}                       reliable, redundant
const M_ACTION_RESULT := 21  # хост → автору: что стало с приказом                           reliable
const M_CLOSURE := 30        # хост → все: шаг мира (приказы, дни, счётчик случайностей, суммы) reliable, redundant
const M_REPORT := 31         # гость → хост: «я на шаге N, сумма M»                          slot
const M_RESYNC := 32         # гость → хост: суммы разделов на шаге N, прошу лечить          reliable
const M_PATCH := 33          # хост → гость: разделы мира (малые — внутри)                   reliable
const M_PATCH_BLOB := 34     # хост → гость: разделы мира пришлёт Xfer, примени на шаге N     reliable
const M_WORLD := 40          # хост → гость: целый мир пришлёт Xfer                          reliable
const M_XFER_BEGIN := 41     # отправитель → получатель                                      reliable
const M_XFER_CHUNK := 42     # отправитель → получатель                                      oneshot
const M_XFER_ACK := 43       # получатель → отправитель                                      slot
const M_XFER_END := 44       # получатель → отправитель: собрано / не сошлась сумма          reliable
const M_TIME_CMD := 50       # гость → хост: пауза, скорость, голос                          reliable
const M_TIME := 51           # хост → все: состояние времени                                 reliable
const M_PING := 60           # любой: метка времени                                          slot
const M_PONG := 61
const M_NOTICE := 70         # хост → гость: понятное сообщение {code, args}                 reliable
const M_BYE := 71            # любая сторона: закрываю звено, причина                        reliable
const M_FRAG := 73           # кусок большого надёжного сообщения {mid, i, n, тип}            reliable
const M_REPLAY := 72         # гость → хост: прошу шаги с N (короткий обрыв)                 reliable
const M_APP := 80             # сообщение протокола игры/мода {s, from, to, type, data}         reliable (частями)
const M_APP_ACK := 81         # «получил всё до s»                                                slot

# --- рукопожатие (до звена; свои кадры, crc32 в конце) ---
const H_HELLO := 1
const H_CHALLENGE := 2
const H_CONNECT := 3
const H_ACCEPT := 4
const H_REJECT := 5

# --- коды причин (в журнал и в окно игрока через ключ перевода paxnet_err_<код>) ---
const ERR_VERSION := "version"           # другая версия протокола
const ERR_MODS := "mods"                 # наборы модов не совпали
const ERR_FULL := "full"                 # лобби заполнено
const ERR_CODE := "code"                 # нет такого кода / приглашения
const ERR_BANNED := "banned"
const ERR_STARTED := "started"           # партия идёт, вход закрыт правилами
const ERR_SEAT_TAKEN := "seat_taken"
const ERR_TIMEOUT := "timeout"           # молчит дольше таймаута
const ERR_KICKED := "kicked"
const ERR_HOST_LEFT := "host_left"
const ERR_ILLEGAL := "illegal"           # приказ не по правилам
const ERR_HOST_ONLY := "host_only"       # время решает хост
const ERR_RATE := "rate"                 # слишком часто
const ERR_BAD_PACKET := "bad_packet"
const ERR_DESYNC := "desync"             # мир расходился, лечение не помогло
const ERR_NO_ROUTE := "no_route"         # не достучаться (NAT, порт, ретранслятор)
const ERR_PIN := "pin"                   # ключ хоста не совпал с приглашением (подмена на ретрансляторе или чужое приглашение)
const ERR_RELAY := "relay"               # ретранслятор недоступен

# Что сказать игроку и что нажать — ключи перевода мода (data/lang/*.json):
#   paxnet_err_<код>      — что случилось
#   paxnet_err_<код>_do   — что нажать
static func human(code: String) -> Dictionary:
	return {"what": "paxnet_err_" + code, "do": "paxnet_err_" + code + "_do", "code": code}
