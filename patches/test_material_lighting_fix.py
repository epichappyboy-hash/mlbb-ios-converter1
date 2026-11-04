#!/usr/bin/env python3
"""Dependency-free regression tests for normalize_ios_lighting()."""
from __future__ import annotations

import ast
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
source = source_path.read_text(encoding="utf-8")
tree = ast.parse(source, filename=str(source_path))
function = next(
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "normalize_ios_lighting"
)
module = ast.Module(body=[function], type_ignores=[])
ast.fix_missing_locations(module)

calls = {"monster": 0, "float": [], "color": []}

def normalize_monster_material(material):
    calls["monster"] += 1

def set_saved_float(material, name, value):
    calls["float"].append((name, value))

def set_saved_color(material, name, value):
    calls["color"].append((name, value))

namespace = {
    "normalize_monster_material": normalize_monster_material,
    "set_saved_float": set_saved_float,
    "set_saved_color": set_saved_color,
    "ColorRGBA": lambda *values: tuple(values),
}
exec(compile(module, str(source_path), "exec"), namespace)
normalize = namespace["normalize_ios_lighting"]

# A hero material using ML_FightOutline must not receive monster brightness values.
zeo = type("Material", (), {"m_Name": "zeo_skin02"})()
normalize(zeo, "MLHero/ML_FightOutline")
assert calls["float"] == [], "ML_FightOutline unexpectedly rewrote float properties"
assert calls["color"] == [], "ML_FightOutline unexpectedly rewrote color properties"

# A generic hero using ML_NHero must not inherit Lancelot's special settings.
other_hero = type("Material", (), {"m_Name": "hero_zeo_skin04"})()
normalize(other_hero, "MlHero/ML_NHero_L1_T2")
assert calls["float"] == [], "Generic ML_NHero material was normalized as Lancelot"
assert calls["color"] == [], "Generic ML_NHero color was normalized as Lancelot"

# The verified Lancelot exception remains narrowly scoped.
lancelot = type("Material", (), {"m_Name": "txt_lancelot_skin"})()
normalize(lancelot, "MlHero/ML_NHero_L1_T2")
assert ("_LitMult", 1.6) in calls["float"]
assert ("_LightScale", 2.0) in calls["float"]

# Monster map aliases remain enabled without a global lighting rewrite.
monster = type("Material", (), {"m_Name": "purple_buff"})()
normalize(monster, "MlHero/ML_NMonster_L1_T2")
assert calls["monster"] == 1

print("PASS: generic hero and ML_FightOutline source lighting is preserved.")
print("PASS: Lancelot-only adjustment remains narrowly scoped.")
print("PASS: monster texture-alias handling remains enabled.")
