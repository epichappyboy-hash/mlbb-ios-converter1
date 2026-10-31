from __future__ import annotations

import io
import json
import os
import shutil
import traceback
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime
from pathlib import Path


def _diagnostic(output_path: str | Path, message: str) -> None:
    """Write checkpoints immediately so iOS crashes can be localized."""
    try:
        parent = Path(output_path)
        parent.mkdir(parents=True, exist_ok=True)
        with (parent / "conversion_diagnostics.log").open("a", encoding="utf-8") as stream:
            stream.write(f"{datetime.now().isoformat(timespec='seconds')} PYTHON: {message}\n")
            stream.flush()
            os.fsync(stream.fileno())
    except Exception:
        pass


def _ensure_user_shader_folder() -> Path:
    home = Path(os.path.expanduser("~"))
    target = home / "Documents" / "MLBB Converter" / "Shaders"
    target.mkdir(parents=True, exist_ok=True)
    bundled = Path(__file__).resolve().parent / "ios_shaders"
    if bundled.is_dir():
        for source in bundled.glob("*.unity3d"):
            destination = target / source.name
            if not destination.exists():
                shutil.copy2(source, destination)
    return target


def _output_stem(display_name: str) -> str:
    from mlbb_ios_converter import safe_name
    stem = display_name.strip()
    for suffix in (".unity3d", ".zip", ".rar", "_iOS"):
        if stem.lower().endswith(suffix.lower()):
            stem = stem[:-len(suffix)]
    if "_ios" not in stem.lower():
        stem = f"{stem}_iOS"
    return safe_name(stem)


def _unique_zip(parent: Path, stem: str) -> Path:
    candidate = parent / f"{stem}.zip"
    number = 2
    while candidate.exists():
        candidate = parent / f"{stem}_{number}.zip"
        number += 1
    return candidate


def _webdav_cache_root(path: Path) -> Path | None:
    resolved = path.resolve()
    lowered = [part.lower() for part in resolved.parts]
    try:
        marker = lowered.index("webdav imports")
    except ValueError:
        return None
    if marker + 1 >= len(resolved.parts):
        return resolved
    return Path(*resolved.parts[: marker + 2])



_ASTC_LIBRARY = None


