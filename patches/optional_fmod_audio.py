#!/usr/bin/env python3
"""Make UnityPy's optional FMOD audio decoder non-fatal for the iOS converter."""
from __future__ import annotations

import argparse
from pathlib import Path

IMPORT_OLD = "import fmod_toolkit"
IMPORT_NEW = """try:
    import fmod_toolkit
except ModuleNotFoundError:
    # FMOD's native runtime is not part of this iOS texture-conversion build.
    # UnityPy can still handle OGG/WAV/M4A passthrough and all non-audio assets.
    fmod_toolkit = None
"""
CALL_OLD = """    return fmod_toolkit.raw_to_wav(
        audio_data,
        audio.m_Name,
        audio.m_Channels or 2,
        audio.m_Frequency or 44100,
        convert_pcm_float=convert_pcm_float,
    )
"""
CALL_NEW = """    if fmod_toolkit is None:
        raise RuntimeError(
            "FMOD audio decoding is unavailable in this iOS build. "
            "Raw FMOD-compressed audio cannot be exported, but texture/material "
            "conversion and already-encoded OGG/WAV/M4A passthrough are supported."
        )

    return fmod_toolkit.raw_to_wav(
        audio_data,
        audio.m_Name,
        audio.m_Channels or 2,
        audio.m_Frequency or 44100,
        convert_pcm_float=convert_pcm_float,
    )
"""
MARKER = "FMOD audio decoding is unavailable in this iOS build."


def patch(path: Path) -> bool:
    source = path.read_text(encoding="utf-8")
    if MARKER in source and "except ModuleNotFoundError:" in source:
        compile(source, str(path), "exec")
        return False
    if IMPORT_OLD not in source:
        raise SystemExit(f"Could not find required import in {path}")
    if CALL_OLD not in source:
        raise SystemExit(f"Could not find FMOD decode call in {path}")
    source = source.replace(IMPORT_OLD, IMPORT_NEW, 1)
    source = source.replace(CALL_OLD, CALL_NEW, 1)
    compile(source, str(path), "exec")
    path.write_text(source, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    changed = patch(args.source)
    print("Applied optional FMOD import fix." if changed else "Optional FMOD fix already present.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
