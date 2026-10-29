# Instructions for AI coding assistants (Claude Code, Cursor, Copilot, Codex…)

This folder is a **Pax Universe mod**. Pax Universe is a grand strategy narrated by an AI: the player runs a
country (or a person, an organisation, a post-nuclear colony) with orders in plain words, and the game itself
computes economy, war, laws, elections, research, the newspaper and the whole Solar System. Built on
**Godot 4.7** with **GDScript**. Read this whole file before writing anything.

## Where things are

| What | Where |
|---|---|
| Mod manifest | `mod.json` (schema: `docs/modding/schemas/mod.schema.json` in the game folder) |
| Mod code entry | `main.gd` — must start with `extends PaxMod` |
| Changes to game data | `data/<file>.patch.json` — mirrors the game's `data/<file>.json` |
| Translations | `data/lang/<code>.json` — merged into the game dictionary |
| Your assets | anywhere in the mod; address them as `res://mods/<id>/…` or `path("…")` in code |
| Full guide | `docs/modding/en/README.md` (RU: `docs/modding/ru/README.md`) |
| API reference | `docs/modding/en/api-reference.md` (generated from code — trust it) |
| Hooks — change what the game does at key moments | `docs/modding/en/hooks.md` (generated from code): order parsed, war declared, law passed, election, research, report… |
| Every game data file, what it holds, who reads it | `docs/modding/en/data-catalog.md` + a JSON schema per file in `docs/modding/schemas/data/` |
| Working examples | `mods/example_theia` (planet + UI + save), `mods/example_alpha_centauri` (star system + arks), `mods/example_galaxy` (known star, galaxy secret, own galaxy, system_generated hook), `mods/example_events` (events without code), `mods/example_voxel` (voxels) |

If the game folder is not open next to the mod, ask the user where the game is installed: the docs,
schemas and the game's own `data/*.json` (the source of truth for field names) are there.

## The three ways to change the game

- **Data** — `data/<file>.patch.json`. Economy (`economy/*.json`), politics (`politics/*.json`: laws, forms of
  government, parties, forces), armies (`unit_branches.json`, `army_models.json`), technology and weapon classes,
  crises, events, map styles — see the data catalog for the full list.
- **Events and decisions without code** — `data/mod_events.patch.json`: conditions + text + options with
  effects, and paid decisions in the Decisions window. Format: `docs/modding/en/07-events-and-decisions.md`;
  example mod `example_events`. Prefer this over code for anything that is "when X, show Y, apply Z".
- **The galaxy** — every star of the galaxy map can be entered; its system is built on the first visit.
  `galaxy.patch.json` (known stars, Local Group galaxies with their own stars), `galaxy_systems.patch.json`
  (real planets of known stars), `galaxy_secrets.patch.json` (easter eggs: own planet + guests). In code:
  `game.galaxy()`, `game.chart_star("млечный:17")`, hook `system_generated` (edit a system before it is built),
  callbacks `_system_charted`, `_secret_found`. Guide: `docs/modding/en/03-planets-and-stars.md` → "The galaxy";
  example mod `example_galaxy`.
- **Your own world map** — a "colour = province" PNG turned into `data/regions2.*` by the studio's 🗺 button
  (`docs/modding/en/08-your-own-map.md`). Do not hand-write `regions2.bin`.
- **Hooks** — `hook("law_passed", func(d): …)` in `main.gd`. The handler gets a Dictionary and may edit it;
  hooks marked [cancel] stop the action with `d.cancel = true`. Full list: `docs/modding/en/hooks.md`.
  Add your own rules to every AI request with the `ai_request` hook (append to `d.system` — the end of the
  prompt, so the provider's prompt cache keeps working).
- **Your own AI calls** — `ask_ai("channel", prompt, data, func(answer): …)`. The game adds world lore, rules
  and the player's language, counts the cost, and returns the parsed JSON. End your prompt with the JSON you
  expect. Limit: 12 requests per minute per mod.

## Hard rules

1. **Never copy a whole game data file** into the mod. Use `*.patch.json` with `$append`, `$edit` + `$match`,
   `$remove`, `$insert_after`, `$replace`, or plain object merge (`null` deletes a key). Otherwise mods conflict.
2. **Game data keys are Russian** (`"тела"`, `"имя"`, `"род"`, `"параметры"`). Copy them exactly from the game's
   `data/*.json`. Do not translate keys. Body names (`"Земля"`, `"Марс"`) are ids — also exact.
3. **No player-visible text in code.** Put it into `data/lang/en.json` and `data/lang/ru.json` (at least these two)
   and read with `tr_key("key")`. Prefix keys with the mod id to avoid collisions.
4. **GDScript is strict here**: inferring a type from an untyped value is a compile error.
   Write `var x: float = dict["a"]`, not `var x := dict["a"]`. Same for results of untyped calls.
5. Use the **stable API** (`PaxGame` methods, `Pax` signals, `PaxMod` callbacks). `game.main`, `game.sim`,
   `game.world`, `game.stock` are raw internals with Russian identifiers — allowed, but may change between versions.
6. Save state only through `_save_state` → `_game_loaded` (JSON types only: no Vector3, no Objects).
7. Textures, sounds and models from the mod load at runtime without Godot import: use `texture()`, `sound()`,
   `model()`, `shader()` helpers (or `Pax.texture(path)`), never `load()` for png/jpg/ogg/glb.

8. **Sandbox — the game refuses to run a mod that breaks these** (checked before loading, shown with file:line):
   - no `OS.execute`/`create_process`/`shell_open`/environment/system paths; no network classes (`HTTPRequest`,
     `HTTPClient`, sockets, WebSocket, UPNP…); no `FileAccess`/`DirAccess`/`ConfigFile`/`ResourceSaver`, no
     `user://`, drive letters or `..` in paths; no `Expression`, `ClassDB`, `GDScript`, `set_script`,
     `Engine.get_singleton`, `str_to_var`; no `res://scripts/…` game scripts, scene changes or `get_tree().quit()`;
     no `.dll/.exe/.pck/.scn/.res` files and no GDScript embedded in `.tscn`.
   - `load()`/`preload()` only with a literal `"res://mods/<id>/…"` path. Everything else — the safe `PaxMod` API:
     `load_resource("x.tscn")`, `read_text("notes.txt")`, `read_bytes()`, `list_files("folder")`,
     `save_data("name", value)` / `load_data("name", default)`, `open_link("https://…")`, `texture()`, `sound()`,
     `model()`, `shader()`, `scene()`, `load_json()`, `get_setting()/set_setting()`.

## Verify your work — always

```
godot --headless --path <game folder> -- --check-mods <mod id>
```
Exit code 0 = no errors. Fix every ERROR and read every WARNING. In the running game press **F8** for the dev
console: `check <id>`, `json res://data/bodies.json` (final data after all patches), `eval game.body_names()`,
`reload` (re-read JSON/text/images without restarting). In the game **F6** reloads mod code and texts.

Enable/disable mods in the launcher → **Mods** (restart applies). Package for sharing: `--pack-mod <id>`.
