#!/usr/bin/env python3
"""Approximate Pax Universe mod sandbox checker (rules from AGENTS.md, section 8).

Not the game's checker: a conservative re-implementation used to catch violations before
running `--check-mods`. Usage: sandbox_scan.py <mod_dir> <mod_id>
"""
import os
import re
import sys

mod_dir, mod_id = sys.argv[1], sys.argv[2]

TOKENS = {
    "code": [r"\bOS\s*\.\s*(execute|create_process|create_instance|shell_open|shell_show_in_file_manager|kill|get_environment|set_environment|has_environment|unset_environment|get_executable_path|get_user_data_dir|get_data_dir|get_config_dir|get_cache_dir|get_system_dir)\b",
             r"\bExpression\b", r"\bClassDB\b", r"\bGDScript\b", r"\bset_script\b",
             r"\bEngine\s*\.\s*get_singleton\b", r"\bstr_to_var\b", r"\bbytes_to_var_with_objects\b",
             r"\bJavaScriptBridge\b", r"\bJavaScript\b", r"\bNativeExtension\b", r"\bGDExtension\b"],
    "net": [r"\bHTTPRequest\b", r"\bHTTPClient\b", r"\bStreamPeerTCP\b", r"\bStreamPeerTLS\b", r"\bTCPServer\b",
            r"\bPacketPeerUDP\b", r"\bUDPServer\b", r"\bWebSocketPeer\b", r"\bWebSocketMultiplayerPeer\b",
            r"\bENet\w*", r"\bUPNP\w*", r"\bWebRTC\w*", r"\bIP\s*\.", r"\bMultiplayerPeer\b", r"\bDTLSServer\b"],
    "files": [r"\bFileAccess\b", r"\bDirAccess\b", r"\bConfigFile\b", r"\bResourceSaver\b", r"user://",
              r"\b[A-Za-z]:[\\/]", r"\bProjectSettings\s*\.\s*(globalize_path|set_setting|save)"],
    "game": [r"res://scripts/", r"\bchange_scene\w*", r"\bget_tree\(\)\s*\.\s*quit\b", r"\bunload_current_scene\b"],
    "thread": [r"\bThread\b", r"\bOS\s*\.\s*delay"],
}
LOAD_RE = re.compile(r"\b(preload|load|ResourceLoader\s*\.\s*load)\s*\(\s*([^)]*)\)")
EXT_RE = re.compile(r'^\s*extends\s+"([^"]+)"')
BAD_FILES = (".dll", ".exe", ".pck", ".scn", ".res", ".so", ".dylib")
# Game scripts the original mod preloads and that the user reported as allowed by the checker.
GAME_SCRIPTS_OK = {"res://src/net/Seats.gd", "res://src/save/Save.gd", "res://src/economy/Resources.gd",
                   "res://src/economy/Economy.gd", "res://src/core/FeatureState.gd"}

errors = []
for root, _dirs, files in os.walk(mod_dir):
    for fn in files:
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, mod_dir)
        if fn.lower().endswith(BAD_FILES):
            errors.append((rel, 0, "files", "forbidden file type"))
        if not fn.endswith((".gd", ".tscn")):
            continue
        with open(p, encoding="utf-8") as f:
            lines = f.read().split("\n")
        if fn.endswith(".tscn"):
            if any("GDScript" in l or "script/source" in l for l in lines):
                errors.append((rel, 0, "code", "embedded GDScript in .tscn"))
            continue
        for i, line in enumerate(lines, 1):
            code = line.split("#", 1)[0] if not line.lstrip().startswith("##") else ""
            # strip string contents except for load paths check
            for cat, pats in TOKENS.items():
                for pat in pats:
                    for m in re.finditer(pat, code):
                        # ignore inside string literals
                        before = code[:m.start()]
                        if before.count('"') % 2 == 1:
                            if cat not in ("files", "game"):
                                continue
                        errors.append((rel, i, cat, m.group(0)))
            for m in LOAD_RE.finditer(code):
                arg = m.group(2).strip()
                lit = re.fullmatch(r'"([^"]*)"', arg)
                if not lit:
                    errors.append((rel, i, "load", "non-literal %s(%s)" % (m.group(1), arg)))
                    continue
                path = lit.group(1)
                if ".." in path:
                    errors.append((rel, i, "load", "'..' in path " + path))
                elif path in GAME_SCRIPTS_OK:
                    pass
                elif not path.startswith("res://mods/%s/" % mod_id):
                    errors.append((rel, i, "load", "path outside mod: " + path))
            em = EXT_RE.match(line)
            if em:
                path = em.group(1)
                if ".." in path or not (path.startswith("res://mods/%s/" % mod_id) or path in GAME_SCRIPTS_OK):
                    errors.append((rel, i, "load", "extends " + path))

for e in sorted(errors):
    print("%s:%d\t%s\t%s" % e)
print("sandbox scan: %d problem(s)" % len(errors))
sys.exit(1 if errors else 0)
