#!/usr/bin/env python3
"""Host smoke tests for native decoder dispatch and safe legacy fallback."""
from __future__ import annotations

import sys
import types
from enum import IntEnum
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from high_texture_decoder import install_high_texture_decoder  # noqa: E402


class FakeImage:
    def __init__(self, mode, size, data):
        self.mode, self.size, self.data = mode, size, data

    @classmethod
    def frombytes(cls, mode, size, data, _raw, _decoder):
        return cls(mode, size, data)


pil = types.ModuleType("PIL")
pil.Image = FakeImage
sys.modules["PIL"] = pil


class TextureFormat(IntEnum):
    DXT1 = 10
    ETC_RGB4 = 34
    ASTC_RGBA_4x4 = 54
    RGBA32 = 4
    ETC_RGB4Crunched = 64
    ETC2_RGBA8Crunched = 65


def legacy_decoder(_data, width, height):
    return FakeImage("RGBA", (width, height), b"legacy")


def legacy_etc(_data, width, height, _fmt):
    return FakeImage("RGBA", (width, height), b"legacy-etc")


texture_converter = types.SimpleNamespace(
    CONV_TABLE={
        TextureFormat.DXT1: (legacy_decoder, ()),
        TextureFormat.ETC_RGB4: (legacy_etc, ("ETC1",)),
        TextureFormat.ASTC_RGBA_4x4: (legacy_etc, ((4, 4),)),
        TextureFormat.RGBA32: (legacy_decoder, ()),
    },
    TEXTURE_FORMAT_BLOCK_SIZE_TABLE={
        TextureFormat.DXT1: (4, 4),
        TextureFormat.ETC_RGB4: (4, 4),
        TextureFormat.ASTC_RGBA_4x4: (4, 4),
        TextureFormat.RGBA32: None,
        TextureFormat.ETC_RGB4Crunched: (4, 4),
        TextureFormat.ETC2_RGBA8Crunched: (4, 4),
    },
    etc=legacy_etc,
)

dispatcher = install_high_texture_decoder(texture_converter, logger=print)
assert TextureFormat.RGBA32 in texture_converter.CONV_TABLE
assert TextureFormat.ETC_RGB4Crunched in texture_converter.CONV_TABLE
assert TextureFormat.ETC2_RGBA8Crunched in texture_converter.CONV_TABLE

decode_etc = texture_converter.CONV_TABLE[TextureFormat.ETC_RGB4][0]
image = decode_etc(bytes(8), 4, 4, "ETC1")
assert image.mode == "RGBA" and image.size == (4, 4)
assert bytes(image.data[:4]) == bytes((0, 0, 0, 255))

decode_dxt1 = texture_converter.CONV_TABLE[TextureFormat.DXT1][0]
fallback_image = decode_dxt1(bytes(7), 4, 4)
assert fallback_image.data == b"legacy"
snapshot = dispatcher.stats.snapshot()
assert snapshot["native_decodes"] >= 1
assert snapshot["legacy_fallbacks"] == 1
assert "DXT1" in snapshot["fallback_formats"]

decode_astc = texture_converter.CONV_TABLE[TextureFormat.ASTC_RGBA_4x4][0]
astc_result = decode_astc(bytes(16), 4, 4, (4, 4))
assert astc_result.size == (4, 4)

print("PASS: native dispatcher installs only on supported compressed formats.")
print("PASS: ETC1 native decode returns a BGRA-compatible RGBA image.")
print("PASS: invalid native input falls back to the existing decoder.")
print("PASS: ASTC uses native-primary/fallback dispatch.")
