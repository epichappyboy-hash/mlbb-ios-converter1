#!/usr/bin/env python3
"""Apply Windows portable converter defaults to Isha's Unity conversion core."""
from __future__ import annotations
import ast, re, sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_windows_compat.py PATH_TO_mlbb_ios_converter.py")
path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

anchor = "METAL_SHADER_PLATFORM = 14\n"
helpers = '''METAL_SHADER_PLATFORM = 14

# Windows portable defaults: re-encode Android GPU-compressed textures only.
# Existing ASTC/PVRTC and uncompressed textures remain untouched by default.
WINDOWS_ANDROID_GPU_TEXTURE_FORMAT_NAMES = frozenset({
    "ETC_RGB4", "ETC_RGB4Crunched", "ETC_RGB4_3DS",
    "ETC2_RGB", "ETC2_RGBA1", "ETC2_RGBA8", "ETC2_RGBA8Crunched",
    "ATC_RGB4", "ATC_RGBA8",
    "EAC_R", "EAC_R_SIGNED", "EAC_RG", "EAC_RG_SIGNED",
    "DXT1", "DXT3", "DXT5", "DXT1Crunched", "DXT5Crunched",
    "BC4", "BC5", "BC6H", "BC7",
})


def windows_should_reencode_texture(texture) -> bool:
    try:
        format_name = TextureFormat(int(texture.m_TextureFormat)).name
    except (TypeError, ValueError):
        return False
    if format_name.startswith(("ASTC", "PVRTC")):
        return False
    return format_name in WINDOWS_ANDROID_GPU_TEXTURE_FORMAT_NAMES


def windows_astc_target_format(image, quality: str):
    blocks = {"high": 4, "balanced": 6, "small": 8}
    try:
        block = blocks[quality]
    except KeyError as exc:
        raise ConversionError(f"Unknown texture quality: {quality}") from exc
    alpha_min, alpha_max = image.getchannel("A").getextrema()
    family = "RGBA" if alpha_min < 255 or alpha_max < 255 else "RGB"
    return getattr(TextureFormat, f"ASTC_{family}_{block}x{block}")


def windows_preserved_mipmap_count(texture) -> int:
    requested = max(1, int(getattr(texture, "m_MipCount", 1) or 1))
    width, height = int(texture.m_Width), int(texture.m_Height)
    result = 1
    for index in range(requested - 1):
        width //= 2
        height //= 2
        if width < 4 or height < 4:
            return index + 1
        result = index + 2
    return result
'''
if source.count(anchor) != 1:
    raise SystemExit("Could not find unique constants insertion point")
if "WINDOWS_ANDROID_GPU_TEXTURE_FORMAT_NAMES" not in source:
    source = source.replace(anchor, helpers, 1)

source = source.replace(
    '        return root.save(packer="lz4"), True',
    '        return root.save(packer="original"), True',
    1,
)
if '        return root.save(packer="original"), True' not in source:
    raise SystemExit("Windows original UnityFS packer is missing")
source = source.replace(
    '    texture_quality: str = "balanced"\n',
    '    texture_quality: str = "high"\n',
    1,
)

convert_start = source.index("    def _convert_bundle(self, source: Path, target: Path):")
validate_start = source.index("    def _validate_all(self):", convert_start)
convert_section = source[convert_start:validate_start]
branch_re = re.compile(
    r'(?ms)^(?P<i>            )elif obj\.type\.name == "Texture2D":\n'
    r'(?P<body>.*?)(?=^            else:\n)'
)
new_branch = '''            elif obj.type.name == "Texture2D":
                try:
                    texture = obj.read()
                    source_format = TextureFormat(int(texture.m_TextureFormat))
                    if not windows_should_reencode_texture(texture):
                        self.log(
                            f"Windows-compatible preserve: {source_format.name} texture "
                            f"{texture.m_Name} in {source.name}"
                        )
                        continue
                    image = texture.image.convert("RGBA")
                    target_format = windows_astc_target_format(
                        image, self.options.texture_quality
                    )
                    mipmap_count = windows_preserved_mipmap_count(texture)
                    texture.set_image(
                        image,
                        target_format=target_format,
                        mipmap_count=mipmap_count,
                    )
                    obj.save_typetree(texture)
                    self.stats.textures += 1
                except Exception as exc:
                    message = f"Texture conversion failed in {source.name}: {exc}"
                    if self.options.strict_matching:
                        raise ConversionError(message) from exc
                    self.stats.warnings.append(message)
                    self.log("WARNING: " + message)
'''
convert_section, count = branch_re.subn(lambda m: new_branch, convert_section, count=1)
if count != 1:
    raise SystemExit(f"Expected one conversion Texture2D branch, got {count}")
