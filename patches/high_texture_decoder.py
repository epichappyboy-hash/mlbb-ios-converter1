"""Native high-coverage Unity texture decoder with the existing decoder as fallback."""
from __future__ import annotations

import ctypes
import os
from pathlib import Path
from typing import Callable


_FORMAT_IDS = {
    "DXT1": 1, "DXT1Crunched": 1,
    "DXT3": 2,
    "DXT5": 3, "DXT5Crunched": 3,
    "BC4": 4, "BC5": 5, "BC6H": 6, "BC7": 8,
    "ATC_RGB4": 9, "ATC_RGBA8": 10,
    "ETC_RGB4": 11, "ETC_RGB4Crunched": 11,
    "ETC2_RGB": 12, "ETC2_RGBA1": 13,
    "ETC2_RGBA8": 14, "ETC2_RGBA8Crunched": 14,
    "EAC_R": 15, "EAC_R_SIGNED": 16,
    "EAC_RG": 17, "EAC_RG_SIGNED": 18,
    "PVRTC_RGB2": 20, "PVRTC_RGBA2": 20,
    "PVRTC_RGB4": 21, "PVRTC_RGBA4": 21,
}
_ASTC_FORMAT_ID = 19
_MAX_PIXELS = 32 * 1024 * 1024


def _format_info(texture_format, block_size_table):
    name = getattr(texture_format, "name", str(texture_format))
    if name.startswith("ASTC_") and name.rsplit("_", 1)[-1].count("x") == 1:
        block = block_size_table.get(texture_format)
        if block and len(block) == 2:
            return _ASTC_FORMAT_ID, int(block[0]), int(block[1])
    format_id = _FORMAT_IDS.get(name)
    if format_id is None:
        return None
    block = block_size_table.get(texture_format) or (0, 0)
    return format_id, int(block[0] or 0), int(block[1] or 0)


class NativeTextureDecoder:
    def __init__(self, library_path: Path):
        self.library_path = Path(library_path)
        self.library = ctypes.CDLL(str(self.library_path))
        self.decode_fn = self.library.mlbb_texture_decode
        byte_pointer = ctypes.POINTER(ctypes.c_uint8)
        self.decode_fn.argtypes = [
            ctypes.c_uint32, byte_pointer, ctypes.c_size_t,
            ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
            byte_pointer, ctypes.c_size_t,
        ]
        self.decode_fn.restype = ctypes.c_int
        self.version_fn = self.library.mlbb_texture_decoder_version
        self.version_fn.argtypes = []
        self.version_fn.restype = ctypes.c_uint32
        self.version = int(self.version_fn())

    def decode(self, format_id: int, data: bytes, width: int, height: int,
               block_width: int = 0, block_height: int = 0):
        from PIL import Image

        width, height = int(width), int(height)
        if width <= 0 or height <= 0 or width * height > _MAX_PIXELS:
            raise ValueError(f"Invalid or oversized texture dimensions: {width}x{height}")
        raw_data = bytes(data)
        if not raw_data:
            raise ValueError("Compressed texture data is empty")
        source = (ctypes.c_uint8 * len(raw_data)).from_buffer_copy(raw_data)
        output_size = width * height * 4
        output = (ctypes.c_uint8 * output_size)()
        status = self.decode_fn(
            int(format_id), source, len(raw_data), width, height,
            int(block_width), int(block_height), output, output_size,
        )
        if status != 0:
            raise ValueError(
                f"Native texture decoder rejected format id {format_id} "
                f"({width}x{height}, status {status})"
            )
        return Image.frombytes("RGBA", (width, height), bytes(output), "raw", "BGRA")


class DecoderStats:
    def __init__(self):
        self.native_success = 0
        self.legacy_fallback = 0
        self.fallback_formats = set()
        self._reported_fallbacks = set()

    def snapshot(self):
        return {
            "backend": "Rust native primary + UnityPy legacy fallback",
            "native_decodes": self.native_success,
            "legacy_fallbacks": self.legacy_fallback,
            "fallback_formats": sorted(self.fallback_formats),
        }


class HighTextureDispatcher:
    def __init__(self, native: NativeTextureDecoder, logger: Callable[[str], None] | None = None):
        self.native = native
        self.logger = logger or (lambda _message: None)
        self.stats = DecoderStats()

    def install(self, texture_converter):
        from UnityPy.enums import TextureFormat

        table = texture_converter.CONV_TABLE
        # UnityPy unpacks Crunch before looking up CONV_TABLE. Add ETC Crunch aliases
        # to the format table so the decompressed payload can use the same dispatcher.
        crunch_aliases = (
            ("ETC_RGB4Crunched", texture_converter.etc, ("ETC1",)),
            ("ETC2_RGBA8Crunched", texture_converter.etc, ("ETC2_A8",)),
        )
        for enum_name, decoder, args in crunch_aliases:
            enum_value = getattr(TextureFormat, enum_name, None)
            if enum_value is not None:
                table.setdefault(enum_value, (decoder, args))

        installed = []
        for texture_format, (legacy_decoder, legacy_args) in list(table.items()):
            info = _format_info(texture_format, texture_converter.TEXTURE_FORMAT_BLOCK_SIZE_TABLE)
            if info is None:
                continue
            format_id, block_width, block_height = info
            format_name = getattr(texture_format, "name", str(texture_format))

            def decode(data, width, height, *args,
                       _format_id=format_id,
                       _block_width=block_width,
                       _block_height=block_height,
                       _legacy_decoder=legacy_decoder,
                       _legacy_args=legacy_args,
                       _format_name=format_name):
                try:
                    image = self.native.decode(
                        _format_id, data, width, height, _block_width, _block_height
                    )
                    legacy_mode = (
                        _legacy_args[0]
                        if _legacy_args and _legacy_args[0] in ("L", "RGB", "RGBA")
                        else "RGBA"
                    )
                    if legacy_mode == "L":
                        image = image.getchannel("R")
                    elif legacy_mode == "RGB":
                        image = image.convert("RGB")
                    self.stats.native_success += 1
                    return image
                except Exception as native_error:
                    self.stats.legacy_fallback += 1
                    self.stats.fallback_formats.add(_format_name)
                    if _format_name not in self.stats._reported_fallbacks:
                        self.stats._reported_fallbacks.add(_format_name)
                        self.logger(f"HIGH-TEXTURE fallback: {_format_name}: {native_error}")
                    try:
                        return _legacy_decoder(data, width, height, *_legacy_args)
                    except Exception as legacy_error:
                        raise RuntimeError(
                            f"Both native and legacy decoders failed for {_format_name}; "
                            f"native={native_error}; legacy={legacy_error}"
                        ) from legacy_error

            table[texture_format] = (decode, legacy_args)
            installed.append(format_name)

        self.logger(
            "HIGH-TEXTURE native decoder ready: "
            f"version={self.native.version}; formats={len(installed)}; "
            + ", ".join(sorted(installed))
        )
        return self


def _default_library_path() -> Path:
    override = os.environ.get("MLBB_HIGH_TEXTURE_DECODER_LIBRARY")
    if override:
        return Path(override)
    app_root = Path(__file__).resolve().parents[1]
    return app_root / "Frameworks" / "HighTextureDecoder.framework" / "HighTextureDecoder"


def install_high_texture_decoder(texture_converter, logger=None):
    native = NativeTextureDecoder(_default_library_path())
    return HighTextureDispatcher(native, logger).install(texture_converter)
