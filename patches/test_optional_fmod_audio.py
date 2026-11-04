#!/usr/bin/env python3
"""Smoke-test UnityPy AudioClipConverter without the optional fmod_toolkit package."""
from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path
from types import SimpleNamespace

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
compile(source, str(path), "exec")

assert "except ModuleNotFoundError:" in source
assert "FMOD audio decoding is unavailable in this iOS build." in source

# Build the minimal package context needed for the relative ResourceReader import.
unitypy = types.ModuleType("UnityPy")
unitypy.__path__ = []
export = types.ModuleType("UnityPy.export")
export.__path__ = []
helpers = types.ModuleType("UnityPy.helpers")
helpers.__path__ = []
reader = types.ModuleType("UnityPy.helpers.ResourceReader")
reader.get_resource_data = lambda *args, **kwargs: b""
sys.modules.update({
    "UnityPy": unitypy,
    "UnityPy.export": export,
    "UnityPy.helpers": helpers,
    "UnityPy.helpers.ResourceReader": reader,
})
# Ensure this test represents the iOS bundle, where fmod_toolkit is absent.
sys.modules.pop("fmod_toolkit", None)

spec = importlib.util.spec_from_file_location("UnityPy.export.AudioClipConverter", path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# Already encoded audio must pass through unchanged without FMOD.
ogg = b"OggS" + b"test-audio"
audio = SimpleNamespace(
    m_AudioData=ogg, m_Name="voice", m_Channels=2, m_Frequency=44100, m_Resource=None
)
assert module.extract_audioclip_samples(audio) == {"voice.ogg": ogg}

wav = b"RIFF" + b"test-audio"
audio.m_AudioData = wav
assert module.extract_audioclip_samples(audio) == {"voice.wav": wav}

# Raw FMOD-compressed audio should fail only when that exact operation is requested.
audio.m_AudioData = b"FMODRAW" + b"payload"
try:
    module.extract_audioclip_samples(audio)
except RuntimeError as exc:
    assert "FMOD audio decoding is unavailable" in str(exc)
else:
    raise AssertionError("Expected a clear optional-FMOD RuntimeError")

print("PASS: UnityPy AudioClipConverter imports without fmod_toolkit.")
print("PASS: OGG/WAV passthrough works without fmod_toolkit.")
print("PASS: only raw FMOD audio decoding reports an explicit unsupported-operation error.")