def _install_ios_astc_encoder(texture_converter, texture_quality: str) -> None:
    """Use the bundled ARM64 ASTC encoder to create real ASTC texture payloads."""
    import ctypes

    global _ASTC_LIBRARY
    framework = (
        Path(__file__).resolve().parents[1]
        / "Frameworks"
        / "AstcEncoder.framework"
        / "AstcEncoder"
    )
    if not framework.is_file():
        raise RuntimeError(f"Missing iOS ASTC encoder framework: {framework}")

    library = ctypes.CDLL(str(framework))
    encode = library.mlbb_astc_encode_rgba
    encode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_float,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
    ]
    encode.restype = ctypes.c_int
    _ASTC_LIBRARY = library

    effort = {"high": 80.0, "balanced": 60.0, "small": 45.0}[texture_quality]

    def compress_astc(data: bytes, width: int, height: int, target_texture_format) -> bytes:
        block_size = texture_converter.TEXTURE_FORMAT_BLOCK_SIZE_TABLE[target_texture_format]
        if block_size is None or block_size[0] != block_size[1]:
            raise ValueError(f"Unsupported ASTC block size for {target_texture_format}")
        block = int(block_size[0])
        required = ((width + block - 1) // block) * ((height + block - 1) // block) * 16
        if len(data) != width * height * 4:
            raise ValueError(
                f"Invalid RGBA texture buffer: expected {width * height * 4} bytes, got {len(data)}"
            )
        source = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
        output = (ctypes.c_uint8 * required)()
        status = encode(source, width, height, block, effort, output, required)
        if status != 0:
            raise RuntimeError(f"ASTC {block}x{block} encoder failed with status {status}")
        return bytes(output)

    # UnityPy's image_to_texture2d resolves this module-level function when
    # Texture2D.set_image() is called with an ASTC target format.
    texture_converter.compress_astc = compress_astc

def run_conversion(input_path: str, shader_path: str, output_path: str, display_name: str, texture_quality: str = "balanced") -> str:
    logs, capture = [], io.StringIO()
    output_dir = output_zip = None
    try:
        parent = Path(output_path)
        parent.mkdir(parents=True, exist_ok=True)
        _diagnostic(parent, "run_conversion entered; preparing user shader folder")
        try:
            _ensure_user_shader_folder()
            _diagnostic(parent, "user shader folder ready")
        except Exception as shader_exc:
            logs.append(f"WARNING: Could not prepare user shader folder: {shader_exc}")
            _diagnostic(parent, f"shader-folder setup warning: {type(shader_exc).__name__}: {shader_exc}")
        with redirect_stdout(capture), redirect_stderr(capture):
            _diagnostic(parent, "importing mlbb_ios_converter / UnityPy")
            from mlbb_ios_converter import Converter, ConvertOptions
            _diagnostic(parent, "mlbb_ios_converter / UnityPy imported")
            _diagnostic(parent, "importing texture decoder dependencies")
            import texture2ddecoder
            from PIL import Image
            from UnityPy.export import Texture2DConverter as texture_converter
            _diagnostic(parent, "texture decoder dependencies imported")

            def decode_astc(image_data: bytes, width: int, height: int, block_size: tuple):
                expected = texture_converter.calculate_astc_compressed_size(width, height, block_size)
                if len(image_data) < expected:
                    raise ValueError(f"Invalid ASTC data size: {len(image_data)} < {expected}")
                rgba = texture2ddecoder.decode_astc(
                    image_data[:expected], width, height, block_size[0], block_size[1]
                )
                return Image.frombytes("RGBA", (width, height), rgba, "raw", "BGRA")

            for texture_format, (decoder, arguments) in list(texture_converter.CONV_TABLE.items()):
                if decoder is texture_converter.astc:
                    texture_converter.CONV_TABLE[texture_format] = (decode_astc, arguments)
            _diagnostic(parent, "iOS ASTC decoder installed")
            if texture_quality not in {"high", "balanced", "small"}:
                raise ValueError(f"Unknown texture quality: {texture_quality}")
            _install_ios_astc_encoder(texture_converter, texture_quality)
            _diagnostic(parent, f"iOS ASTC encoder installed; quality={texture_quality}")

            class _SpaceSavingJobs(list):
                def __init__(self, owner):
                    super().__init__()
                    self.owner = owner

                def append(self, job):
                    owner = self.owner
                    saved_jobs = owner.jobs
                    owner.jobs = [job]
                    try:
                        Converter._validate_all(owner)
                    finally:
                        owner.jobs = saved_jobs
                    super().append(job)
                    source = Path(job[0])
                    try:
                        source.unlink(missing_ok=True)
                        owner.log(f"Validated and released temporary Android bundle: {source.name}")
                    except OSError as exc:
                        owner.log(f"WARNING: Could not release temporary bundle {source.name}: {exc}")

            class _SpaceSavingConverter(Converter):
                def __init__(self, *args, **kwargs):
                    super().__init__(*args, **kwargs)
                    self._cache_root = _webdav_cache_root(self.input_path)
                    if self._cache_root is not None:
                        self.jobs = _SpaceSavingJobs(self)
                        self.log("Low-storage mode enabled for WebDAV input.")

                def _validate_all(self):
                    if self._cache_root is None:
                        return super()._validate_all()
                    self.log("All converted bundles passed incremental validation.")
                    shutil.rmtree(self._cache_root, ignore_errors=True)
                    self.log("Released the remaining WebDAV input cache before ZIP creation.")

            _diagnostic(parent, "creating converter")
            converter = _SpaceSavingConverter(Path(input_path), Path(shader_path), parent,
                ConvertOptions(create_zip=True, full_validation=False, strict_matching=True, preserve_shadows=True, texture_quality=texture_quality),
                logger=logs.append,
                progress=lambda value, message: logs.append(f"[{value:.0f}%] {message}"))
            _diagnostic(parent, "starting converter.convert()")
            output_dir, output_zip, report = converter.convert()
            _diagnostic(parent, "converter.convert() returned")
        if output_zip is None or not output_zip.is_file():
            raise RuntimeError("The converter did not create an output ZIP.")
        _diagnostic(parent, "validating output ZIP CRC")
        with zipfile.ZipFile(output_zip) as archive:
            bad = archive.testzip()
            if bad:
                raise RuntimeError(f"Output ZIP failed CRC validation at {bad}")
        final_zip = _unique_zip(parent, _output_stem(display_name))
        os.replace(output_zip, final_zip)
        shutil.rmtree(output_dir, ignore_errors=True)
        _diagnostic(parent, f"conversion succeeded: {final_zip.name}")
        return json.dumps({"ok": True, "output": str(final_zip), "convertedBundles": converter.stats.bundles, "logs": logs[-120:]})
    except Exception as exc:
        if output_dir:
            shutil.rmtree(output_dir, ignore_errors=True)
        if output_zip and Path(output_zip).exists():
            Path(output_zip).unlink()
        details = capture.getvalue().strip()
        if details:
            logs.extend(details.splitlines()[-40:])
        logs.append(traceback.format_exc(limit=12))
        _diagnostic(output_path, f"conversion error: {type(exc).__name__}: {exc}")
        _diagnostic(output_path, traceback.format_exc(limit=12))
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}", "logs": logs[-120:]})
