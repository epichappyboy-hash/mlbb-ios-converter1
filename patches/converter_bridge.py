from __future__ import annotations


class _BoundedCapture:
    """Bound captured UnityPy output so repeat conversions do not retain huge buffers."""
    def __init__(self, limit: int = 256 * 1024):
        from collections import deque
        self.limit = limit
        self.parts = deque()
        self.length = 0

    def write(self, value: str) -> int:
        value = str(value)
        written = len(value)
        if len(value) >= self.limit:
            self.parts.clear()
            self.parts.append(value[-self.limit:])
            self.length = self.limit
            return written
        if value:
            self.parts.append(value)
            self.length += len(value)
        while self.length > self.limit and self.parts:
            excess = self.length - self.limit
            first = self.parts[0]
            if len(first) <= excess:
                self.parts.popleft()
                self.length -= len(first)
            else:
                self.parts[0] = first[excess:]
                self.length -= excess
        return written

    def flush(self) -> None:
        pass

    def getvalue(self) -> str:
        return "".join(self.parts)


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
        sources = list(bundled.glob("*.unity3d"))
        # Replace existing Documents copies once when the updated shader bundle
        # first runs. Later runs only recreate missing files, preserving user edits.
        migration_marker = target / ".isha_shader_bundle_v3"
        if sources and not migration_marker.exists():
            for source in sources:
                shutil.copy2(source, target / source.name)
            temporary_marker = migration_marker.with_suffix(".tmp")
            temporary_marker.write_text("v3", encoding="utf-8")
            temporary_marker.replace(migration_marker)
        else:
            for source in sources:
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
    logs, capture = [], _BoundedCapture()
    output_dir = output_zip = None
    converter = report = None
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
                    # Reclaim cyclic objects left by _convert_bundle before opening
                    # another pair of UnityPy source/output environments for validation.
                    try:
                        import gc
                        gc.collect()
                    except Exception:
                        pass
                    saved_jobs = owner.jobs
                    owner.jobs = [job]
                    try:
                        # Validate each output as soon as it is produced.
                        # This bounds the number of live UnityPy object graphs.
                        Converter._validate_all(owner)
                    finally:
                        owner.jobs = saved_jobs
                    super().append(job)
                    owner._incrementally_validated.add(owner._job_key(job))
                    source = Path(job[0])
                    if owner._cache_root is not None:
                        try:
                            source.unlink(missing_ok=True)
                            owner.log(f"Validated and released temporary Android bundle: {source.name}")
                        except OSError as exc:
                            owner.log(f"WARNING: Could not release temporary bundle {source.name}: {exc}")
                    try:
                        import gc
                        collected = gc.collect()
                        _diagnostic(owner.output_parent, f"incremental validation finished for {source.name}; collected {collected} objects")
                    except Exception:
                        pass

            class _SpaceSavingConverter(Converter):
                def __init__(self, *args, **kwargs):
                    super().__init__(*args, **kwargs)
                    self._cache_root = _webdav_cache_root(self.input_path)
                    self._incrementally_validated = set()
                    self.jobs = _SpaceSavingJobs(self)
                    if self._cache_root is not None:
                        self.log("Low-storage mode enabled for WebDAV input.")

                @staticmethod
                def _job_key(job):
                    return (str(job[0]), str(job[1]))

                def _validate_all(self):
                    jobs = list(self.jobs)
                    if jobs and all(self._job_key(job) in self._incrementally_validated for job in jobs):
                        self.log("All converted bundles passed incremental validation.")
                        if self._cache_root is not None:
                            shutil.rmtree(self._cache_root, ignore_errors=True)
                            self.log("Released the remaining WebDAV input cache before ZIP creation.")
                        return
                    return super()._validate_all()

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
    finally:
        # UnityPy/Pillow keep sizable object graphs alive during bundle conversion.
        # Drop the converter/report references before collecting so a later
        # conversion doesn't inherit memory pressure from the previous one.
        converter = None
        report = None
        capture = None
        try:
            import gc
            collected = gc.collect()
            _diagnostic(output_path, f"post-conversion cleanup completed; collected {collected} objects")
        except Exception:
            pass
