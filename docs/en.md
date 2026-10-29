# PaxNet Core: documentation

An online-play library for Pax Universe mods. The same documentation is available at https://paxnet.isroot.in/. Russian version: [ru.md](ru.md).

## Contents

- [What is this, anyway](#what-is-this-anyway)
- [Words you will meet below](#words-you-will-meet-below)
- [How to install it when a mod asks for PaxNet](#how-to-install-it-when-a-mod-asks-for-paxnet)
- [Your first network mod, step by step](#your-first-network-mod-step-by-step)
- [How a single message travels](#how-a-single-message-travels)
- [Status: where your game is right now](#status-where-your-game-is-right-now)
- [PaxNetLib: the library's entry point](#paxnetlib-the-librarys-entry-point)
- [Session: your online game](#session-your-online-game)
- [Room settings](#room-settings)
- [What you can send](#what-you-can-send)
- [Errors and what to do about them](#errors-and-what-to-do-about-them)
- [Ready-made solutions: copy and adapt](#ready-made-solutions-copy-and-adapt)
- [Your own world: checks and healing](#your-own-world-checks-and-healing)
- [A game in the world of Pax Universe itself](#a-game-in-the-world-of-pax-universe-itself)
- [Not working? Frequently asked questions](#not-working-frequently-asked-questions)
- [The sandbox: why things work the way they do](#the-sandbox-why-things-work-the-way-they-do)
- [What is protected and how it works](#what-is-protected-and-how-it-works)
- [How PaxNet Core differs from PaxNet](#how-paxnet-core-differs-from-paxnet)
- [MPL 2.0 in plain words](#mpl-20-in-plain-words)
- [Protocol](#protocol)
- [How it was tested](#how-it-was-tested)
- [Help PaxNet grow](#help-paxnet-grow)

## What is this, anyway

> **In a nutshell.**
>
> The PaxNet mod changes nothing in the game by itself. It is an engine for other mods: with it, a mod can be played online with friends without writing a single line of networking code.

Think of a post office. One player (the **host**) opens a "post office" (a room) and gets its address: a short **code** such as `D3EF5YXQ` plus a secret **PIN**. Friends (the **guests**) receive an invite with the code and PIN and arrive at the same office. From then on anyone can send a "letter" (a **message**) to the host, to a specific friend, or to everyone at once.

PaxNet makes sure every letter arrives **exactly once** and **in the order it was sent**. Even if a friend loses internet for a minute, the letters sent in the meantime arrive after they come back. None get lost and none arrive twice.

Letters do not travel directly between computers. They go through the **game relay**, the server `mp.paxuniverse.ru` that Pax Universe itself already uses. So there is no need to open ports on a router, know a friend's IP address or set up a VPN. All letters are **encrypted**: the relay forwards them but cannot read them (details in [Security](#what-is-protected-and-how-it-works)).

- **For players**: Enable the mod in the mod list. Nothing else to do: other mods use it.
- **For mod authors**: Call `host()` or `join()`, send messages with `send()` and receive them with the `message` signal.
- **For advanced users**: Whole-world sync: per-section checksums, healing divergences, handing over the world without pausing the game.

## Words you will meet below

Read this once and everything after will make sense. Every term is explained in plain language, with an example.

- **Host**: The player who opened the room. On the network the host is always number `1`. The host is in charge: settles disputes and broadcasts the "truth". *Like the owner of the flat where the guests came.*
- **Guest**: A player who entered someone else's room by invitation. Guests are numbered `2`, `3`, `4`… in order of arrival. *Came by invitation.*
- **Room**: A place on the relay where the host and guests meet. It exists while the host is in the game.
- **Room code**: 4 to 12 characters with no look-alike letters (no `0`, `O`, `1`, `I`). For example `D3EF5YXQ`. Case does not matter. The relay knows the code too: it uses it to find the room. *The post office address.*
- **Invite PIN**: 24 characters from the same alphabet, for example `K7M2P9QXA4HVF3D8WNQ5TZ6B`. The first 12 are secret: the host lets in only those who know them. The last 12 are a fingerprint of the host's public key: the guest checks the host's key against the invite and will not talk to a substituted key. The PIN is never sent to the relay. *A door password and a seal on it.*
- **Invite**: A link with the code and PIN: `https://mp.paxuniverse.ru/j/CODE#PIN`. The short form `CODE#PIN` works too. Send it to a friend in a messenger, whole.
- **Relay**: The game server all messages go through. Pax Universe itself provides it via `Network.relay_pipe()`. *The mail sorting centre.*
- **Game / session**: Your whole online game: room, players, messages. In code it is the `Session` node.
- **Message**: Any plain data with a "type", a string that tells you what arrived. For example type `"my_mod.chat"`, data `"Hello!"`.
- **Exactly once**: A message is never lost and never arrives twice, even across a dropped connection. Order is preserved.
- **Reconnect**: The connection dropped and came back by itself. The player returns with the same number to the same place.
- **Player key**: A secret string stored on the player's computer. It is never sent to a host: the host gets a separate key for its own room and uses that to recognise a returning player. *Like an office pass, but a different one for every office.*
- **Lobby**: The time before the game starts: players gather, pick seats, press "ready".
- **Seat**: The number of the country or side a player controls. One seat has one player, but may have co-rulers.
- **Adapter**: Your object through which PaxNet learns about your mod's "world". Only needed if you sync a whole world.
- **World section**: A named piece of the world: `"score"`, `"map"`. Checked and healed separately from the rest.
- **Checksum (hash)**: A short number computed from data. If two players' data differ, their checksums almost certainly differ too. *A fingerprint of the data.*
- **Healing**: A guest's section diverged from the host's. The guest quietly asks for that section only, and the host sends the correct one.
- **World step**: One "tick" of the game: a number, orders, how many days passed. Steps go strictly in order: 1, 2, 3…

## How to install it when a mod asks for PaxNet

1.  **Download PaxNet Core from the Workshop**

    Open the Pax Universe launcher → **Workshop**, find "PaxNet Core" and click "Download".

2.  **Enable it in the "Mods" section**

    Launcher → **Mods** → tick "PaxNet Core" and the mod that asked for it. The game applies mods on the next launch.

> **What you see on screen.**
>
> If the mod enabled the status line, the top of the screen shows: "You are the host · code D3EF5YXQ · players: 3 · 42 ms". On an error a window appears saying what happened and what to click, for example a "Rejoin" button. The mod that uses PaxNet will explain how to open a room and join.

> **Friend cannot get in?**
>
> Send the invite whole, together with the PIN: `CODE#PIN` or the full link. If only the code is sent, joining fails and after 8 seconds "The host is not responding" appears.

## Your first network mod, step by step

> **What you will build.**
>
> The "Hello Net" mod: chat between players through the developer console (<span class="kbd">F8</span>). One player types `hello host` and gets an invite, the other types `hello join INVITE`. After that `hello say Hi!` shows the message to everyone. It is under 90 lines of code, and every piece has a comment.

All code on this page is written for Godot 4.7 with strict typing, as in the game, and is meant to pass the sandbox check.

1.  **Create the mod folder**

    In the game's `mods` folder, create a folder `hello_net`. Folder name = **mod id**: Latin letters, digits and `_`. Here is what it will contain at the end:

    ``` text
    mods/
    └── hello_net/
        ├── mod.json            ← the mod's passport: name, version, dependencies
        ├── main.gd             ← mod code, first line: extends PaxMod
        └── data/
            └── lang/
                ├── ru.json     ← Russian texts
                └── en.json     ← English texts
    ```

2.  **Write mod.json, the mod's passport**

    The key line is `"depends": ["paxnet_core"]`. It tells the game: "this mod does not work without PaxNet, load the library before me".

    ``` json
    {
        "api": 1.0,
        "id": "hello_net",
        "name": {"en": "Hello Net", "ru": "Привет, сеть"},
        "description": {"en": "Smallest PaxNet example: chat between players.", "ru": "Самый маленький пример PaxNet: чат между игроками."},
        "version": "1.0.0",
        "entry": "main.gd",
        "game_version": ">=0.9.0",
        "authors": ["You"],
        "depends": ["paxnet_core"],
        "load_after": ["paxnet_core"],
        "tags": []
    }
    ```

    > **Common mistake.**
    >
    > Forgetting `depends`. Then your mod may load before the library and fail to find it.

3.  **Add texts to data/lang**

    In Pax Universe **you may not write player-facing text directly in code**: everything the player sees lives in translation files (a game rule). In code you write a key, for example `tr_key("hello_net_me")`, and the game substitutes the text in the player's language. Start keys with your mod id so they do not clash with other mods.

    ``` json
    {
        "hello_net_no_lib": "Enable the PaxNet Core mod and restart the game.",
        "hello_net_me": "Player",
        "hello_net_wait": "Opening the room… In a couple of seconds type: hello code",
        "hello_net_line": "%s: %s",
        "hello_net_joined": "%s joined the game",
        "hello_net_help": "hello host | hello code | hello join INVITE | hello say TEXT | hello leave"
    }
    ```

    The `ru.json` file has the same keys in Russian. At least these two languages are required.

    ``` json
    {
        "hello_net_no_lib": "Включите мод PaxNet Core и перезапустите игру.",
        "hello_net_me": "Игрок",
        "hello_net_wait": "Комната открывается… Через пару секунд наберите: hello code",
        "hello_net_line": "%s: %s",
        "hello_net_joined": "%s вошёл в партию",
        "hello_net_help": "hello host | hello code | hello join ПРИГЛАШЕНИЕ | hello say ТЕКСТ | hello leave"
    }
    ```

4.  **Write main.gd, the mod itself**

    The first line is always `extends PaxMod`. Read the comments: they say what each piece does.

    ``` gdscript
    extends PaxMod
    ## The smallest network mod on PaxNet: chat between players via the console (F8).

    ## Our message type. Start it with your mod id so types from different mods never mix.
    const MSG_SAY: String = "hello_net.say"

    ## The online game (the net/Session.gd node from the library). null if not created yet.
    var net: Node = null


    func _mod_loaded() -> void:
        Pax.register_command("hello", Callable(self, "_cmd"), tr_key("hello_net_help"))


    ## The PaxNet library: the node it stores in the root's metadata. null if the library is not enabled.
    func _lib() -> Node:
        var v: Variant = Pax.get_tree().root.get_meta("paxnet_lib", null)
        return v as Node if v is Node else null


    ## The session is created once and lives as long as the game runs.
    func _net() -> Node:
        if net != null and is_instance_valid(net):
            return net
        var lib: Node = _lib()
        if lib == null:
            return null
        net = lib.call("new_session")
        net.connect("message", _on_message)
        net.connect("event", _on_event)
        net.connect("failed", _on_failed)
        return net


    func _cmd(args0: Variant = []) -> String:
        var args: Array = []
        if args0 is String:
            args = Array((args0 as String).split(" ", false))
        elif args0 is Array:
            args = args0
        var n: Node = _net()
        if n == null:
            return tr_key("hello_net_no_lib")
        var what: String = str(args[0]) if args.size() > 0 else ""
        match what:
            "host":
                var err: String = str(n.call("host", tr_key("hello_net_me")))
                return err if err != "" else tr_key("hello_net_wait")
            "code":
                # The link together with the PIN: send it to your friend whole.
                return str(n.call("invite_link"))
            "join":
                if args.size() < 2:
                    return tr_key("hello_net_help")
                var err2: String = str(n.call("join", str(args[1]), tr_key("hello_net_me")))
                return err2 if err2 != "" else "ok"
            "say":
                var text: String = " ".join(PackedStringArray(args.slice(1)))
                n.call("broadcast", MSG_SAY, text)
                return tr_key("hello_net_line") % [tr_key("hello_net_me"), text]
            "leave":
                n.call("leave")
                return "ok"
        return tr_key("hello_net_help")


    ## A message arrived from another player.
    func _on_message(from_id: int, type: String, data: Variant) -> void:
        if type == MSG_SAY:
            var who: String = str(net.call("player_name", from_id))
            _toast(tr_key("hello_net_line") % [who, str(data)])


    ## Session events: here only "someone joined" (the host sees it).
    func _on_event(kind: String, data: Dictionary) -> void:
        if kind == "peer_joined":
            _toast(tr_key("hello_net_joined") % str(data.get("name", "?")))


    ## Error: show a clear reason from the library's translations.
    func _on_failed(code: String) -> void:
        _toast(tr_key("paxnet_err_" + code) + " " + tr_key("paxnet_err_" + code + "_do"))


    func _toast(text: String) -> void:
        var g: Variant = Pax.get("game")
        if g is Object and (g as Object).has_method("toast"):
            (g as Object).call("toast", text)
        else:
            print(text)
    ```

    > **What matters here.**
    >
    > `_lib()` fetches the library. `new_session()` creates a session. `host()` opens a room, `join()` enters one. `broadcast()` sends to everyone. The `message` signal fires when a message reaches you. `invite_link()` returns the invite with the PIN.

5.  **Check the mod**

    Run this command in the game folder. Exit code `0` means no errors:

    ``` bash
    godot --headless --path <game folder> -- --check-mods hello_net
    ```

6.  **Enable both mods and run the game on two computers**

    Launcher → Mods → tick "PaxNet Core" and "Hello Net". Restart.

7.  **Play**

    Press <span class="kbd">F8</span> to open the console.

    | Who    | What to type                       | What happens                                                                                                                         |
    |--------|------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
    | Host   | `hello host`                       | "Opening the room…". The room is ready in 1-2 seconds.                                                                               |
    | Host   | `hello code`                       | An invite link with the PIN, for example `https://mp.paxuniverse.ru/j/D3EF5YXQ#K7M2P9QXA4HVF3D8WNQ5TZ6B`. Send it to a friend, whole.            |
    | Friend | `hello join D3EF5YXQ#K7M2P9QXA4HVF3D8WNQ5TZ6B` | The friend enters the room; the host sees "Player joined the game". Pasting the whole link works too. Without the PIN joining fails. |
    | Anyone | `hello say Hi!`                    | Everyone else sees "Player: Hi!".                                                                                                    |
    | Anyone | `hello leave`                      | Leave. If the host leaves, guests see "The host closed the game".                                                                    |

    > **Done.**
    >
    > This is a complete online game: dropped connections, ordering, duplicates and encryption are already handled for you. Next come the reference and the recipes: real-time movement, turn-based play, shared dice, a room of the day.

## How a single message travels

A guest called `send(1, "my_mod.chat", "Hi")`. Here is what happens next, top to bottom. You do not need to know this, but it makes errors easier to understand.

- **You call send()** (your mod): The message gets a sequence number: 1, 2, 3… The receiver uses these numbers to drop duplicates and restore order.
- **Packing** (AppChannel): The data is turned into bytes by PaxNet's own codec. Anything over 4 KB is compressed. A large message is split into chunks.
- **Encryption and signature** (UdpLink): Chunks are packed into packets of up to 1200 bytes. The contents of each packet are encrypted (AES-128) and signed with a key only this guest and the host know. A packet cannot be read or forged on the way.
- **Into the game channel** (PipeGuest): The packet goes into the relay channel, addressed to the host, number 1.
- **The game relay** (mp.paxuniverse.ru): The Pax Universe server forwards the packet to the host over a secure connection (wss, port 443). Inside the packet it sees only ciphertext.
- **Verify and reassemble** (host): The host checks the signature, decrypts, reassembles the chunks, decompresses. It acknowledges: "received everything up to number N".
- **Delivery** (host → recipient): If the message was for the host, the host's `message` signal fires. If it was for another guest or for everyone, the host forwards it the same way and states the real author itself.

> **What if the connection drops halfway?**
>
> Unacknowledged messages stay in the sender's queue. When the connection returns they are sent again. The receiver sees familiar numbers and discards what it already has. That is how you get exactly once, in order.

### Who can message whom

| Call                                      | Who receives it                             | `from_id` at the receiver |
|-------------------------------------------|---------------------------------------------|---------------------------|
| `send(1, …)` on a guest                   | Only the host                               | the guest's number        |
| `send(3, …)` on guest \#2                 | Only guest \#3 (via the host)               | `2`                       |
| `send(0, …)` or `broadcast(…)` on a guest | The host and all guests except the author   | the author's number       |
| `send(2, …)` on the host                  | Only guest \#2                              | `1`                       |
| `broadcast(…)` on the host                | All guests                                  | `1`                       |
| `send(own_number, …)`                     | Nobody: you never receive your own messages | none                      |

## Status: where your game is right now

A session has a `status` field. It changes by itself, and every change fires the `changed` signal. Look at the status to decide what to show the player.

- `connecting`: Opening or entering the room. Usually 1-2 seconds.
- `lobby`: Everyone is in the room; the game has not started. Messages already flow.
- `syncing`: A guest is receiving the world from the host. The host's game keeps running.
- `playing`: The game is on.

<!-- -->

- `reconnecting`: The connection dropped; PaxNet brings the player back by itself. Nothing to do.
- `failed`: The connection did not come back. Show the player a "Rejoin" button (`rejoin()`).
- `closed`: The host closed the game or kicked the player. Nowhere to return to.

There is also `""` (empty string): no game; the session was just created or left with `leave()`.

> **Note for the host.**
>
> The host never has `syncing`, and `playing` starts after `start()`. Messages already work in `lobby`: if your mod has no "game start", you do not need to call `start()` at all.

## PaxNetLib: the library's entry point

The library creates the `/root/PaxNetLib` node and immediately, before it even enters the tree, stores it in the root's metadata. So fetch it like this; it works even in `_mod_loaded`:

``` gdscript
## Fetch the library. Works already in _mod_loaded: the node lives in the root's metadata.
func get_paxnet() -> Node:
    var v: Variant = Pax.get_tree().root.get_meta("paxnet_lib", null)
    if v is Node:
        return v as Node
    return null   # library not enabled: show the player a hint
```

> **Why not preload?**
>
> The game sandbox allows `load()` and `preload()` only for paths of *your own* mod. A line like `preload("res://mods/paxnet_core/…")` in your mod will be rejected. Everything you need is handed out by the library node itself.

| Method                                          | What it does                                                                                                                                                                                                            | Example                                                |
|-------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| new_session(parent = null) → Node               | Creates a new online game (Session) and adds it to the tree. The player key is filled in automatically.                                                                                                                 | `var net: Node = lib.new_session()`                    |
| open_pipe(first) → Object                       | A raw relay channel for your own protocol (as in doom_2). See recipe 6. PaxNet encryption does not apply here.                                                                                                          | `lib.open_pipe({"op": "join", "code": c})`             |
| overlay(session, parent) → CanvasLayer          | A status line at the top of the screen for the session: code, players, ping, a clear error with a button.                                                                                                               | `lib.overlay(net, game.hud_layer())`                   |
| encode(value) → PackedByteArray                 | Value to bytes. Custom codec: objects are never encoded, depth and lengths are limited.                                                                                                                                 | `var b: PackedByteArray = lib.encode({"hp": 5})`       |
| decode(bytes) → Dictionary                      | Bytes to value: {ok, v}. Garbage does not crash the game; you get ok = false.                                                                                                                                           | `var d: Dictionary = lib.decode(b)`                    |
| rng(seed, tick = 0, stream = "") → RefCounted   | A random generator identical for all players. Methods: frand(), irange(a, b), chance(p), pick(arr), next_u32().                                                                                                         | `lib.rng(seed, turn, "my_mod/dice")`                   |
| state_hash(value) → int                         | A 32-bit fingerprint of a value, independent of dictionary key order. For sync checks.                                                                                                                                  | `lib.state_hash(world)`                                |
| parse_code(text) → String                       | The room code from whatever the player typed: a code, PAX-…, a link (anything after "#" is ignored). "" means it is not a code.                                                                                         | `lib.parse_code("pax-d3ef5yxq")`                       |
| parse_pin(text) → String                        | The PIN from an invite like `CODE#PIN` or a link. "" if there is no PIN or it is malformed (not 24 alphabet characters).                                                                                                | `lib.parse_pin("D3EF5YXQ#K7M2P9QXA4HVF3D8WNQ5TZ6B")`               |
| invite_link(code, pin = "") → String            | Invite link for a code. If pin is given, it is appended after "#".                                                                                                                                                      | `lib.invite_link("D3EF5YXQ", pin)`                     |
| shared_code(seed, stream, prefix = "") → String | A room code that is the same for everyone with the same seed and stream. 8 characters total; prefix is up to 4 characters at the start. Such rooms need `pinned: false`, see recipe 4.                                  | `lib.shared_code(lib.utc_day(), "my_mod/daily", "MM")` |
| utc_day() → int                                 | The current UTC day number: the same for every player in the world.                                                                                                                                                     | `lib.utc_day()`                                        |
| player_key() → String                           | The persistent player key on this computer (shared by all mods). Never sent out, see [Security](#what-is-protected-and-how-it-works).                                                                                   | `lib.player_key()`                                     |
| script_of(name) → Script                        | A library script by name: Proto, Bytes, SharedRng, StateHash, Delta, Crc32, Hmac, Adapter, BasicAdapter, HostSession, GuestSession, Mailbox, TimeAuthority, Relay, RelayPipe, PipeHost, PipeGuest, Session, NetOverlay. | `var RP: Script = lib.script_of("RelayPipe")`          |
| world_service() → Node                          | A game in the world of Pax Universe itself (the strategy game). null if unavailable in this game version.                                                                                                               | `lib.world_service().host_open("Anna")`                |
| world_service_if_any() → Node                   | Same, but does not create it: null if it does not exist yet.                                                                                                                                                            |                                                        |
| pipe_detail() → String                          | What was found instead of the channel on the last failure. For logs and support.                                                                                                                                        | `print(lib.pipe_detail())`                             |

Call methods with `lib.call("name", …)` or simply `lib.name(…)`: GDScript allows calling by name on a `Node`. The result of such a call is untyped, so give the variable an explicit type: `var net: Node = lib.new_session()`. The game will not compile `var net := lib.new_session()`.

## Session: your online game

The node returned by `lib.new_session()`. It is already in the tree and keeps processing even while the game is paused. One session is one game; after `leave()` the same session can be reused.

Tags: \[host\] works only on the host, \[guest\] only on a guest, \[both\] on everyone.

### Open, join, leave

| Method                                                  | Who       | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Example                                      |
|---------------------------------------------------------|-----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| host(name, adapter = null, cfg = {}) → String           | \[host\]  | Open a room. name: the player name everyone will see. adapter: only for world sync, otherwise null. cfg: [room settings](#room-settings). Returns "" if opening has started, or an error code. The room code and PIN appear in 1-2 seconds (the room event, status lobby).                                                                                                                                                                                          | `net.host("Anna")`                           |
| join(target, name, adapter = null, extra = {}) → String | \[guest\] | Join by invite: `CODE#PIN`, "PAX-CODE#PIN" or a link with the PIN. Returns "" (joining, wait for status lobby) or an error code: "code" if the input is clearly not a code, "relay" if the relay channel did not open. If no room has that code, you find out later: the failed("code") signal fires. If the PIN is missing or wrong, the handshake silently fails and after 8 seconds failed("no_route") arrives. If the host's key does not match the fingerprint in the invite, failed("pin") arrives and the secret is never sent to the host. extra.mods is compared with the host's cfg.mods. | `net.join("D3EF5YXQ#K7M2P9QXA4HVF3D8WNQ5TZ6B", "Boris")` |
| start() → Dictionary                                    | \[host\]  | Start the game: status playing, guests receive the world (or an empty world if there is no adapter). Returns {ok, code}. Optional if your mod has no "start".                                                                                                                                                                                                                                                                                                       | `net.start()`                                |
| leave()                                                 | \[both\]  | Leave. A guest says goodbye to the host. The host says goodbye to everyone and closes the room. Called automatically when the node is freed.                                                                                                                                                                                                                                                                                                                        | `net.leave()`                                |
| rejoin() → String                                       | \[guest\] | Join again after a connection error (status failed): same key, same seat, same PIN.                                                                                                                                                                                                                                                                                                                                                                                 | `net.rejoin()`                               |
| request_full_world()                                    | \[guest\] | Ask for the entire world if it diverged and did not heal (desync error).                                                                                                                                                                                                                                                                                                                                                                                            |                                              |

### Messages

| Method                              | Who      | What it does                                                                                                                                                                                                                                                                                                  | Example                                      |
|-------------------------------------|----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| send(to, type, data = null) → bool  | \[both\] | Send a message. to: 1 (host), 2… (guest), 0 (everyone except yourself). Delivered exactly once and in order. Returns false if there is no game. The rate is limited, see [Limits](#what-you-can-send).                                                                                                        | `net.send(1, "my_mod.hi", "hello")`          |
| broadcast(type, data = null) → bool | \[both\] | Same as send(0, …): everyone except yourself.                                                                                                                                                                                                                                                                 | `net.broadcast("my_mod.pos", Vector2(3, 4))` |
| action(kind, args = null) → Variant | \[both\] | An order via a world step: same order for everyone. Only needed with an adapter. Works only after start(): in the lobby the order is rejected with illegal. If the adapter's action_policy returns "own" (the default), the author must hold a seat. A guest gets the order number; the host gets {ok, code}. | `net.action("my_mod.build", {"x": 2})`       |

### Lobby

| Method                                | Who      | What it does                                                                                                                                                                                                          | Example                                         |
|---------------------------------------|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------|
| set_ready(on)                         | \[both\] | The "ready" mark.                                                                                                                                                                                                     | `net.set_ready(true)`                           |
| choose_seat(seat, as_coruler = false) | \[both\] | Take a seat (country, side) by number from the adapter's countries(). If the seat is taken nothing changes: check players() after the changed signal. On the host, lobby_cmd returns {ok: false, code: "seat_taken"}. A player becomes a co-ruler (as_coruler = true) only by the seat owner's invite (`invite_coruler`). | `net.choose_seat(0)`                            |
| chat(text)                            | \[both\] | A chat line to everyone (up to 300 characters). Arrives in the adapter's on_chat. For your own chat, send/broadcast is simpler.                                                                                       | `net.chat("gg")`                                |
| kick(id)                              | \[host\] | Kick a player: they see "The host removed you from the game".                                                                                                                                                         | `net.kick(3)`                                   |
| invite_coruler(guest_id)              | \[both\]  | The seat owner invites a player to be a co-ruler. Without an invite nobody can take another player's seat as co-ruler. | `net.invite_coruler(3)` |
| revoke_coruler(guest_id)              | \[both\]  | Withdraw the invite and, if the player is already a co-ruler, remove them from the seat. | `net.revoke_coruler(3)` |
| lobby_cmd(cmd) → Variant              | \[both\] | Any lobby command: {op: "seat"\|"ready"\|"name"\|"rules"\|"kick"\|"start", …}. rules is host-only: time_mode, join_in_progress, ready_required, allow_coruler, max_players.                                           | `net.lobby_cmd({"op": "name", "name": "Anna"})` |

### Game time

| Method                       | Who      | What it does                                                                                                                                                                     | Example                 |
|------------------------------|----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------|
| time_cmd(kind, value = null) | \[both\] | kind: "pause", "resume", "speed" (value from 1 to 5). With time_mode "host" the host refuses a guest: code host_only goes to the adapter (on_notice). With "vote" a vote starts. | `net.time_cmd("pause")` |
| time_state() → Dictionary    | \[both\] | {paused, speed, by, by_name, mode, votes, v}: whether paused, who paused, whether a vote is on.                                                                                  |                         |

### Querying state

| Method                        | Who       | What it does                                                                                               | Example |
|-------------------------------|-----------|------------------------------------------------------------------------------------------------------------|---------|
| is_host() / is_guest() → bool | \[both\]  | Who am I in this game.                                                                                     |         |
| active() → bool               | \[both\]  | In a game and connected: status lobby, syncing or playing.                                                 |         |
| my_id() → int                 | \[both\]  | My number: 1 on the host, 2… on a guest. 0 if the guest has not joined yet.                                |         |
| code() → String               | \[both\]  | The room code (without the PIN).                                                                           |         |
| pin() → String                | \[host\]  | The invite PIN. "" if the room has no PIN (`pinned: false`) or you are a guest.                            |         |
| invite_link() → String        | \[host\]  | The invite link with the PIN: `https://mp.paxuniverse.ru/j/CODE#PIN`. This is what to send to friends.     |         |
| invite_code() → String        | \[host\]  | The short invite for typing by hand: `CODE#PIN`.                                                           |         |
| players() → Array             | \[both\]  | All players: \[{id, name, seat, role, ready, ai, ping, host, away}\]. away: connection lost, seat is held. |         |
| player_name(id) → String      | \[both\]  | Player name by number ("?" if not found).                                                                  |         |
| rtt_ms() → float              | \[guest\] | Ping to the host in milliseconds.                                                                          |         |
| state() → Dictionary          | \[both\]  | Everything at once: role, status, code, players, time, notice, rtt, id. Handy for your own lobby window.   |         |

### Signals

| Signal                                             | When it fires                                                                                          |
|----------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| message(from_id: int, type: String, data: Variant) | A message arrived. `from_id`: the author's number (1 means the host). **The main signal.**             |
| changed()                                          | Something changed: status, roster, readiness, time, an error. Handy for redrawing a lobby window.      |
| failed(code: String)                               | The game failed or was closed. `code` comes from the [error table](#errors-and-what-to-do-about-them). |
| event(kind: String, data: Dictionary)              | Detailed events, listed below.                                                                         |

### Events (`event`)

| kind                             | On    | Meaning                                                          | data                                                                  |
|----------------------------------|-------|------------------------------------------------------------------|-----------------------------------------------------------------------|
| `room`                           | host  | Room opened, code ready                                          | `{code}`                                                              |
| `reopening`                      | host  | The relay lost the room; reopening it with the same code and PIN | `{try}`                                                               |
| `relay_error`                    | host  | The relay did not give a room                                    | `{code, why}`                                                         |
| `peer_joined`                    | host  | A player joined or returned                                      | `{id, name, reconnect, mode}`                                         |
| `peer_left`                      | host  | A player left or vanished (their seat is held)                   | `{id, why}`; why: `bye`, `timeout`, `kicked`, `app_rate`, `app_abuse`, `lag` |
| `lobby`                          | both  | The lobby was updated                                            | the whole lobby state                                                 |
| `started`                        | host  | The game started                                                 | `{}`                                                                  |
| `world_sent` / `world_delivered` | host  | World sent to a guest / the guest assembled it                   | `{id, …}`                                                             |
| `step`                           | host  | A world step was made                                            | `{t, n}`                                                              |
| `connected`                      | guest | Connected to the host (also after a return)                      | `{id, mode, reconnect}`                                               |
| `lost`                           | guest | Connection lost, starting to come back                           | `{}`                                                                  |
| `world_installed`                | guest | The host's world was received and installed                      | `{tick}`                                                              |
| `patched` / `mismatch`           | guest | World changes arrived / a divergence was found (will be healed)  | `{names, tick}`                                                       |
| `action_rejected`                | guest | The host rejected an order                                       | `{c, ok, code}`                                                       |
| `closed` / `failed`              | guest | The host closed the game / the connection did not return         | `{why}` / `{code}`                                                    |

### Readable fields

| Field                             | Contents                                                                                            |
|-----------------------------------|-----------------------------------------------------------------------------------------------------|
| `role`                            | `"host"`, `"guest"` or `""`                                                                         |
| `status`                          | See [status](#status-where-your-game-is-right-now)                                                  |
| `last_notice`                     | The last error: `{what, do, code, args}`. `what` and `do` are translation keys: `tr_key(n["what"])` |
| `player_key`                      | The player key. Issued by the library, shared by all mods. Never sent to a host                     |
| `defaults`                        | Default room settings (see below)                                                                   |
| `session`, `transport`, `adapter` | Internals (HostSession/GuestSession, PipeHost/PipeGuest, your adapter), for advanced use            |

## Room settings

The third argument of `host(name, adapter, cfg)` is a dictionary. Everything is optional: any key you omit takes its default.

``` gdscript
net.host("Anna", null, {"max_players": 4, "time_mode": "vote", "join_in_progress": false})
```

| Key                | Default     | Meaning                                                                                                                                                                                                                                                                   |
|--------------------|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `max_players`      | `5`         | How many people in the game **including the host**. The sixth gets the `full` error.                                                                                                                                                                                      |
| `join_in_progress` | `true`      | Whether people can join a game in progress. With `false` newcomers get `started` (players returning with their key always get in).                                                                                                                                        |
| `time_mode`        | `"host"`    | Who controls time. `"host"`: only the host. `"vote"`: voting (anyone can pause immediately; unpausing or changing speed needs a majority within 15 seconds).                                                                                                              |
| `allow_coruler`    | `true`      | Whether two people can play one seat together (co-ruler).                                                                                                                                                                                                                 |
| `ready_required`   | `false`     | `start()` will not work until everyone pressed "ready" (returns `{ok: false, code: "not_ready"}`). The library has no ready `paxnet_err_…` text for `not_ready`: write the player message yourself.                                                                       |
| `room_name`        | host's name | Room name on the relay.                                                                                                                                                                                                                                                   |
| `public`           | `false`     | Ask the relay to show the room in the public list. Joining by code always works.                                                                                                                                                                                          |
| `preset`           | `"paxnet"`  | Room label for the relay. Set it to your mod id.                                                                                                                                                                                                                          |
| `want_code`        | `""`        | Request a specific code (continuing a saved game, room of the day). If the code is taken, the relay may give another one. Check `code()` after the `room` event.                                                                                                          |
| `want_pin`         | `""`        | The previous PIN when continuing a saved game, so old invites keep working. Empty: a new PIN is created.                                                                                                                                                                  |
| `pinned`           | `true`      | Whether to protect the room with a PIN. With `false` no PIN is created and a code alone is enough to join, but there is no protection against key swapping on the relay. Needed for rooms whose code is computed in advance and is the same for everyone (`shared_code`). |
| `mods`             | `""`        | A mod-set "fingerprint" string. If not empty, a guest with a different string in `join(…, {"mods": …})` gets the `mods` error.                                                                                                                                            |
| `authority`        | `false`     | For world sync: with `true` only the host computes the world and broadcasts the changes. See [your own world](#your-own-world-checks-and-healing).                                                                                                                        |
| `external_time`    | `false`     | With `true` you make world steps yourself by calling `session.record_step(days)`, instead of the speed timer. Before `start()` the call does nothing.                                                                                                                     |
| `push_min_ms`      | `0`         | In `authority` mode: minimum milliseconds between world-change broadcasts.                                                                                                                                                                                                |

### Limits that protect the host

These values cap what a single guest can do, so that one guest cannot overload the host. An honest mod stays far below them; you rarely need to change them. If a guest exceeds a message limit, the host cuts its link (the `peer_left` event reports the reason `app_rate` or `app_abuse`); the player can join again.

| Key                | Default           | Meaning                                                                                        |
|--------------------|-------------------|------------------------------------------------------------------------------------------------|
| `app_max_unpack`   | `4194304` (4 MB)  | The largest mod message after decompression. Larger: the link is cut.                          |
| `app_window`       | `1024`            | How far a message number may run ahead of the last accepted one. Further: the link is cut.     |
| `app_msgs_per_s`   | `50`              | Mod messages per second from one guest (burst of two seconds).                                 |
| `app_bytes_per_s`  | `524288` (512 KB) | Bytes per second from one guest, counted after decompression.                                  |
| `app_burst_bytes`  | `6291456` (6 MB)  | How many bytes a guest may send at once while the "bucket" is full. At least `app_max_unpack`. |
| `resync_gap_ms`    | `250`             | The host listens to a section-healing request at most once per this many milliseconds.         |
| `resync_burst`     | `6`               | How many healing requests in a row are allowed.                                                |
| `resync_refill_ms` | `5000`            | One request returns to the budget every this many milliseconds.                                |
| `lag_kick_ms`      | `15000`           | How many milliseconds a player may hold up world steps (lagging, silent or lying in reports) before the host cuts its link. After three such cases entry is closed for a minute. |
| `max_lobby_cmd_bytes` | `1024`         | The longest lobby command from a guest before parsing, in bytes. |
| `max_chat_bytes`   | `2048`            | The longest chat line from a guest before parsing, in bytes. |
| `max_time_cmd_bytes` | `256`           | The longest time command from a guest before parsing, in bytes. |
| `max_resync_bytes` | `8192`            | The longest healing request before parsing, in bytes. |
| `max_frag_bytes`   | `8388608` (8 MB)  | The largest message assembled from chunks. |
| `max_roster`       | `0`               | How many distinct players the host remembers per game. 0 means `max_players * 4`, at least 16. |

## What you can send

Put only plain values in `data`. Objects (nodes, resources, scripts) never travel over the network: that way another player cannot send you a malicious object.

| Type                                                                | Allowed?             | Note                                                              |
|---------------------------------------------------------------------|----------------------|-------------------------------------------------------------------|
| `null`, `bool`, `int`, `float`, `String`                            | ✅                   | `StringName` arrives as `String`                                  |
| `Array`, `Dictionary`                                               | ✅                   | Nesting up to 48 levels. Dictionary keys must be plain values too |
| `PackedByteArray`                                                   | ✅                   | Sent as is: handy for your own binary formats                     |
| `PackedInt32/64Array`, `PackedFloat32/64Array`, `PackedStringArray` | ✅                   | Arrive as a plain `Array`                                         |
| `Vector2`, `Vector3`, `Color`, `Vector2i`                           | ✅                   | `Vector2/3` and `Color` are sent with float32 precision           |
| `Rect2`, `Transform`, `Quaternion` and others                       | ❌ arrives as `null` | Break them into numbers or arrays                                 |
| `Object`, `Node`, `Resource`, `Callable`                            | ❌ arrives as `null` | Send an id or a name, not the object itself                       |

### Limits

| What                                         | Limit                                                                                    | What happens above it                                                                                                                        |
|----------------------------------------------|------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| One mod message after decompression          | 4 MB (`app_max_unpack`)                                                                  | The sender's link is cut. Split large data yourself                                                                                          |
| Compression                                  | Turns on automatically for messages from 4 KB                                            | nothing                                                                                                                                      |
| Message type                                 | Any string; the convention is `"mod_id.what"`                                            | nothing                                                                                                                                      |
| `send()` and `broadcast()` rate from a guest | about 50 messages per second and 512 KB per second (`app_msgs_per_s`, `app_bytes_per_s`) | The host cuts the guest's link. In practice 10-20 messages per second per player is fine; 60 per second with large messages is already a lot |
| An `action()` order                          | up to 700 bytes, kind up to 40 characters, ~20 per second (burst 40)                     | Rejected: `illegal` or `rate`                                                                                                                |
| Chat `chat()`                                | 300 characters, about 6 lines in a row                                                   | Line dropped, the author gets `rate`                                                                                                         |

> **The limits apply to guests.**
>
> The host sends to its guests without these limits, but remember that every "to everyone" message from a guest is forwarded by the host to each of the others.

> **Validate what arrives.**
>
> Data comes from another person, who may have a different mod version or a bug. Always check the type: `if data is Dictionary:`, `if data is Vector2:`. Do not trust numbers blindly: check that a coordinate is inside the map and a count is not negative.

## Errors and what to do about them

An error arrives as a string code: from `host()` or `join()` (if it failed immediately), in the `failed(code)` signal and in `last_notice.code`. For every code the library ships two ready texts in Russian and English: `paxnet_err_CODE` (what happened) and `paxnet_err_CODE_do` (what to click).

``` gdscript
func _on_failed(code: String) -> void:
    var what: String = tr_key("paxnet_err_" + code)        # "No such code, or the invite has expired."
    var todo: String = tr_key("paxnet_err_" + code + "_do") # "Check the code with your friend…"
    game.toast(what + " " + todo)
```

> **Where errors arrive.**
>
> Connection and join errors (`code`, `full`, `relay`, `timeout`, `host_left`, `kicked`, `version`, `mods`, `started`, `no_route`, `pin`, `desync`) arrive in the `failed` signal. Refusals of individual actions (`illegal`, `host_only`, `rate`) do not break the game: they arrive in your adapter's `on_notice` method and in the `action_rejected` event.

| Code         | When it happens                                                                                                                                                        | What the player sees                                            | What to do                                                                                   |
|--------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------|
| `version`    | The guest has a different PaxNet protocol version than the host.                                                                                                       | Your online version differs from the host's.                    | Update the game to the host's version and join again.                                        |
| `mods`       | The host set cfg.mods and the guest's mods string differs.                                                                                                             | Your mod set does not match the host's.                         | Enable the same mods as the host and join again.                                             |
| `full`       | The game (including the host) already has max_players people, or the relay said the room is full.                                                                      | There are no free spots in the game.                            | Ask the host to free a spot.                                                                 |
| `code`       | The input is not a code (wrong characters, length) or no such room exists.                                                                                             | No such code, or the invite has expired.                        | Check the code with your friend or ask for a new invite.                                     |
| `banned`     | Reserved: the library does not issue this code at the moment.                                                                                                          | The host has barred you.                                        | Message the host.                                                                            |
| `started`    | The game is running and the host has join_in_progress = false. Players returning with their key always get in.                                                         | The game is already on; the host's rules close entry.           | Ask the host to allow joining a game in progress.                                            |
| `seat_taken` | choose_seat on a seat that already has a player.                                                                                                                       | Another player already controls this country.                   | Pick another country or become a co-ruler.                                                   |
| `timeout`    | No packets from the host for more than 15 seconds and returning failed.                                                                                                | No word from the host for a while: the connection is lost.      | The game tries to return by itself. You can click "Rejoin": you will return to your country. |
| `kicked`     | The host called kick(id).                                                                                                                                              | The host removed you from the game.                             | Message the host.                                                                            |
| `host_left`  | The host left (leave) or their room no longer exists on the relay.                                                                                                     | The host closed the game.                                       | Wait until the host starts it again and join with the same invite.                           |
| `illegal`    | An order or command against the rules: wrong phase, no seat, order kind too long, an invalid deal amount (negative, above the treasury, not a number).                 | Order rejected: that is not allowed.                            | Read the reason in the order window and fix the order.                                       |
| `host_only`  | A guest tries to do something only the host may: move time with time_mode "host", change rules.                                                                        | The host controls time in this game.                            | Ask the host to pause or change speed.                                                       |
| `rate`       | Too often: more than ~40 orders in a row or ~6 chat lines within a few seconds.                                                                                        | Too many commands in a row.                                     | Wait a second.                                                                               |
| `bad_packet` | Reserved: corrupted packets are dropped silently.                                                                                                                      | Corrupted data arrived.                                         | If it happens again, rejoin.                                                                 |
| `desync`     | The world could not be installed: the adapter's install_world returned false.                                                                                          | Your world diverged from the host's and did not heal by itself. | Click "Rejoin" and the world will arrive again in a few seconds.                             |
| `no_route`   | The handshake with the host did not complete within 8 seconds. Most often the guest joined without the PIN or with a wrong one: the host silently drops such attempts. | The host is not responding.                                     | Check that the invite was copied whole, with the PIN (`CODE#PIN`), and click "Rejoin".       |
| `pin`        | The host's key does not match the fingerprint in the invite: the connection may be intercepted, or the invite is left over from a previous game (the host's key is created anew at every launch). | The host's key does not match your invite. | Do not join. Ask the host for a fresh invite over a channel you trust. |
| `relay`      | No Network.relay_pipe() in the game, or the relay refused or did not respond (the host waits 20 s, a guest 10 s).                                                      | The Pax Universe relay is unavailable.                          | Check your internet and game version and try again in a minute.                              |

## Ready-made solutions: copy and adapt

In the examples `lib` is the library and `net` is a session from `lib.new_session()`. Message types start with `my_mod.`: replace it with your mod id.

### 1. Real-time player positions

Each player tells everyone where they are 10 times per second. That is enough for smooth motion: between messages, smooth the position locally, for example with `lerp`.

``` gdscript
const MSG_POS: String = "my_mod.pos"
var _pos_timer: float = 0.0
## Where the other players are now: player id → position.
var others: Dictionary = {}

## Call every frame from your _process: broadcasts your position 10 times per second.
func send_my_position(delta: float, my_pos: Vector2) -> void:
    _pos_timer += delta
    if _pos_timer < 0.1 or not bool(net.call("active")):
        return
    _pos_timer = 0.0
    net.call("broadcast", MSG_POS, my_pos)   # to everyone except yourself

## From the message signal handler.
func on_position(from_id: int, data: Variant) -> void:
    if data is Vector2:
        others[from_id] = data
```

### 2. Turn-based play: the host is the judge

The most robust scheme for turn-based games and anything where cheating is possible. A guest only *asks* to make a move. The host checks the rules and broadcasts the new state. Guests trust only the host.

``` gdscript
const MSG_MOVE: String = "my_mod.move"     # guest → host: "I want to move"
const MSG_STATE: String = "my_mod.state"   # host → all: "here is the board now"
var board: Dictionary = {"turn": 0, "cells": {}}

## The player clicked a cell.
func try_move(cell: Vector2i) -> void:
    if bool(net.call("is_host")):
        _judge(1, cell)                          # the host judges its own moves too
    else:
        net.call("send", 1, MSG_MOVE, cell)      # a guest only asks

func on_judge_message(from_id: int, type: String, data: Variant) -> void:
    if type == MSG_MOVE and bool(net.call("is_host")) and data is Vector2i:
        _judge(from_id, data)
    elif type == MSG_STATE and from_id == 1 and data is Dictionary:
        board = data                             # a guest trusts only the host

func _judge(player_id: int, cell: Vector2i) -> void:
    var cells: Dictionary = board["cells"]
    var key: String = "%d,%d" % [cell.x, cell.y]
    if cells.has(key):
        return                                   # cell taken: move rejected
    cells[key] = player_id
    board["turn"] = int(board["turn"]) + 1
    net.call("broadcast", MSG_STATE, board)      # all guests get the new board
```

> **Why this way.**
>
> If everyone changes the shared state themselves and broadcasts it, two players may move at the same time and end up with different boards. When one host decides, there is one truth.

### 3. Shared dice: randomness that is the same for everyone

A plain `randi()` gives each player something different. `lib.rng(seed, step, "stream")` gives everyone the same result when all three inputs match: on any computer and any engine version.

``` gdscript
## A die that rolls the same for every player. The host hands out seed once at the start
## of the game (for example in a "my_mod.seed" message); turn is the turn number.
func roll_dice(seed: int, turn: int) -> int:
    var r: RefCounted = lib.call("rng", seed, turn, "my_mod/dice")
    return int(r.call("irange", 1, 6))
```

Generator methods: `next_u32()`, `frand()` (0 to 1), `irange(a, b)` (an integer from a to b inclusive), `chance(p)`, `pick(array)`.

### 4. Room of the day

Everyone playing today lands in the same room without exchanging codes: the code is computed from the day number. Since the code is known to everyone in advance, such a room cannot have a secret PIN, so the host opens it with `"pinned": false` and guests join with the code alone.

``` gdscript
## Room of the day: every player gets the same code today. The first to arrive opens it,
## the rest join. A room without a PIN: a code known to everyone in advance is not a secret.
var _daily_code: String = ""

func enter_daily_room(my_name: String) -> void:
    _daily_code = str(lib.call("shared_code", int(lib.call("utc_day")), "my_mod/daily", "MM"))
    net.connect("failed", _on_daily_failed, CONNECT_ONE_SHOT)
    net.call("join", _daily_code, my_name)

func _on_daily_failed(code: String) -> void:
    if code == "code":
        # no such room yet: open it ourselves with this code, without a PIN
        net.call("host", "Daily", null, {"want_code": _daily_code, "max_players": 16, "pinned": false})
```

> **The price of convenience.**
>
> In a room without a PIN the packet contents are still encrypted, but there is no protection against active key swapping on the relay. Do not send anything in such rooms that must stay secret from the relay. Details in [Security](#what-is-protected-and-how-it-works).

### 5. On-screen status line

One line at the top of the screen with the code, players and ping. On an error a window appears with an explanation and a "Rejoin" or "OK" button. The library takes the texts from its own translations.

``` gdscript
## Status line at the top of the screen: code, players, ping, a clear error with a "Rejoin" button.
func show_status_line(game: PaxGame) -> void:
    lib.call("overlay", net, game.hud_layer())
```

### 6. Raw channel: your own protocol end to end

If PaxNet sessions do not suit you (doom_2 is built this way), use the relay channel directly. Then ordering, duplicates, reconnection and encryption become your job. The game channel is already reliable and ordered, but on a disconnect everything in flight is lost.

``` gdscript
## Raw relay channel without PaxNet sessions: the whole protocol is on you
## (doom_2 is built this way). In the channel the host is 1, guests are 2, 3…; 0 means "all guests".
var pipe: Object = null
var RP: Script = null

func open_raw_room() -> void:
    RP = lib.call("script_of", "RelayPipe")
    pipe = lib.call("open_pipe", {"op": "host", "name": "my room", "public": false, "max": 4,
        "ai": "", "preset": "my_mod", "host_name": "Host", "code": ""})
    if pipe == null:
        push_warning("relay: " + str(lib.call("pipe_detail")))
        return
    RP.call("wire", pipe, self, "_raw_")      # channel signals → _raw_lobby_ready etc.

func _raw_lobby_ready(code: Variant, _rules: Variant = null) -> void:
    print("room code: ", code)

func poll_raw() -> void:                          # every frame
    RP.call("poll", pipe)
    while true:
        var pk: Array = RP.call("recv", pipe)     # [sender, bytes] or []
        if pk.is_empty():
            break
        var d: Dictionary = lib.call("decode", pk[1])
        if bool(d["ok"]):
            print("from ", pk[0], ": ", d["v"])

func raw_send_all(value: Variant) -> void:
    RP.call("send", pipe, 0, lib.call("encode", value))
```

## Your own world: checks and healing

> **Do you need this?**
>
> If messages are enough for your mod, no: skip this section. It is for when all players must have the *same large world*: a map, an economy, armies. PaxNet watches that worlds do not diverge and repairs them.

### The idea

The world is split into **sections**, named dictionaries (`"score"`, `"map"`, `"units"`). Each section gets a **checksum**. The host broadcasts its checksums. A guest compares them with its own. If section `"map"` does not match, the guest quietly asks the host for *that section only*. The host sends it, the guest inserts it, and the world is identical again; the game never stopped.

### Two modes

- **The host computes the world authority: true**: The host changes the world and calls `record_step()`. Guests receive only the changes (a diff) along with checksums. Guests compute nothing themselves. Suits almost everyone.
- **Everyone computes the same authority: false**: Every step everyone gets identical orders, day count and randomness. Each player recomputes the world, and checksums catch divergences (as in Factorio). Requires strictly deterministic code.

### The adapter: your world for PaxNet

The adapter is an object with methods PaxNet calls by name. You do not need to inherit anything from the library (and you cannot: the sandbox rejects a foreign `extends`). What matters is that **all the methods exist**. Here is a complete working example: a world with scores and a flag.

> **New method can_afford.**
>
> Starting with this version, the player mailbox validates the amount of trade deals. For that it calls `adapter.can_afford(seat, amount)`: whether the seat's treasury covers the amount. If your world has no treasury, just return `true`. The method is in the example below too. Without it, "trade" deals fail on an adapter that lacks the method.

``` gdscript
extends RefCounted
## A world for sync checks: player scores and a flag on the map. The PaxNet core calls these
## methods by name, so you do not need to inherit the library's Adapter.gd: it is enough that all methods exist.
## The host computes the world (cfg "authority": true): guests receive changes as diffs and compare checksums.

## World sections: name → plain data (numbers, strings, arrays, dictionaries).
var sections: Dictionary = {"score": {}, "flag": {"owner": "", "x": 0, "y": 0}}
var day: int = 0
## Where the mod reports changes (optional).
var on_changed: Callable = Callable()


# ---------- the world as a set of sections ----------

func section_names() -> Array:
    return ["flag", "score"]


func section_period(_name: String) -> int:
    return 1


func hashes(_tick: int, _all: bool = false) -> Dictionary:
    var h: Dictionary = {}
    for n in sections:
        h[n] = _hash(sections[n])
    return h


func hashes_view(_view: Variant, tick: int, all: bool = false) -> Dictionary:
    return hashes(tick, all)


func section_data(names: Array) -> Dictionary:
    var out: Dictionary = {}
    for n in names:
        if sections.has(n):
            out[n] = (sections[n] as Dictionary).duplicate(true)
    return out


func section_data_view(_view: Variant, names: Array) -> Dictionary:
    return section_data(names)


func apply_sections(data: Dictionary) -> void:
    for n in data:
        sections[n] = data[n]
    if on_changed.is_valid():
        on_changed.call()


func world_snapshot_view(_view: Variant) -> PackedByteArray:
    return var_to_bytes({"s": sections, "d": day})


func install_world(bytes: PackedByteArray) -> bool:
    var v: Variant = bytes_to_var(bytes)
    if not (v is Dictionary) or not (v as Dictionary).has("s"):
        return false
    sections = (v as Dictionary)["s"]
    day = int((v as Dictionary)["d"])
    if on_changed.is_valid():
        on_changed.call()
    return true


func view_of(_seat: int) -> Variant:
    return ""


func begin_views(_tick: int) -> void:
    pass


# ---------- game flow ----------

func current_day() -> int:
    return day


func advance(days: int, _tick: int, _world_seed: int) -> void:
    day += days


func action_policy(_kind: String) -> String:
    return "free"


func execute_action(_actor: Dictionary, _action: Dictionary, _ctx: Dictionary) -> Dictionary:
    return {"ok": false, "code": "illegal", "text": ""}


func apply_event(_ev: Dictionary) -> void:
    pass


func apply_deal(_kind: String, _from_seat: int, _to_seat: int, _terms: Dictionary) -> Dictionary:
    return {"ok": true}


## Whether the seat's treasury covers the amount of a trade deal. This world has no treasury.
func can_afford(_seat: int, _amount: float) -> bool:
    return true


func auto_reply(_kind: String, _from_seat: int, _to_seat: int, _terms: Dictionary) -> bool:
    return false


func countries() -> Array:
    return [{"id": 0, "name": "red"}, {"id": 1, "name": "blue"}]


# ---------- player-facing output (does not affect the world) ----------

func on_news(_e: Dictionary) -> void:
    pass


func on_ai_result(_e: Dictionary) -> void:
    pass


func on_action_result(_actor: Dictionary, _action: Dictionary, _result: Dictionary) -> void:
    pass


func on_chat(_from_id: int, _name: String, _text: String) -> void:
    pass


func on_notice(_code: String, _args: Dictionary) -> void:
    pass


func on_roster_changed(_players: Array) -> void:
    pass


func on_progress(_what: String, _ratio: float) -> void:
    pass


func on_time_state(_state: Dictionary) -> void:
    pass


# A hash that does not depend on dictionary key order (custom, because hash() of a dictionary does).
static func _hash(v: Variant) -> int:
    if v is Dictionary:
        var sum: int = 13
        for k in v:
            sum += hash(str(k)) * 31 + _hash((v as Dictionary)[k])
        return sum & 0xFFFFFFFF
    return hash(v) & 0xFFFFFFFF
```

### How to use it

``` gdscript
var world: RefCounted = load("res://mods/my_mod/ScoreWorld.gd").new()

func host_world() -> void:
    net.host("Anna", world, {"authority": true, "external_time": true})

func join_world(invite: String) -> void:
    var my_world: RefCounted = load("res://mods/my_mod/ScoreWorld.gd").new()
    net.join(invite, "Boris", my_world)        # invite: CODE#PIN. The guest has its own instance; PaxNet fills it

# The host changed something in the world: record a step, guests receive the changes.
# Works only after net.start(): in the lobby record_step does nothing.
func add_point(player: String) -> void:
    var score: Dictionary = world.sections["score"]
    score[player] = int(score.get(player, 0)) + 1
    var core: Object = net.session
    core.record_step(0)                         # 0 days: a step with changes only
```

### Adapter methods: what each must do

| Method                                                                                                     | What to return or do                                                                                                                                                        |
|------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| section_names() → Array                                                                                    | Section names                                                                                                                                                               |
| section_period(name) → int                                                                                 | Check the section every N steps (heavy ones less often). Usually 1                                                                                                          |
| hashes(tick, all) → Dictionary                                                                             | Checksum of each section: `{name: number}`. It must not depend on key order                                                                                                 |
| hashes_view(view, tick, all)                                                                               | Same for a player's "view". If there is one view for everyone, call `hashes`                                                                                                |
| section_data(names) → Dictionary                                                                           | Full copies of sections: `{name: data}`                                                                                                                                     |
| section_data_view(view, names)                                                                             | Same for a view                                                                                                                                                             |
| apply_sections(data)                                                                                       | Insert received sections into your world (healing and changes)                                                                                                              |
| world_snapshot_view(view) → PackedByteArray                                                                | The whole world as bytes (for a joining guest)                                                                                                                              |
| install_world(bytes) → bool                                                                                | Install the world from bytes. `false` if it failed (`desync` error)                                                                                                         |
| view_of(seat) → Variant                                                                                    | The "view" key of the world for a seat. If there is one view for everyone, return `""`                                                                                      |
| begin_views(tick)                                                                                          | The host calls it before computing views (for caching). May be empty                                                                                                        |
| current_day() → int                                                                                        | Current day or world turn number                                                                                                                                            |
| advance(days, tick, seed)                                                                                  | "Everyone computes" mode: simulate the days. Take randomness only from `rng(seed, tick, …)`                                                                                 |
| action_policy(kind) → String                                                                               | Who may issue the order: `"own"` (the seat owner), `"free"` (anyone), `"host"` (host only)                                                                                  |
| execute_action(actor, action, ctx) → Dictionary                                                            | Execute an order: `{ok, code, text}`. In "everyone computes" mode it is called on everyone                                                                                  |
| apply_event(ev)                                                                                            | A system event: a seat was taken, a country is run by the AI                                                                                                                |
| apply_deal(kind, from, to, terms) → Dictionary                                                             | A deal between players (trade, alliance, war) was executed                                                                                                                  |
| can_afford(seat, amount) → bool                                                                            | Whether the seat's treasury covers a trade deal amount. No treasury: return `true`. The core mailbox itself rejects negative amounts, non-numbers and amounts above the cap |
| auto_reply(kind, from, to, terms) → bool                                                                   | The answer of a seat run by the AI                                                                                                                                          |
| countries() → Array                                                                                        | Lobby seats: `[{id, name}]`                                                                                                                                                 |
| on_news, on_ai_result, on_action_result, on_chat, on_notice, on_roster_changed, on_progress, on_time_state | Display only; they do not affect the world. May be empty                                                                                                                    |

> **Common mistake.**
>
> Computing a dictionary checksum with the built-in `hash(dictionary)`. It depends on the order in which keys were added and gives two players different numbers for identical data. Then healing will fire endlessly. Use `lib.state_hash(v)` or a sum over pairs, as in the example.

### Deals between players

The core mailbox (letters of kind `war`, `peace`, `alliance`, `trade`, `coruler`, `letter`) checks trade deals twice: when the letter is sent and when the deal is executed. The amount (`terms.amount`) must be a number from zero up to 10<sup>12</sup>. A deal runs in two steps: the host asks the **giver** to debit the amount, the giver answers, and only after that confirmation does the recipient get the money. A confirmation is accepted once and only from the giver. A deal with a negative amount is rejected with `illegal`.

> **Limit of the protection.**
>
> A guest's treasury lives on the guest and the host does not verify it. An honest client debits and confirms. A modified client can confirm a debit that never happened. Only a treasury check on the host side would stop that (this architecture has none), so in games that need to be cheat-proof, deals between players remain trust-based.

## A game in the world of Pax Universe itself

The library includes ready-made world sync for the Pax Universe strategy game, the reason PaxNet was created. It is `lib.world_service()`: a session with the `GameAdapter` adapter. Sections are the keys of the game's save record. The world is projected for each guest's country. Province owners are healed through the stable API.

| Call                                                                                                                                 | What it does                                                                                                                                       |
|--------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| `world_service().host_open(name, rules)`                                                                                             | The host opens a game of its world and takes its own country. World steps run by themselves as the game proceeds (the `Pax.world_stepped` signal). |
| `world_service().host_start()`                                                                                                       | Guests receive the world into the network save slot and open it.                                                                                   |
| `world_service().guest_join(invite, name)`                                                                                           | Join someone else's world. Invite: `CODE#PIN` or a link.                                                                                           |
| console <span class="kbd">F8</span>: `paxnet host Name`, `paxnet join CODE#PIN Name`, `paxnet start`, `paxnet state`, `paxnet leave` | The same, for manual testing.                                                                                                                      |

> **Careful.**
>
> This part relies on game internals (`res://src/net/Seats.gd`, `res://src/save/Save.gd`, `game.main`). They may change in another game version. Then `world_service()` returns `null` and writes a warning to the log. The rest of the library keeps working.

In such a game each player runs their own country, so its sections (orders, laws, treasury) are not healed from the host; otherwise the guest's actions would be rolled back. Consistency is kept by the shared sections: date, powers, province owners, armies, wars, chronicle, market. A saved game stores the room code and PIN, so after the host restarts, old invites keep working.

## Not working? Frequently asked questions

#### lib == null: the library cannot be found

Check three things. 1) The "PaxNet Core" mod is enabled in the launcher and the game was restarted afterwards. 2) Your mod's `mod.json` has `"depends": ["paxnet_core"]`. 3) You fetch the node with `Pax.get_tree().root.get_meta("paxnet_lib", null)`, not with `get_node("/root/PaxNetLib")` at the very start: the node enters the tree one frame later, while the metadata is available immediately.

#### host() returned "relay" or the status is failed right away

The library did not find the game's relay channel. Causes: the game is old and has no `Network.relay_pipe()`; no internet; the relay is temporarily down. Print `lib.pipe_detail()`: it says what was found instead of the channel. The host waits 20 seconds for a room, a guest 10 seconds to join.

#### My friend enters the code, waits and gets "The host is not responding" (no_route)

Almost always this means the friend joined **without the PIN** or with a wrong one. The host does not answer anyone who does not know the PIN, on purpose. Send the invite whole: the link from `invite_link()` or `CODE#PIN` from `invite_code()`. If you opened the room with `"pinned": false`, no PIN is needed and the error means something else (internet, relay).

#### There is a code, but my friend gets "No such code"

A room lives while the host is in the game and has not called `leave()`. Check the code in the field above: codes never contain `0`, `O`, `1`, `I`. If the host restarted the game without continuing a saved game, the code may have changed: ask for a new invite.

#### A message was sent, but the message signal does not fire

1\) You never receive your own messages: the host does not get its own `broadcast`. 2) Is the signal connected to the same session the game runs through? A common mistake: calling `new_session()` twice and connecting the signal to the second one. 3) Do you compare `type` with the same string you sent? `"my_mod.chat"` and `"my_mod_chat"` are different types. 4) A guest sent before entering the room: such a message is not lost, it goes out after joining.

#### A player was thrown out after a burst of messages

The host cuts the link of a guest who sends more than about 50 messages per second or more than 512 KB per second (see the [limits](#room-settings)). The player can join again and returns to their seat. If your mod honestly sends more, combine data into one message or send updates less often.

#### null arrived instead of my data

You sent something that does not travel over the network: an object, node, resource, Callable, Rect2, Transform. See the ["What you can send"](#what-you-can-send) table: break the data into numbers, strings, arrays and dictionaries.

#### Compile error "Cannot infer the type…"

The game forbids `:=` when the right-hand side is untyped: a `call()` result, a dictionary or array element. Write the type explicitly: `var net: Node = lib.new_session()`, `var hp: int = data["hp"]`.

#### The mod does not start: the sandbox check complains about preload

You may not `preload("res://mods/paxnet_core/…")` from your mod: the sandbox allows loading only from paths of *your own* mod. Get everything through the library node: `lib.script_of("Bytes")`, `lib.encode()` and so on.

#### My friend lost internet for a minute. What happens?

The status becomes `reconnecting`. PaxNet re-enters the room by itself, up to 8 attempts with increasing pauses. The player returns with the same number, and everything sent to them meanwhile arrives exactly once and in order. Meanwhile the host sees `away = true` for the player. If returning fails, the status becomes `failed` and a "Rejoin" button appears (`rejoin()`).

#### My friend closed the game and came back. Will they get their seat back?

Yes, if they join with the same invite from the same computer. The host recognises them by the room key that the player derives from their own key and this room's code. They get the same number and seat, and if there is a world, the world too: whole, or only the missed steps.

#### How many players are possible?

By default 5 people including the host (`max_players`). Technically more, but every message goes through the host, and with 10-16 players message frequency starts to matter.

#### Can I play without internet, over a LAN?

No. The mod sandbox does not allow custom sockets, so all traffic goes through the game relay. Every player needs internet.

#### How do I build a lobby window with a player list?

Connect to the `changed` signal and in the handler redraw the list from `net.players()`: name, `ready`, `ping`, `away`. Take the invite for friends from `net.invite_link()` (with the PIN) or `net.invite_code()`; the host's "Start" button calls `net.start()`.

## The sandbox: why things work the way they do

Pax Universe checks every mod **before** launch and refuses to run a mod that breaks the security rules. This protects players from harmful mods. PaxNet and your mod must follow the same rules.

| Not allowed                                        | Why                                                                    | Use instead                                                  |
|----------------------------------------------------|------------------------------------------------------------------------|--------------------------------------------------------------|
| Sockets, HTTP, WebSocket, UPnP                     | A mod must not go online by itself                                     | The game channel `relay_pipe()`: PaxNet uses only that       |
| `FileAccess`, `DirAccess`, `ConfigFile`, `user://` | A mod must not touch the player's files                                | `save_data()`/`load_data()`, `get_setting()`/`set_setting()` |
| `ClassDB`, `Expression`, `GDScript`, `str_to_var`  | They can execute foreign code                                          | Ordinary calls; the PaxNet codec for data                    |
| `preload` of a foreign path, `..` in a path        | A mod sees only its own folder                                         | `lib.script_of("Name")`, library methods                     |
| `var x := dict["a"]`                               | The game's strict typing: a type is not inferred from an untyped value | `var x: int = dict["a"]`                                     |
| Player-facing text in code                         | The game is multilingual                                               | `data/lang/ru.json`, `en.json` and `tr_key()`                |
| Executable files (`.sh`, `.exe`, `.dll` and so on) | A mod ships only as text and data                                      | Keep developer scripts with a `.txt` suffix                  |

> **For mod developers.**
>
> Test scripts that need forbidden calls (`get_tree().quit()`, `res://tests/…`) cannot live inside the mod folder: the check will find them and refuse to run the mod. In the PaxNet repository the tests are stored with a `.txt` suffix and started by a separate script that builds a temporary project.

## What is protected and how it works

> **In short.**
>
> Everything players send each other is encrypted end to end: the relay sees only ciphertext. The invite PIN catches the relay trying to swap encryption keys. Your permanent player key never leaves your computer. The host limits how much junk a single guest can send.

### Encryption

1.  **The host presents a public key**

    Once per launch the host creates an RSA-1024 key pair and gives the public half to everyone who knocks.

2.  **The guest invents a secret**

    The guest creates a random secret (32 bytes) and sends it to the host, encrypted with the public key. Only the host can decrypt it.

3.  **The secret is bound to the PIN**

    Before the secret becomes working keys, it is mixed with the invite PIN (HMAC). Only the host and the people it was sent to have the PIN. It never reaches the relay.

4.  **Everything after is encrypted**

    The name, the room key and the host's welcome are encrypted with the secret. Every link packet is encrypted with AES-128 (CBC mode, a random IV per packet) and signed with HMAC-SHA256. The heavy RSA step happens once at join; packets cost almost nothing.

### What it protects against

| Threat                                                                                      | Protection                                                                                                                                                                                                |
|---------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Someone on the network or the relay reads packets                                           | AES-128 encryption. They cannot be read.                                                                                                                                                                  |
| Someone forges or replays packets                                                           | An HMAC signature on every packet; packet numbers drop replays.                                                                                                                                           |
| The relay swaps the host's public key ("man in the middle") | The host key fingerprint inside the invite. The guest compares the key it receives with the fingerprint before sending the secret and refuses to join on a mismatch (`pin`). A key with a matching fingerprint (60 bits) cannot be produced, and there is nothing to brute-force the PIN against: the middleman never gets the secret. |
| A guest stays silent or lies in progress reports and holds up world steps for everyone | Reports can neither go back nor look into the future, and a player who holds steps longer than `lag_kick_ms` is disconnected. |
| A guest takes another player's country as co-ruler without consent | A co-ruler seat needs the seat owner's invite. The seat number is checked against the adapter's countries. |
| A guest floods the host with time votes | A rate limit on time commands, at most 8 open votes, the value is coerced to a number, only players with a country vote. |
| A guest sends huge or deeply nested structures | A size cap per message type before parsing, a parse budget by element count, nested chunks are forbidden. |
| Many join attempts make the host do RSA | A shared RSA operation bucket, an address is refused after four failures in 10 seconds, a cap on remembered players. |
| The relay mirrors a packet back to its sender | Signing and cipher keys differ per direction, so a packet returned to its sender fails verification. |
| The relay replays old packets | A 32-bit packet number under the signature; packets older than a 32-packet window are dropped. |
| A malicious host sends a guest a gigantic world or a section of the wrong shape | Size ceilings for transfers and the unpacked world, type checks of sections before applying. |
| The host of another room or the relay wants to enter another room as you and take your seat | A host never receives your player key, only a key for that one room: `HMAC(player key, room code)`. In another room it is useless.                                                                        |
| One guest floods the host with messages or giant "compression bombs"                        | A size cap after decompression (4 MB), a cap on number run-ahead, a per-guest rate and volume limit, a budget for section healing. The offender loses the link. See the [limit settings](#room-settings). |
| A deal with a negative amount takes money from the recipient                                | The deal amount is checked on sending and on execution: a number from zero, within the cap, within the giver's treasury.                                                                                  |
| A seat tag in the world reveals a player key to other guests                                | Only an irreversible tag, not the key, appears in seat events and the shared seat list.                                                                                                                   |

### What it does not give you

> **Honest limitations.**
>
> - **Rooms without a PIN** (`"pinned": false`, for example a "room of the day") are not protected against active key swapping on the relay: a code known in advance is not a secret. Their packets are still encrypted against anyone who merely listens.
> - **The host sees everything.** Encryption runs between a player and the host. By definition the host decrypts everything sent to it and forwards it to the others.
> - **Guard the invite.** Anyone who saw the invite together with the PIN (for example in a public chat) can join the room as an ordinary guest.
> - **The raw channel** (`open_pipe`, recipe 6) bypasses PaxNet encryption: protect your own protocol yourself.
> - **A guest's treasury and client honesty.** Money and other sections of a guest's country live on the guest. A modified client can lie about its treasury (see the section on deals).
> - **A save file contains the PIN.** The host's save stores the room PIN so old invites keep working after a restart. The permanent player key no longer goes in. Do not publish a save while the room is still needed.
> - **Discord.** If a mod shows the invite with the PIN in Discord status, Discord servers and everyone who sees the profile can see the PIN.
> - **Lifetime.** RSA-1024 and AES-128 are chosen as light and sufficient for the duration of a game (hours, a day), not for years of stored recorded traffic.

## How PaxNet Core differs from PaxNet

> **PaxNet and PaxNet Core are not the same thing.**
>
> They are two versions of one protocol. **PaxNet** is still in active development and is meant to be built directly into Pax Universe, into the game's own online play. **PaxNet Core** is a library based on PaxNet, made specifically for mods and their multiplayer. It runs inside the mod sandbox and replaces nothing in the game itself.

PaxNet replaces the game's network service and opens a UDP port itself. That is impossible inside the mod sandbox, so for mods its core was moved into a library. Here is what had to change for that.

### For the sandbox

- **No custom sockets.** Removed `UdpSocket`, `WsSocket`, UPnP, NAT punch-through and joining by `ip:port`. Traffic goes through the game channel `Network.relay_pipe()`, the same way as in doom_2. The new `PipeHost` and `PipeGuest` give the core its old interface, so sessions, sync checks and world transfer were not rewritten.
- **The game's network service is not replaced.** A library must not silently change online play for everyone who enabled it, and cannot take away the channel the game itself uses.
- **All paths are full literals** `res://mods/paxnet_core/…`, without `..`.
- `FileAccess.COMPRESSION_ZSTD` replaced with the number `2` (verified against Godot 4.7).

### Security

- **Link encryption:** RSA-1024 at join, AES-128-CBC and HMAC on every packet. The handshake now carries the host's public key, so the guest's first packet (`HELLO`) is padded to 400 bytes.
- **The invite PIN** protects against key swapping on the relay. An invite now looks like `CODE#PIN`; rooms without a PIN are enabled with the setting `pinned: false`.
- **Per-room player key:** the host receives `HMAC(player key, room code)`, and seat events and the shared seat list keep only an irreversible tag.
- **Message channel limits:** size after decompression, number window, per-guest rate and volume, healing budget. Settings: `app_*` and `resync_*`.
- **Deals:** amount validation on sending and on execution, a new adapter method `can_afford`. Trade runs in two steps: the giver debits first, then the recipient is paid.
- **Lag reports, co-ruler, time:** a player can neither stall the steps with a false report, nor take another country without an invite, nor flood votes.
- **The link:** per-direction keys, 32-bit packet numbers, a 16-byte signature, the engine's native HMAC.
- **A guest does not trust the host:** size ceilings and type checks for the incoming world.

### Other

- The shared random generator mixes the stream name with FNV-1a instead of `hash()`. The result is identical on any engine version, but the sequences differ from PaxNet.
- Translation keys renamed to `paxnet_…`; all text moved out of code.
- The link on top of the reliable channel retransmits less: retries no sooner than 400 ms, a keep-alive every 500 ms, disconnect after 15 s of silence.
- The host says goodbye to everyone when leaving. Guests see "The host closed the game" and do not try to return.
- Tests moved out of the mod folder (files with a `.txt` suffix) so the sandbox check passes with no errors.

## MPL 2.0 in plain words

PaxNet is distributed under the **Mozilla Public License 2.0**. The full text is in the `LICENSE` file inside the mod and in the <a href="https://github.com/01Duga01/pax-paxnet-core" rel="noopener" target="_blank">GitHub repository</a>; a short notice sits at the top of every code file.

- **You may**: Use the library in your mod: free or paid, open or closed source.
- **You may**: Copy and distribute PaxNet, including bundled with your mod.
- **You must**: If you **modified PaxNet files**, distribute the modified files under MPL 2.0 with source code too.
- **You need not**: Open the source of **your own** files. A mod that only uses the library may have any license.
- **You may not**: Remove license notices from PaxNet files.

This is a summary, not legal advice. If it matters, read the full license text.

## Protocol

You do not need to know this to use the library. The core protocol version is unchanged (`Proto.VERSION = 1`), but the packet and handshake formats changed because of encryption, so PaxNet Core builds from before and after this update will not connect to each other. Link packets travel as datagrams of the game channel instead of UDP. In the channel the host is number 1, guests are 2 and up. To the core, a guest's address looks like `pipe#number`.

#### Link packet

``` text
0xA7 | conn u32 | flags u8 (bit 0: ack valid) | seq u32 | ack u32 | ack_bits u32     header (18 bytes), in the clear
IV (16 bytes, random) | AES-128-CBC( records… | padding to 16 bytes )                      ciphertext
HMAC-SHA256 (16 bytes) over everything above                                                signature
record: 1 reliable : varint id | u8 type | varint length | body
        2 slot     : u8 type | varint length | body   ("latest value")
        3 oneshot  : u8 type | varint length | body   (no retries: transfer chunks)
```

The signature is checked before decryption. The AES and signature keys are derived from the link key. Acknowledgements ride in every packet: the last received `seq` plus a bitmap of 32 more. Reliable messages are delivered in order and exactly once. Lost ones are resent: quickly (when newer packets are acknowledged) or on the timer `srtt + 4·rttvar`. No more than 6 packets per poll, a packet at most 1200 bytes, of which 32 bytes go to the IV and cipher padding.

#### Handshake

``` text
guest → HELLO(version, nonce_c)                 padded to 400 bytes
host  → CHALLENGE(nonce_c, window, cookie, host RSA public key)    the guest compares its fingerprint with the PIN, otherwise it refuses
                                                cookie = HMAC(host secret, address | nonce_c | window)
guest → CONNECT(nonce_c, window, cookie, secret under RSA, info under the secret)
        info: name, room key, mods, has world, last step, checksum
host  → ACCEPT(conn_id, welcome under the secret) | REJECT(code)
frame: 0xA6 | type | body | CRC32
secret   = HMAC(guest's random secret, "pax-pin|" + PIN)      (no PIN: the random secret itself)
link key = HMAC(secret, cookie | nonce_c | "pax-link")
```

The host performs the RSA decryption only after the cookie is verified, so forged requests cost it nothing. If the guest has the wrong PIN, the host cannot verify the info block and silently drops the attempt. A link is recognised by its signature on any address. So a guest that reopened the channel under a new number continues the same link without a new handshake.

#### Core messages

| \#                | Message                                      | Who → whom                | Delivery                                                                               |
|-------------------|----------------------------------------------|---------------------------|----------------------------------------------------------------------------------------|
| 10                | `LOBBY`: the whole lobby                     | host → all                | reliable, in parts                                                                     |
| 11                | `LOBBY_CMD`: seat, ready, name, rules, start | guest → host              | reliable                                                                               |
| 12                | `CHAT`                                       | anyone → host → all       | reliable                                                                               |
| 20 / 21           | `ACTION` / `ACTION_RESULT`                   | guest ↔ host              | reliable, redundant; deduplicated by number                                            |
| 30                | `CLOSURE`: world step                        | host → all                | reliable, strictly ordered                                                             |
| 31 / 32 / 33 / 34 | `REPORT`, `RESYNC`, `PATCH`, `PATCH_BLOB`    | checks and healing        | slot / reliable; `RESYNC` is budget-limited                                            |
| 40-44             | `WORLD`, `XFER_*`: world transfer            | host → guest              | chunks, selective resend, CRC32                                                        |
| 50 / 51           | `TIME_CMD` / `TIME`                          | guest → host / host → all | reliable                                                                               |
| 60 / 61           | `PING` / `PONG`                              | anyone                    | slot                                                                                   |
| 70 / 71           | `NOTICE` / `BYE`                             | host → guest / anyone     | reliable                                                                               |
| 73                | `FRAG`: a chunk of a large message           | anyone                    | reliable, ordered                                                                      |
| 80 / 81           | `APP` / `APP_ACK`: mod messages              | anyone → host → recipient | numbered, "everything up to N", resend after a drop; size, window and rate are limited |

#### World step (CLOSURE)

| Field            | Meaning                                                          |
|------------------|------------------------------------------------------------------|
| `t`              | step number, grows by 1 without gaps                             |
| `n`              | days elapsed (0 means a step with orders only)                   |
| `iv`             | ms between steps on the host: the guest keeps the same rhythm    |
| `a`              | orders in sequence: `{p, s, r, c, k, g}`                         |
| `ev`, `nw`, `ai` | system events, numbered news, neural-network results             |
| `h`, `p`         | section checksums after the step; the step carries world changes |

## How it was tested

The network test runs real host and guest sessions on a virtual relay with 40 ms latency, and the compile test checks that every library script builds in Godot 4.7 with strict typing, as in the game.

What the network test covers: room, code and PIN; joining via a link with the PIN and via `PAX-…#PIN`; the roster on everyone; 60 messages in order without duplicates; a private A→B message reaching only B; 300 KB byte for byte; ready and start; a guest channel drop with return under the same number, with everything sent during the drop arriving exactly once and in order; the host leaving. For the world: 10 steps as diffs, healing a corrupted section without resending the world, returning to the same seat after a restart, the `ScoreWorld` adapter from this page. Plus join errors.

> **Status of the checks.**
>
> After the latest security changes (encryption, PIN, limits, deal validation) the tests still have to be run in your environment: before a release run both tests and the mod check shown below.

### Run it yourself

The tests live in the repository in the `paxnet-tests` folder and as a separate archive for developers. Test files are stored with a `.txt` suffix so the mod sandbox check does not scan them. To run them use the `run.sh.txt` script: it builds an ordinary Godot project in a temporary folder and starts it. You need `godot` in `PATH`.

[Download the tests](https://drive.google.com/file/d/1s8JAb5v5RnquTrU2xgtFdy8fNsItt4dR/view?usp=sharing) \| [Source code on GitHub](https://github.com/01Duga01/pax-paxnet-core)

``` bash
bash paxnet-tests/run.sh.txt compile   # compile all scripts
bash paxnet-tests/run.sh.txt net       # network test
python3 paxnet-tests/sandbox_scan.py . paxnet_core   # sandbox scanner (findings inside paxnet-tests are expected: those are the tests)
```

### What to check in the game itself

1.  `godot --headless --path <game folder> -- --check-mods paxnet_core`: make sure the real check passes with no errors.
2.  That your game version has `Network.relay_pipe()`. If not, `lib.pipe_detail()` and the log (`[paxnet] relay_pipe not found`) show what was found.
3.  A game in the game world: console <span class="kbd">F8</span>, `paxnet host Name` on one computer and `paxnet join CODE#PIN Name` on another.

## Help PaxNet grow

PaxNet is free and open, and it will stay that way. If the library helped your mod, or you simply want it to keep growing, you can support its development. The money pays for time spent on new features, testing on fresh game versions and this documentation.

> **A donation, not a purchase.**
>
> Nothing is sold or unlocked in return: every PaxNet feature is the same for everyone, whether they donate or not.

The donation form is available on the website: https://paxnet.isroot.in/#en-support