source = source[:convert_start] + convert_section + source[validate_start:]

validate_start = source.index("    def _validate_all(self):")
report_start = source.index("    def _write_report(", validate_start)
validate_section = source[validate_start:report_start]
load = '            output_env = UnityPy.load(str(target))\n'
if validate_section.count(load) != 1:
    raise SystemExit("Could not find output bundle validation setup")
validate_section = validate_section.replace(
    load,
    load + '''            source_textures = {
                obj.path_id: obj.read()
                for obj in source_env.objects
                if obj.type.name == "Texture2D"
            }
''',
    1,
)
validator_re = re.compile(
    r'(?ms)^                elif obj\.type\.name == "Texture2D":\n'
    r'(?P<body>.*?)(?=^            percent = 76)'
)
new_validator = '''                elif obj.type.name == "Texture2D":
                    texture = obj.read()
                    source_texture = source_textures.get(obj.path_id)
                    if source_texture is None:
                        raise ConversionError(
                            f"Source Texture2D missing for {texture.m_Name} in {target.name}"
                        )
                    source_format = TextureFormat(int(source_texture.m_TextureFormat))
                    if windows_should_reencode_texture(source_texture):
                        source_image = source_texture.image.convert("RGBA")
                        expected = windows_astc_target_format(
                            source_image, self.options.texture_quality
                        )
                        if int(texture.m_TextureFormat) != int(expected):
                            raise ConversionError(
                                f"Texture format mismatch in {target.name}: {texture.m_Name}; "
                                f"expected {expected.name}, got "
                                f"{TextureFormat(int(texture.m_TextureFormat)).name}"
                            )
                        expected_mips = windows_preserved_mipmap_count(source_texture)
                        if int(getattr(texture, "m_MipCount", 1) or 1) != expected_mips:
                            raise ConversionError(
                                f"Mip count changed for {texture.m_Name}: expected "
                                f"{expected_mips}, got {getattr(texture, 'm_MipCount', None)}"
                            )
                        stream = getattr(texture, "m_StreamData", None)
                        if stream and stream.path:
                            raise ConversionError(f"Texture stream remains: {texture.m_Name}")
                    else:
                        if TextureFormat(int(texture.m_TextureFormat)) != source_format:
                            raise ConversionError(
                                f"Windows-preserved texture format changed: {texture.m_Name}"
                            )
                        if texture.get_image_data() != source_texture.get_image_data():
                            raise ConversionError(
                                f"Windows-preserved texture payload changed: {texture.m_Name}"
                            )
                        if int(getattr(texture, "m_MipCount", 1) or 1) != int(
                            getattr(source_texture, "m_MipCount", 1) or 1
                        ):
                            raise ConversionError(
                                f"Windows-preserved texture mip count changed: {texture.m_Name}"
                            )
                    if self.options.full_validation:
                        image = texture.image
                        if image.mode != "RGBA" or image.size != (
                            texture.m_Width, texture.m_Height
                        ):
                            raise ConversionError(f"Texture validation failed: {texture.m_Name}")
'''
validate_section, count = validator_re.subn(lambda m: new_validator, validate_section, count=1)
if count != 1:
    raise SystemExit(f"Expected one validation Texture2D branch, got {count}")
source = source[:validate_start] + validate_section + source[report_start:]

ast.parse(source)
if 'return root.save(packer="lz4"), True' in source:
    raise SystemExit("Forced regular LZ4 packing remains")
if "windows_should_reencode_texture(texture)" not in source:
    raise SystemExit("Windows texture conversion policy is missing")
if "texture.get_image_data() != source_texture.get_image_data()" not in source:
    raise SystemExit("Byte-for-byte preservation validator is missing")
if "mipmap_count=mipmap_count" not in source:
    raise SystemExit("Source mip count preservation is missing")
path.write_text(source, encoding="utf-8")
print("Windows-compatible texture policy, alpha-aware ASTC, mip preservation, original UnityFS packer, and strict passthrough validation applied.")
