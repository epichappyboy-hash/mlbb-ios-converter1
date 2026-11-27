"""Offline skin-package inspection and safe local backup/restore for Isha."""
from __future__ import annotations
import hashlib, json, os, shutil, stat, time, uuid, zipfile
from pathlib import Path, PurePosixPath

ENGINE_VERSION = "1.0.0"
MAX_FILES = 50000
MAX_ENTRY_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_RATIO = 1000

class SkinPackageError(RuntimeError):
    pass

def _sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def _relative(name: str) -> Path:
    if not name or "\x00" in name:
        raise SkinPackageError("Archive contains an invalid path.")
    normalized = name.replace("\\", "/")
    path = PurePosixPath(normalized)
    if path.is_absolute() or normalized.startswith("/") or any(x in {"", ".", ".."} for x in path.parts):
        raise SkinPackageError(f"Unsafe archive path refused: {name}")
    if path.parts and ":" in path.parts[0]:
        raise SkinPackageError(f"Drive-qualified archive path refused: {name}")
    return Path(*path.parts)

def _unity_info(path: Path) -> dict:
    with path.open("rb") as stream:
        head = stream.read(16)
    signature = next((s.decode("ascii") for s in (b"UnityFS", b"UnityRaw", b"UnityWeb", b"UnityArchive") if head.startswith(s)), "unknown")
    result = {"unityHeader": signature, "unityPyReadable": False, "objectCount": None, "objectTypes": []}
    try:
        import UnityPy
        env = UnityPy.load(str(path))
        counts = {}
        for obj in env.objects:
            kind = str(getattr(getattr(obj, "type", None), "name", "Unknown"))
            counts[kind] = counts.get(kind, 0) + 1
        result.update(unityPyReadable=True, objectCount=len(env.objects),
                      objectTypes=[{"name": k, "count": counts[k]} for k in sorted(counts)])
    except Exception as exc:
        result["unityPyError"] = f"{type(exc).__name__}: {exc}"[:400]
    return result

def _extract_zip(source: Path, destination: Path) -> dict:
    destination.mkdir(parents=True, exist_ok=True)
    seen, total, count = set(), 0, 0
    with zipfile.ZipFile(source) as archive:
        bad = archive.testzip()
        if bad:
            raise SkinPackageError(f"ZIP CRC validation failed at {bad}")
        infos = archive.infolist()
        if len(infos) > MAX_FILES:
            raise SkinPackageError("ZIP contains too many entries.")
        for info in infos:
            rel = _relative(info.filename)
            if info.is_dir():
                (destination / rel).mkdir(parents=True, exist_ok=True)
                continue
            mode = (info.external_attr >> 16) & 0xffff
            if stat.S_ISLNK(mode):
                raise SkinPackageError(f"Symbolic link refused: {info.filename}")
            key = rel.as_posix().casefold()
            if key in seen:
                raise SkinPackageError(f"Duplicate or case-colliding path: {info.filename}")
            seen.add(key)
            if info.file_size > MAX_ENTRY_BYTES:
                raise SkinPackageError(f"File exceeds size limit: {info.filename}")
            total += info.file_size
            if total > MAX_TOTAL_BYTES:
                raise SkinPackageError("ZIP exceeds total uncompressed size limit.")
            if info.file_size and info.compress_size == 0:
                raise SkinPackageError(f"Invalid compressed size: {info.filename}")
            if info.compress_size and info.file_size / info.compress_size > MAX_RATIO:
                raise SkinPackageError(f"Suspicious compression ratio: {info.filename}")
            target = destination / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as src, target.open("xb") as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
            count += 1
    return {"entryCount": len(infos), "fileCount": count, "uncompressedBytes": total}

def _inspect(root: Path):
    files = sorted(p for p in root.rglob("*") if p.is_file())
    if len(files) > MAX_FILES:
        raise SkinPackageError("Package contains too many files.")
    entries, bundles, total = [], [], 0
    for path in files:
        relative, size = path.relative_to(root).as_posix(), path.stat().st_size
        total += size
        if size > MAX_ENTRY_BYTES or total > MAX_TOTAL_BYTES:
            raise SkinPackageError(f"Package size limit exceeded: {relative}")
        record = {"path": relative, "size": size, "sha256": _sha(path), "kind": path.suffix.lower().lstrip(".") or "file"}
        entries.append(record)
        if path.suffix.lower() == ".unity3d":
            bundle = dict(record)
            bundle.update(_unity_info(path))
            bundles.append(bundle)
    return entries, bundles

def _write_json(path: Path, value: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, path)

def _manifest(operation_root: Path):
    try:
        value = json.loads((operation_root / "package_manifest.json").read_text(encoding="utf-8"))
    except Exception as exc:
        raise SkinPackageError(f"Package manifest is unavailable: {exc}") from exc
    if value.get("engineVersion") != ENGINE_VERSION:
        raise SkinPackageError("Unsupported package manifest version.")
    return value

