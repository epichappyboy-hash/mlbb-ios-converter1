#!/usr/bin/env python3
"""Apply Windows portable converter defaults to Isha's Unity conversion core."""
from __future__ import annotations
import ast, re, sys
from pathlib import Path

if len(sys.argv) not in (2, 3):
    raise SystemExit("usage: apply_windows_compat.py PATH_TO_mlbb_ios_converter.py [UNITYPY_PACKAGE_DIR]")
path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

# Keep the quality option in the converter's actual dataclass API. The bridge
# already passes this keyword; without this field conversion fails at startup.
module = ast.parse(source)
options_class = next(
    (node for node in module.body if isinstance(node, ast.ClassDef) and node.name == "ConvertOptions"),
    None,
)
if options_class is None:
    raise SystemExit("ConvertOptions class not found")
quality_field = any(
    isinstance(node, ast.AnnAssign)
    and isinstance(node.target, ast.Name)
    and node.target.id == "texture_quality"
    for node in options_class.body
)
if not quality_field:
    first_method = next(
        (node for node in options_class.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))),
        None,
    )
    if first_method is None:
        insert_line = options_class.end_lineno
    else:
        insert_line = first_method.lineno - 1
    lines = source.splitlines(keepends=True)
    lines.insert(insert_line, '    texture_quality: str = "high"\n')
    source = "".join(lines)
module = ast.parse(source)
options_class = next(
    node for node in module.body if isinstance(node, ast.ClassDef) and node.name == "ConvertOptions"
)
if not any(
    isinstance(node, ast.AnnAssign)
    and isinstance(node.target, ast.Name)
    and node.target.id == "texture_quality"
    for node in options_class.body
):
    raise SystemExit("ConvertOptions.texture_quality field was not added")

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
                obj.path_id: obj
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
                    source_texture_obj = source_textures.get(obj.path_id)
                    if source_texture_obj is None:
                        raise ConversionError(
                            f"Source Texture2D missing for {texture.m_Name} in {target.name}"
                        )
                    source_texture = source_texture_obj.read()
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

