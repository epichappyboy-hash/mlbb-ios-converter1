#!/usr/bin/env python3
"""Patch MLBB converter to preserve source material lighting unless explicitly verified.

This patch is intentionally conservative: shader remapping may be required for iOS,
but it must not silently rewrite every material's brightness/rim/highlight values.
"""
from __future__ import annotations

import argparse
from pathlib import Path

START = "def normalize_ios_lighting(material, shader_name: str):"
END = "\ndef prepare_material_for_shader("
MARKER = "PRESERVE_SOURCE_MATERIAL_LIGHTING_FIX_V1"

REPLACEMENT = '''def normalize_ios_lighting(material, shader_name: str):
    """PRESERVE_SOURCE_MATERIAL_LIGHTING_FIX_V1: preserve source lighting by default.

    A shader remap from Android to Metal does not prove that the source material's
    scalar/color values should be changed. ML_FightOutline is shared by different
    material families, so applying monster-specific values globally can darken hero
    skins. Only the existing texture aliases and verified Lancelot exception remain.
    """
    name = str(shader_name).strip().lower()

    if name == "mlhero/ml_nmonster_l1_t2":
        # Alias existing maps for the iOS monster shader; do not alter lighting.
        normalize_monster_material(material)
        return

    if name == "mlhero/ml_nhero_l1_t2":
        material_name = str(getattr(material, "m_Name", "")).strip().lower()
        is_verified_lancelot = (
            "lancelot" in material_name
            or material_name.startswith("txt_lancelot")
        )
        if not is_verified_lancelot:
            return

        # Keep the narrow, previously verified Lancelot reference adjustment.
        set_saved_float(material, "_LightScale", 2.0)
        set_saved_float(material, "_LitMult", 1.6)
        set_saved_float(material, "_B_Pw", 0.5)
        set_saved_float(material, "_G_Pw", 0.5)
        set_saved_float(material, "_RimIntensity", 0.0)
        set_saved_float(material, "_Fresmel", 0.0)
        set_saved_color(material, "_Sp_Color", ColorRGBA(0.46572232, 0.5482192, 0.86764705, 1.0))
        set_saved_color(material, "_RimColor", ColorRGBA(0.0, 0.0, 0.0, 0.0))
        for prop in ("_Gloss_R", "_Gloss_G", "_Gloss_B"):
            set_saved_float(material, prop, 0.0)
        set_saved_float(material, "_Crystal_UseCustomColor", 0.0)
        return

    if name == "mlhero/ml_fightoutline":
        # Do NOT force _LitMult=1 or clear _RimLit globally. The same shader is
        # used by different materials. Keep Android source values byte-for-byte
        # at the property level; named monster materials are reclassified earlier
        # when a verified iOS monster shader is available.
        return

    # Unknown/new shader families are pass-through until verified with a source
    # Android/iOS material pair. Never guess a global brightness profile.
'''


def patch(path: Path) -> bool:
    source = path.read_text(encoding="utf-8")
    if MARKER in source:
        compile(source, str(path), "exec")
        return False
    start = source.find(START)
    if start < 0:
        raise SystemExit(f"Could not find {START!r} in {path}")
    end = source.find(END, start)
    if end < 0:
        raise SystemExit("Could not find normalize_ios_lighting() end boundary")
    patched = source[:start] + REPLACEMENT + source[end:]
    compile(patched, str(path), "exec")
    path.write_text(patched, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="Path to app/mlbb_ios_converter.py")
    args = parser.parse_args()
    changed = patch(args.source)
    print("Applied source-lighting preservation fix." if changed else "Lighting fix already applied; no changes needed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
