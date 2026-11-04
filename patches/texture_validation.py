#!/usr/bin/env python3
"""Add per-texture input/output validation to the Universal High Texture pipeline."""
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "UNIVERSAL_HIGH_TEXTURE_VALIDATION_V1"

OLD = '''                    texture = obj.read()
                    image = texture.image.convert("RGBA")
                    texture.set_image(
                        image,
                        target_format={
                            "high": TextureFormat.ASTC_RGBA_4x4,
                            "balanced": TextureFormat.ASTC_RGBA_6x6,
                            "small": TextureFormat.ASTC_RGBA_8x8,
                        }[self.options.texture_quality],
                        mipmap_count=max(
                            1,
                            int(getattr(texture, "m_MipCount", 1) or 1),
                        ),
                    )
                    obj.save_typetree(texture)
                    self.stats.textures += 1
'''

NEW = '''                    # UNIVERSAL_HIGH_TEXTURE_VALIDATION_V1
                    texture = obj.read()
                    source_width = int(texture.m_Width)
                    source_height = int(texture.m_Height)
                    source_size = (source_width, source_height)
                    source_mip_count = max(
                        1, int(getattr(texture, "m_MipCount", 1) or 1)
                    )

                    image = texture.image
                    if image.size != source_size:
                        raise ConversionError(
                            f"Decoded source texture dimensions mismatch: "
                            f"{texture.m_Name}: expected {source_size}, got {image.size}"
                        )
                    image = image.convert("RGBA")
                    if image.mode != "RGBA" or image.size != source_size:
                        raise ConversionError(
                            f"Source RGBA normalization failed: {texture.m_Name}"
                        )

                    target_texture_format = {
                        "high": TextureFormat.ASTC_RGBA_4x4,
                        "balanced": TextureFormat.ASTC_RGBA_6x6,
                        "small": TextureFormat.ASTC_RGBA_8x8,
                    }[self.options.texture_quality]

                    # UnityPy regenerates the mip chain from the original base image.
                    expected_mip_count = source_mip_count
                    mip_width, mip_height = source_size
                    for mip_index in range(source_mip_count - 1):
                        mip_width //= 2
                        mip_height //= 2
                        if mip_width < 4 or mip_height < 4:
                            expected_mip_count = mip_index + 1
                            break

                    texture.set_image(
                        image,
                        target_format=target_texture_format,
                        mipmap_count=source_mip_count,
                    )

                    if (int(texture.m_Width), int(texture.m_Height)) != source_size:
                        raise ConversionError(
                            f"Encoded texture dimensions changed: {texture.m_Name}"
                        )
                    if int(texture.m_TextureFormat) != int(target_texture_format):
                        raise ConversionError(
                            f"Texture did not reach requested ASTC format: {texture.m_Name}"
                        )
                    image_data = getattr(texture, "image_data", None)
                    if not image_data:
                        raise ConversionError(
                            f"Encoded texture has no inline image data: {texture.m_Name}"
                        )
                    complete_size = getattr(texture, "m_CompleteImageSize", None)
                    if complete_size is not None and int(complete_size) != len(image_data):
                        raise ConversionError(
                            f"Texture data size metadata mismatch: {texture.m_Name}"
                        )
                    actual_mip_count = getattr(texture, "m_MipCount", None)
                    if actual_mip_count is not None and int(actual_mip_count) != expected_mip_count:
                        raise ConversionError(
                            f"Texture mip count mismatch: {texture.m_Name}: "
                            f"expected {expected_mip_count}, got {actual_mip_count}"
                        )
                    stream_data = getattr(texture, "m_StreamData", None)
                    if stream_data is not None and (
                        getattr(stream_data, "path", "")
                        or int(getattr(stream_data, "size", 0) or 0) != 0
                    ):
                        raise ConversionError(
                            f"Texture still references external stream data: {texture.m_Name}"
                        )

                    # Decode the newly encoded ASTC base level once to verify that
                    # the selected decoder can read the exact bytes we just wrote.
                    roundtrip = texture.image
                    if roundtrip.size != source_size or roundtrip.mode != "RGBA":
                        raise ConversionError(
                            f"ASTC round-trip validation failed: {texture.m_Name}"
                        )

                    obj.save_typetree(texture)
                    self.stats.textures += 1
'''

def patch(path: Path) -> bool:
    source = path.read_text(encoding="utf-8")
    if MARKER in source:
        compile(source, str(path), "exec")
        return False
    if OLD not in source:
        raise SystemExit("Could not find the expected Texture2D conversion block")
    source = source.replace(OLD, NEW, 1)
    compile(source, str(path), "exec")
    path.write_text(source, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("converter", type=Path)
    args = parser.parse_args()
    changed = patch(args.converter)
    print(
        "Applied per-texture decode/encode/mipmap verification."
        if changed else "Per-texture verification already present."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
