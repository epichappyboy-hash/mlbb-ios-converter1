#!/usr/bin/env python3
"""Apply the High Texture profile to the iOS converter build."""
from __future__ import annotations

import argparse
from pathlib import Path

OLD_EFFORT = '    effort = {"high": 80.0, "balanced": 60.0, "small": 45.0}[texture_quality]'
NEW_EFFORT = '    effort = {"high": 100.0, "balanced": 60.0, "small": 45.0}[texture_quality]'
OLD_MIP = "                        mipmap_count=1,"
NEW_MIP = """                        mipmap_count=max(
                            1,
                            int(getattr(texture, "m_MipCount", 1) or 1),
                        ),"""
OLD_DEFAULT = 'texture_quality: str = "balanced"'
NEW_DEFAULT = 'texture_quality: str = "high"'
MARKER = "HIGH_TEXTURE_PROFILE_V1"


def patch_bridge(path: Path) -> None:
    source = path.read_text(encoding="utf-8")
    if OLD_EFFORT in source:
        source = source.replace(OLD_EFFORT, NEW_EFFORT, 1)
    elif NEW_EFFORT not in source:
        raise SystemExit(f"Cannot find ASTC effort mapping in {path}")
    source = source.replace(OLD_DEFAULT, NEW_DEFAULT)
    if NEW_EFFORT not in source or 'texture_quality: str = "high"' not in source:
        raise SystemExit("High profile was not applied to converter bridge")
    compile(source, str(path), "exec")
    path.write_text(source, encoding="utf-8")


def patch_converter(path: Path) -> None:
    source = path.read_text(encoding="utf-8")
    if OLD_MIP in source:
        source = source.replace(OLD_MIP, NEW_MIP, 1)
    elif 'int(getattr(texture, "m_MipCount", 1) or 1)' not in source:
        raise SystemExit(f"Cannot find Texture2D.set_image mipmap argument in {path}")
    source = source.replace(OLD_DEFAULT, NEW_DEFAULT)
    if 'int(getattr(texture, "m_MipCount", 1) or 1)' not in source:
        raise SystemExit("Source mip count is not preserved in High Texture profile")
    if '"high": TextureFormat.ASTC_RGBA_4x4' not in source:
        raise SystemExit("High ASTC 4x4 output mapping is missing")
    compile(source, str(path), "exec")
    path.write_text(source, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bridge", type=Path)
    parser.add_argument("converter", type=Path)
    args = parser.parse_args()
    patch_bridge(args.bridge)
    patch_converter(args.converter)
    print("Applied HIGH_TEXTURE_PROFILE_V1: ASTC 4x4 / effort 100 / source mip count.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
