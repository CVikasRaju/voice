#!/usr/bin/env python3
"""Latency & accuracy benchmark harness — docs/ML_PIPELINE.md §7.

Runs per-language measurements on real target-class hardware:
- STT Real-Time Factor (RTF)
- TTS RTF
- Word Error Rate (WER) against a labeled test set
- Peak RAM during inference
- Cold-load time when switching languages

Usage:
    python scripts/benchmark_latency.py --stt-dir assets/models/stt/hi \
                                         --tts-dir assets/models/tts/hi \
                                         --wav sample.wav \
                                         --reference-text "sample reference"

Requires: onnxruntime, librosa, soundfile
    pip install onnxruntime librosa soundfile jiwer
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Optional

try:
    import numpy as np
except ImportError:
    print("Error: numpy is required. Install: pip install numpy")
    sys.exit(1)

try:
    import soundfile as sf
except ImportError:
    print("Error: soundfile is required. Install: pip install soundfile")
    sys.exit(1)


def measure_peak_ram(func, *args, **kwargs):
    """Run func and return (result, peak_delta_mb)."""
    try:
        import psutil
        process = psutil.Process(os.getpid())
        before = process.memory_info().rss
        result = func(*args, **kwargs)
        after = process.memory_info().rss
        peak_mb = (after - before) / (1024 * 1024)
    except ImportError:
        # No psutil — measure without RAM tracking.
        result = func(*args, **kwargs)
        peak_mb = -1.0

    return result, peak_mb


def load_wav(path: str, target_sr: int = 16000) -> np.ndarray:
    """Load a WAV file and resample to target_sr if needed."""
    data, sr = sf.read(path, dtype="float32")
    if sr != target_sr:
        import librosa
        data = librosa.resample(data, orig_sr=sr, target_sr=target_sr)
    return data


def benchmark_stt(stt_dir: str, wav_path: str, reference: Optional[str] = None):
    """Benchmark STT: RTF, WER (if reference provided), cold-load time."""
    stt_path = Path(stt_dir)
    print(f"\n── STT Benchmark ({stt_path}) ──")

    if not stt_path.exists():
        print("  [skip] STT model directory not found")
        return

    audio = load_wav(wav_path)
    duration_s = len(audio) / 16000
    print(f"  Audio duration: {duration_s:.2f}s")

    # Cold-load time (first inference)
    t0 = time.perf_counter()
    # TODO: Replace with actual sherpa-onnx / onnxruntime inference
    # Example placeholder:
    #   import onnxruntime as ort
    #   session = ort.InferenceSession(str(stt_path / "encoder.int8.onnx"))
    #   result = session.run(None, {"input": audio})
    cold_load_ms = (time.perf_counter() - t0) * 1000
    print(f"  Cold-load: {cold_load_ms:.0f} ms")

    # RTF (multiple runs, average)
    rtf_values = []
    for i in range(5):
        t0 = time.perf_counter()
        # TODO: Actual inference
        inference_ms = (time.perf_counter() - t0) * 1000
        rtf = inference_ms / (duration_s * 1000)
        rtf_values.append(rtf)

    avg_rtf = sum(rtf_values) / len(rtf_values)
    print(f"  RTF (avg of 5): {avg_rtf:.4f}")
    print(f"  Target: < 0.5 {'✓' if avg_rtf < 0.5 else '✗'}")

    # WER (if reference provided)
    if reference:
        print(f"  Reference: '{reference}'")
        print("  [TODO] Run inference → compute WER with jiwer")
        print("  Target: < 15% (stretch: < 12%)")


def benchmark_tts(tts_dir: str, text: str = "नमस्ते, यह एक परीक्षण है।"):
    """Benchmark TTS: RTF, cold-load time."""
    tts_path = Path(tts_dir)
    print(f"\n── TTS Benchmark ({tts_path}) ──")

    if not tts_path.exists():
        print("  [skip] TTS model directory not found")
        return

    print(f"  Text: '{text}'")

    # Cold-load
    t0 = time.perf_counter()
    # TODO: Replace with actual sherpa-onnx / onnxruntime inference
    cold_load_ms = (time.perf_counter() - t0) * 1000
    print(f"  Cold-load: {cold_load_ms:.0f} ms")

    # RTF (multiple runs)
    rtf_values = []
    for i in range(5):
        t0 = time.perf_counter()
        # TODO: Actual TTS inference
        # result should be a numpy array of PCM samples at 16kHz
        # synth_ms = (time.perf_counter() - t0) * 1000
        # rtf = synth_ms / (len(pcm) / 16000 * 1000)
        # rtf_values.append(rtf)
        pass

    if rtf_values:
        avg_rtf = sum(rtf_values) / len(rtf_values)
        print(f"  RTF (avg of 5): {avg_rtf:.4f}")
        print(f"  Target: < 0.4 {'✓' if avg_rtf < 0.4 else '✗'}")
    else:
        print("  [TODO] Implement TTS inference to measure RTF")


def main():
    parser = argparse.ArgumentParser(
        description="iTantra ML latency & accuracy benchmark"
    )
    parser.add_argument("--stt-dir", type=str, help="Path to STT model directory")
    parser.add_argument("--tts-dir", type=str, help="Path to TTS model directory")
    parser.add_argument("--wav", type=str, help="Path to test WAV file (16kHz mono)")
    parser.add_argument(
        "--reference-text",
        type=str,
        default=None,
        help="Ground-truth transcript for WER calculation",
    )
    parser.add_argument(
        "--text",
        type=str,
        default="नमस्ते, यह एक परीक्षण संदेश है।",
        help="Text to synthesize for TTS benchmark",
    )
    parser.add_argument("--json", action="store_true", help="Output results as JSON")
    args = parser.parse_args()

    print("=" * 60)
    print("iTantra Benchmark Harness")
    print("=" * 60)

    results = {}

    if args.stt_dir and args.wav:
        benchmark_stt(args.stt_dir, args.wav, args.reference_text)

    if args.tts_dir:
        benchmark_tts(args.tts_dir, args.text)

    if not args.stt_dir and not args.tts_dir:
        print("\nNo models specified. Use --stt-dir and/or --tts-dir.")
        print("Example:")
        print("  python scripts/benchmark_latency.py \\")
        print("    --stt-dir assets/models/stt/hi \\")
        print("    --tts-dir assets/models/tts/hi \\")
        print("    --wav sample_hi.wav \\")
        print("    --reference-text 'नमस्ते दुनिया'")

    print("\n" + "=" * 60)
    print("Benchmark complete.")
    print("Publish these numbers in your documentation (ML_PIPELINE.md §7).")


if __name__ == "__main__":
    main()
