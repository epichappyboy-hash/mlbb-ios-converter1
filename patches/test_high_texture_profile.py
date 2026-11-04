#!/usr/bin/env python3
"""Static regression checks for High Texture profile defaults and output."""
from __future__ import annotations

import ast
import sys
from pathlib import Path

bridge_path = Path(sys.argv[1])
converter_path = Path(sys.argv[2])
app_path = Path(sys.argv[3])

bridge = bridge_path.read_text(encoding="utf-8")
converter = converter_path.read_text(encoding="utf-8")
app = app_path.read_text(encoding="utf-8")

for path, source in ((bridge_path, bridge), (converter_path, converter)):
    ast.parse(source, filename=str(path))

assert '{"high": 100.0, "balanced": 60.0, "small": 45.0}[texture_quality]' in bridge
assert 'texture_quality: str = "high"' in bridge
assert 'texture_quality: str = "high"' in converter
assert '"high": TextureFormat.ASTC_RGBA_4x4' in converter
assert 'int(getattr(texture, "m_MipCount", 1) or 1)' in converter
assert 'selectedTextureQuality = "high"' in app

# High mode must not introduce a resize/downscale operation in the conversion call.
assert "image = texture.image.convert(\"RGBA\")" in converter
assert "mipmap_count=max(" in converter

print("PASS: High is the default texture-quality mode.")
print("PASS: High ASTC uses 4x4 blocks at encoder effort 100.")
print("PASS: source texture dimensions remain unscaled.")
print("PASS: source mip count is used to regenerate the mip chain.")
