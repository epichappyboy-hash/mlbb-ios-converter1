from __future__ import annotations


def _diagnostic(output_path: str | Path, message: str) -> None:
    """Write checkpoints immediately so iOS crashes can be localized."""
    import os
    from datetime import datetime
    from pathlib import Path
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
    import os
    import shutil
    from pathlib import Path
    home = Path(os.path.expanduser("~"))
    target = home / "Documents" / "Isha Converter iOS" / "Shaders"
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
    from pathlib import Path
    resolved = path.resolve()
    lowered = [part.lower() for part in resolved.parts]
    try:
        marker = lowered.index("webdav imports")
    except ValueError:
        return None
    if marker + 1 >= len(resolved.parts):
        return resolved
    return Path(*resolved.parts[: marker + 2])


def run_conversion(input_path: str, shader_path: str, output_path: str, display_name: str) -> str:
    # Keep module import lightweight; load the standard-library stack only when conversion starts.
    import io
    import json
    import os
    import shutil
    import traceback
    import zipfile
    from contextlib import redirect_stderr, redirect_stdout
    from pathlib import Path
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
                ConvertOptions(create_zip=True, full_validation=False, strict_matching=True, preserve_shadows=True),
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
