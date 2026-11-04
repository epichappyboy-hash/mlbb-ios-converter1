#!/usr/bin/env python3
"""Static regression checks for per-texture High Texture validation."""
from __future__ import annotations

import ast
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
ast.parse(source)
required = (
    "UNIVERSAL_HIGH_TEXTURE_VALIDATION_V1",
    "Decoded source texture dimensions mismatch",
    "Texture did not reach requested ASTC format",
    "Texture still references external stream data",
    "ASTC round-trip validation failed",
    "expected_mip_count = source_mip_count",
)
missing = [item for item in required if item not in source]
if missing:
    raise SystemExit("Missing validation guards: " + ", ".join(missing))
print("PASS: per-texture dimensions, ASTC format, stream, mip count, and round-trip checks are present.")
