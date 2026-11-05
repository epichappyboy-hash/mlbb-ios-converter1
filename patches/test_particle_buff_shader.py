#!/usr/bin/env python3
"""Regression tests for monster-vs-particle material shader classification."""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
source = source_path.read_text(encoding="utf-8")
tree = ast.parse(source, filename=str(source_path))

function_node = next(
    node for node in tree.body
    if isinstance(node, ast.FunctionDef)
    and node.name == "looks_like_monster_buff_name"
)
namespace = {"re": re}
exec(
    compile(ast.Module(body=[function_node], type_ignores=[]), str(source_path), "exec"),
    namespace,
)
classify = namespace["looks_like_monster_buff_name"]

# These map particle/effect materials must keep their own effect shaders.
fx_names = (
    "FX_M_scene_buff_fire01",
    "FX_M_scene_buff_fire03",
    "FX_M_scene_buff_fire04",
    "FX_M_scene_water01_1",
    "FX_M_scene_water01_5",
    "Effect_buff_particle",
    "Particle_purple_buff_glow",
    "VFX_orange_buff_trail",
)
for name in fx_names:
    assert classify(name) is False, f"FX material was misclassified as a monster: {name}"

# Real jungle monster names and known variants must retain their monster route.
monster_names = (
    "purplebuff",
    "purplebuff_min",
    "orangebuff01",
    "mon_newfallenrider02",
    "newtortoise",
    "shixianggui",
    "baoxiangguai",
    "xiyiren",
    "jiachong",
)
for name in monster_names:
    assert classify(name) is True, f"Monster material was no longer recognized: {name}"

# Unrelated hero materials must not be selected just because "buff" appears.
assert classify("hero_buff_costume") is False
assert classify("hero_ishamlbb_skin") is False

print("PASS: FX/particle materials keep their original effect shader routing.")
print("PASS: known jungle-monster material families remain recognized.")