def prepare_package(input_path: str | Path, workspace_root: str | Path) -> dict:
    """Make a hash-verified original backup and a safe, inspectable working copy."""
    source, workspace = Path(input_path).resolve(), Path(workspace_root).resolve()
    if not source.is_file() or source.suffix.lower() not in {".zip", ".unity3d"}:
        raise SkinPackageError("Choose a readable .zip or .unity3d package.")
    operation_id = uuid.uuid4().hex[:16]
    root = workspace / "operations" / operation_id
    backup_dir, source_dir = root / "backup", root / "source"
    backup_dir.mkdir(parents=True, exist_ok=False)
    try:
        backup = backup_dir / source.name
        shutil.copy2(source, backup)
        source_hash, backup_hash = _sha(source), _sha(backup)
        if source_hash != backup_hash:
            raise SkinPackageError("Original backup SHA-256 does not match.")
        if source.suffix.lower() == ".zip":
            archive_info, fmt = _extract_zip(source, source_dir), "zip"
        else:
            source_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, source_dir / source.name)
            archive_info, fmt = {"entryCount": 1, "fileCount": 1, "uncompressedBytes": source.stat().st_size}, "unity3d"
        entries, bundles = _inspect(source_dir)
        if not bundles:
            raise SkinPackageError("No .unity3d resources were found in the package.")
        report = {
            "engineVersion": ENGINE_VERSION, "operationId": operation_id, "createdAtUnix": int(time.time()),
            "sourceName": source.name, "sourceSize": source.stat().st_size, "sourceSHA256": source_hash,
            "backupRelativePath": backup.relative_to(root).as_posix(), "backupSHA256": backup_hash,
            "packageFormat": fmt, "archive": archive_info, "unityBundleCount": len(bundles),
            "entries": entries, "unityBundles": bundles,
            "validation": {"archiveCRC": "passed" if fmt == "zip" else "not-applicable",
                           "backupSHA256": "passed", "unityBundlePresent": True},
            "notice": "Offline inspection/conversion only. This operation does not modify installed game files."
        }
        _write_json(root / "package_manifest.json", report)
        return {"ok": True, "operationId": operation_id, "operationPath": str(root), "report": report}
    except Exception:
        shutil.rmtree(root, ignore_errors=True)
        raise

def verify_operation(operation_id: str, workspace_root: str | Path) -> dict:
    if not operation_id or any(c not in "0123456789abcdef" for c in operation_id.lower()):
        raise SkinPackageError("Invalid operation ID.")
    root = Path(workspace_root).resolve() / "operations" / operation_id
    data = _manifest(root)
    backup = root / data["backupRelativePath"]
    backup_ok = backup.is_file() and _sha(backup) == data["backupSHA256"]
    missing, changed = [], []
    for entry in data["entries"]:
        path = root / "source" / _relative(entry["path"])
        if not path.is_file():
            missing.append(entry["path"])
        elif path.stat().st_size != entry["size"] or _sha(path) != entry["sha256"]:
            changed.append(entry["path"])
    return {"ok": backup_ok and not missing and not changed, "operationId": operation_id,
            "backupValid": backup_ok, "missingEntries": missing, "changedEntries": changed}

def restore_original(operation_id: str, workspace_root: str | Path, destination: str | Path) -> dict:
    root = Path(workspace_root).resolve() / "operations" / operation_id
    data = _manifest(root)
    backup = root / data["backupRelativePath"]
    if not backup.is_file() or _sha(backup) != data["backupSHA256"]:
        raise SkinPackageError("Original backup is missing or checksum-invalid.")
    target = Path(destination).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise SkinPackageError("Restore destination already exists.")
    temp = target.with_name(target.name + ".restore-tmp")
    shutil.copy2(backup, temp)
    if _sha(temp) != data["backupSHA256"]:
        temp.unlink(missing_ok=True)
        raise SkinPackageError("Restored package checksum mismatch.")
    os.replace(temp, target)
    return {"ok": True, "operationId": operation_id, "restoredPath": str(target), "sha256": data["backupSHA256"]}

def repair_operation(operation_id: str, workspace_root: str | Path) -> dict:
    root = Path(workspace_root).resolve() / "operations" / operation_id
    data = _manifest(root)
    backup = root / data["backupRelativePath"]
    if not backup.is_file() or _sha(backup) != data["backupSHA256"]:
        raise SkinPackageError("Cannot repair: original backup is missing/corrupt.")
    temp, source = root / "source.repairing", root / "source"
    shutil.rmtree(temp, ignore_errors=True)
    if data["packageFormat"] == "zip":
        _extract_zip(backup, temp)
    else:
        temp.mkdir(parents=True, exist_ok=True)
        shutil.copy2(backup, temp / data["sourceName"])
    entries, bundles = _inspect(temp)
    if {x["path"]: x["sha256"] for x in entries} != {x["path"]: x["sha256"] for x in data["entries"]}:
        shutil.rmtree(temp, ignore_errors=True)
        raise SkinPackageError("Repaired files do not match the original backup.")
    shutil.rmtree(source, ignore_errors=True)
    os.replace(temp, source)
    data["entries"], data["unityBundles"] = entries, bundles
    data["repairCount"] = int(data.get("repairCount", 0)) + 1
    data["lastRepairAtUnix"] = int(time.time())
    data["validation"]["repair"] = "passed"
    _write_json(root / "package_manifest.json", data)
    return {"ok": True, "operationId": operation_id, "repairedFiles": len(entries), "repairCount": data["repairCount"]}
