extends CanvasLayer
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ОКНО СОСТОЯНИЯ СЕТЕВОЙ ИГРЫ: одна строка вверху (кто в партии, код, пинг, кто поставил паузу),
# полоса передачи мира (игра при этом идёт) и понятная ошибка - что случилось и что нажать.
# Работает с любой сессией net/Session.gd: PaxNetLib.overlay(session, parent).

const Proto = preload("res://mods/paxnet_core/core/Proto.gd")

## net/Session.gd (или game/NetService.gd).
var svc: Node = null
## PaxMod библиотеки - для перевода (tr_key).
var mod: Object = null
var _line: Label
var _bar: ProgressBar
var _box: PanelContainer
var _what: Label
var _do: Label
var _btn: Button
var _copy: Button


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root: VBoxContainer = VBoxContainer.new()
	root.anchor_left = 0.5
	root.anchor_right = 0.5
	root.offset_left = -330
	root.offset_right = 330
	root.offset_top = 6
	add_child(root)
	var row: HBoxContainer = HBoxContainer.new()
	root.add_child(row)
	_line = Label.new()
	_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_line.add_theme_font_size_override("font_size", 13)
	row.add_child(_line)
	_copy = Button.new()
	_copy.text = _t("paxnet_copy_invite")
	_copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(str(svc.call("invite_link"))))
	row.add_child(_copy)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0, 8)
	_bar.show_percentage = false
	_bar.max_value = 1.0
	root.add_child(_bar)
	_box = PanelContainer.new()
	var v: VBoxContainer = VBoxContainer.new()
	_box.add_child(v)
	_what = Label.new()
	_what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_do = Label.new()
	_do.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_do.modulate = Color(0.75, 0.85, 1.0)
	_btn = Button.new()
	v.add_child(_what)
	v.add_child(_do)
	v.add_child(_btn)
	root.add_child(_box)
	_btn.pressed.connect(_on_action)
	if svc != null:
		svc.connect("changed", _on_changed)
		if svc.has_signal("state_changed"):
			svc.connect("state_changed", func(_st: Dictionary) -> void: _on_changed())
	_on_changed()


func _t(key: String) -> String:
	return str(mod.call("tr_key", key)) if mod != null else key


func _on_changed() -> void:
	if svc == null or not is_instance_valid(svc):
		visible = false
		return
	_refresh(svc.call("state"))


func _refresh(st: Dictionary) -> void:
	visible = str(st.get("role", "")) != ""
	if not visible:
		return
	var parts: PackedStringArray = PackedStringArray()
	parts.append(_t("paxnet_role_" + str(st["role"])))
	if str(st.get("code", "")) != "":
		parts.append(_t("paxnet_code") % str(st["code"]))
	parts.append(_t("paxnet_players") % (st.get("players", []) as Array).size())
	if float(st.get("rtt", 0.0)) > 0.0:
		parts.append(_t("paxnet_ping_ms") % int(st["rtt"]))
	var t: Dictionary = st.get("time", {})
	if bool(t.get("paused", false)) and str(t.get("by_name", "")) != "":
		parts.append(_t("paxnet_paused_by") % str(t["by_name"]))
	if str(st.get("status", "")) in ["syncing", "reconnecting", "connecting"]:
		parts.append(_t("paxnet_status_" + str(st["status"])))
	_line.text = "  ·  ".join(parts)
	_copy.visible = str(st.get("code", "")) != "" and str(st.get("role", "")) == "host"
	var pr: Array = st.get("progress", ["", 1.0])
	_bar.visible = str(pr[0]) != "" and float(pr[1]) < 1.0
	_bar.value = float(pr[1])
	var n: Dictionary = st.get("notice", {})
	_box.visible = not n.is_empty()
	if not n.is_empty():
		_what.text = _t(str(n["what"]))
		_do.text = _t(str(n["do"]))
		var code: String = str(n["code"])
		var can_rejoin: bool = str(st.get("role", "")) == "guest" and code in [Proto.ERR_TIMEOUT, Proto.ERR_DESYNC, Proto.ERR_NO_ROUTE, Proto.ERR_RELAY]
		_btn.text = _t("paxnet_btn_" + ("rejoin" if can_rejoin else "ok"))
		_btn.set_meta("code", code)
		_btn.set_meta("rejoin", can_rejoin)


func _on_action() -> void:
	var code: String = str(_btn.get_meta("code", ""))
	var rejoin: bool = bool(_btn.get_meta("rejoin", false))
	svc.set("last_notice", {})
	if rejoin and code == Proto.ERR_DESYNC:
		svc.call("request_full_world")
	elif rejoin:
		svc.call("rejoin")
	_on_changed()
