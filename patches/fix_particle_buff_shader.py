#!/usr/bin/env python3
"""Keep FX/particle materials out of the jungle-monster body-shader override."""
from __future__ import annotations

import argparse
import re
from pathlib import Path

MARKER = "PARTICLE_BUFF_SHADER_CLASSIFICATION_FIX_V1"

REPLACEMENT = '''def looks_like_monster_buff_name(value: str) -> bool:
    """Recognize actual MLBB jungle-monster materials, not FX materials.

    Some map effects use names such as FX_M_scene_buff_fire01.  The old broad
    "buff" token check incorrectly classified those particle materials as
    jungle-monster bodies and replaced their additive/transparent effect shader
    with MlHero/ML_NMonster_L1_T2, which can render the particle quad as a dark
    opaque square.

    Keep known monster naming families, but explicitly exclude FX/effect assets
    and never classify a material merely because it contains the word "buff".
    """
    normalized = re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")
    if normalized.startswith(("fx_", "effect_", "particle_", "vfx_")):
        return False

    compact = normalized.replace("_", "")
    exact = {
        "purplebuffmin",
        "purplebuff",
        "orangebuff01",
        "mon_newfallenrider02",
        "newtortoise",
        "shixianggui",
        "baoxiangguai",
        "xiyiren",
        "jiachong",
    }
    if compact in exact:
        return True

    monster_tokens = {
        "purplebuff",
        "orangebuff",
        "tortoise",
        "newtortoise",
        "fallenrider",
        "newfallenrider",
        "shixianggui",
        "baoxiangguai",
        "xiyiren",
        "jiachong",
    }
    return (
        any(token in normalized for token in monster_tokens)
        or normalized.startswith("mon_")
    )
'''


def patch(path: Path) -> bool:
    source = path.read_text(encoding="utf-8")
    if MARKER in source:
        compile(source, str(path), "exec")
        return False

    pattern = re.compile(
        r"(?ms)^def looks_like_monster_buff_name\(value: str\) -> bool:\n"
        r".*?(?=^def normalize_monster_material\()"
    )
    updated, count = pattern.subn(REPLACEMENT + "\n\n", source, count=1)
    if count != 1:
        raise SystemExit("Could not find the expected looks_like_monster_buff_name() function")

    # The marker is in the function docstring; ensure the intended replacement
    # is what will be compiled before changing the project source.
    if MARKER not in updated:
        updated = updated.replace(
            '"""Recognize actual MLBB jungle-monster materials, not FX materials.',
            '"""PARTICLE_BUFF_SHADER_CLASSIFICATION_FIX_V1: recognize actual MLBB jungle-monster materials, not FX materials.',
            1,
        )
    if MARKER not in updated:
        raise SystemExit("Particle/FX classification marker was not added")

    compile(updated, str(path), "exec")
    path.write_text(updated, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("converter", type=Path, help="Path to app/mlbb_ios_converter.py")
    args = parser.parse_args()
    changed = patch(args.converter)
    print(
        "Applied particle/FX shader classification fix."
        if changed else "Particle/FX shader classification fix already applied."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