# Apply behavior-changing UnityPy 1.25.4 source updates from the Windows package.
# Keep iOS-only native frameworks and the optional FMOD fallback untouched.
if len(sys.argv) == 3:
    unitypy = Path(sys.argv[2])
    if not (unitypy / "__init__.py").is_file():
        raise SystemExit(f"UnityPy package directory not found: {unitypy}")

    def rep(rel, old, new):
        target = unitypy / rel
        value = target.read_text(encoding="utf-8")
        count = value.count(old)
        if count == 0 and new in value:
            return
        if count != 1:
            raise SystemExit(f"UnityPy 1.25.4 patch anchor mismatch: {rel}; count={count}")
        target.write_text(value.replace(old, new, 1), encoding="utf-8")

    rep("__init__.py", '__version__ = "1.25.3"', '__version__ = "1.25.4"')
    rep("environment.py",
        '        z = ZipFile(buffer)\n        self.load_assets(z.namelist(), lambda x: z.open(x, "r"))  # type: ignore\n        z.close()\n',
        '        z = ZipFile(buffer)\n\n'
        '        def load_internal_file(name: str):\n'
        '            file_data = z.open(name, "r").read()\n'
        '            return io.BytesIO(file_data)\n\n'
        '        self.load_assets(z.namelist(), load_internal_file)\n'
        '        z.close()\n')

    rep("export/Texture2DConverter.py",
        'def astc(image_data: bytes, width: int, height: int, block_size: tuple) -> Image.Image:',
        'def astc(image_data: bytes, width: int, height: int, block_size: tuple, hdr: bool = False) -> Image.Image:')
    rep("export/Texture2DConverter.py",
        '    context = get_astc_context(block_size)\n    context.decompress(image_data[:texture_size], image, astc_encoder.ASTCSwizzle.from_str("RGBA"))',
        '    context = get_astc_context(block_size, hdr)\n    context.decompress(image_data[:texture_size], image, astc_encoder.ASTCSwizzle.from_str("RGBA"))')
    rep("export/Texture2DConverter.py",
        'def _get_astc_context(ident: int, block_size: tuple):',
        'def _get_astc_context(ident: int, block_size: tuple, hdr: bool = False):')
    rep("export/Texture2DConverter.py",
        '    config = astc_encoder.ASTCConfig(\n'
        '        astc_encoder.ASTCProfile.LDR,\n'
        '        *block_size,\n'
        '        block_z=1,\n'
        '        quality=100,\n'
        '        flags=astc_encoder.ASTCConfigFlags.USE_DECODE_UNORM8,\n'
        '    )\n',
        '    if hdr:\n'
        '        config = astc_encoder.ASTCConfig(astc_encoder.ASTCProfile.HDR, *block_size, block_z=1, quality=100)\n'
        '    else:\n'
        '        config = astc_encoder.ASTCConfig(\n'
        '            astc_encoder.ASTCProfile.LDR,\n'
        '            *block_size,\n'
        '            block_z=1,\n'
        '            quality=100,\n'
        '            flags=astc_encoder.ASTCConfigFlags.USE_DECODE_UNORM8,\n'
        '        )\n')
    rep("export/Texture2DConverter.py",
        'def get_astc_context(block_size: tuple):',
        'def get_astc_context(block_size: tuple, hdr: bool = False):')
    rep("export/Texture2DConverter.py",
        '    return _get_astc_context(get_ident(), block_size)',
        '    return _get_astc_context(get_ident(), block_size, hdr)')
    for block_size in ("4x4", "5x5", "6x6", "8x8", "10x10", "12x12"):
        x, y = block_size.split("x")
        rep("export/Texture2DConverter.py",
            f'TF.ASTC_HDR_{block_size}: (astc, (({x}, {y}),)),',
            f'TF.ASTC_HDR_{block_size}: (astc, (({x}, {y}), True)),')

    rep("files/BundleFile.py",
        "or tuple consisting of (block_info_flag, data_flag)",
        "or tuple consisting of (data_flag, block_info_flag)")
    rep("files/BundleFile.py",
        '            elif packer == "lz4":\n                self.save_fs(writer, data_flag=194, block_info_flag=2)\n',
        '            elif packer == "lz4":\n                self.save_fs(writer, data_flag=194, block_info_flag=2)\n'
        '            elif packer == "lz4hc":\n                self.save_fs(writer, data_flag=195, block_info_flag=3)\n')
    rep("helpers/CompressionHelper.py",
        "while uncompressed_data_size > chunk_size:",
        "while uncompressed_data_size >= chunk_size:")
    rep("helpers/CompressionHelper.py",
        "if len(compressed_data) > chunk_size:",
        "if len(compressed_data) >= chunk_size:")

    rep("helpers/TypeTreeNode.py",
        '    def parse_blob(cls, reader: EndianBinaryReader, version: int) -> TypeTreeNode:\n'
        '        node_count = reader.read_int()\n',
        '    def parse_blob(cls, reader: EndianBinaryReader, version: int) -> TypeTreeNode:\n'
        '        if version >= 23:\n'
        '            if reader.read_bytes(4) != b"mhtt":\n'
        '                raise ValueError("Invalid type tree blob magic")\n'
        '            format_version = reader.read_int()\n'
        '            if format_version != version:\n'
        '                raise ValueError("Inconsistent type tree format version detected")\n'
        '        node_count = reader.read_int()\n')
    rep("helpers/TypeTreeNode.py",
        '        # write blob\n        writer.write_int(node_count)\n',
        '        # write blob\n'
        '        if version >= 23:\n'
        '            writer.write(b"mhtt")\n'
        '            writer.write_int(version)\n'
        '        writer.write_int(node_count)\n')
    rep("files/SerializedFile.py",
        '    # 21+\n    type_dependencies: Optional[Tuple[int, ...]] = None\n',
        '    # 21+\n    type_dependencies: Optional[Tuple[int, ...]] = None\n'
        '    # 23+\n    type_tree_content_hash: Optional[bytes] = None\n'
        '    type_tree_serialized_size: Optional[int] = None\n')
    rep("files/SerializedFile.py",
        '        if serialized_file._enable_type_tree:\n'
        '            if version >= 12 or version == 10:\n'
        '                self.node = TypeTreeNode.parse_blob(reader, version)\n',
        '        if serialized_file._enable_type_tree:\n'
        '            if version >= 23:\n'
        '                self.type_tree_content_hash = reader.read_bytes(16)\n'
        '                self.type_tree_serialized_size = reader.read_int()\n'
        '            if version >= 12 or version == 10:\n'
        '                if version < 23 or self.type_tree_serialized_size:\n'
        '                    self.node = TypeTreeNode.parse_blob(reader, version)\n')
    rep("files/SerializedFile.py",
        '        if serialized_file._enable_type_tree:\n'
        '            assert self.node is not None\n'
        '            if version >= 12 or version == 10:\n'
        '                self.node.dump_blob(writer, version)\n',
        '        if serialized_file._enable_type_tree:\n'
        '            if version >= 23:\n'
        '                assert self.type_tree_content_hash is not None\n'
        '                writer.write_bytes(self.type_tree_content_hash)\n'
        '            if version >= 12 or version == 10:\n'
        '                if version >= 23:\n'
        '                    blob_writer = EndianBinaryWriter(endian=writer.endian)\n'
        '                    if self.node is not None:\n'
        '                        self.node.dump_blob(blob_writer, version)\n'
        '                    blob_data = blob_writer.bytes\n'
        '                    writer.write_int(len(blob_data))\n'
        '                    writer.write(blob_data)\n'
        '                elif self.node is not None:\n'
        '                    self.node.dump_blob(writer, version)\n')
    rep("helpers/TypeTreeHelper.py",
        '    elif node.m_Type == "TypelessData":\n'
        '        value = [reader.read_bytes() for _ in range(size)]\n',
        '    elif node.m_Type == "TypelessData":\n'
        '        value = [reader.read_byte_array() for _ in range(size)]\n')
    rep("helpers/MeshHelper.py",
        '    def get_triangles(self) -> List[List[Tuple[int, ...]]]:\n'
        '        assert self.m_IndexBuffer is not None\n'
        '        assert self.src.m_SubMeshes is not None\n',
        '    def get_triangles(self) -> List[List[Tuple[int, ...]]]:\n'
        '        assert self.src.m_SubMeshes is not None\n'
        '        if self.m_IndexBuffer is None:\n'
        '            if any(m_SubMesh.indexCount for m_SubMesh in self.src.m_SubMeshes):\n'
        '                raise ValueError("Failed getting triangles. The submeshes have indices, but the mesh has none.")\n'
        '            return [[] for _ in self.src.m_SubMeshes]\n')

    for module in unitypy.rglob("*.py"):
        ast.parse(module.read_text(encoding="utf-8"))
    print("UnityPy 1.25.4 compatibility patches and Python syntax checks passed.")
