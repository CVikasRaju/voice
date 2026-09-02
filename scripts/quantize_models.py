#!/usr/bin/env python3
"""INT8 quantization pipeline — docs/ML_PIPELINE.md §3.

Converts FP32 ONNX models to INT8 (~65-75% size reduction, roughly
halved inference latency). Must be run AFTER fetch_models.py.

Usage:
    python scripts/quantize_models.py
    python scripts/quantize_models.py --input models/hi/vits-hi.onnx

Requires: onnxruntime[cpu] >= 1.16
    pip install "onnxruntime[cpu]>=1.16"
"""

import argparse
import os
import sys
from pathlib import Path

try:
    from onnxruntime.quantization import quantize_dynamic, QuantType
except ImportError:
    print("Error: onnxruntime is required.")
    print("Install it: pip install 'onnxruntime[cpu]>=1.16'")
    sys.exit(1)

ASSETS_DIR = Path("assets/models")


def quantize_model(input_path: Path, output_path: Path) -> None:
    """Quantize a single FP32 ONNX model to INT8."""
    if not input_path.exists():
        print(f"  [skip] {input_path} not found")
        return

    output_path.parent.mkdir(parents=True, exist_ok=True)

    orig_size = input_path.stat().st_size / (1024 * 1024)
    print(f"  [quantize] {input_path.name} ({orig_size:.1f} MB)")

    quantize_dynamic(
        model_input=str(input_path),
        model_output=str(output_path),
        weight_type=QuantType.QInt8,
        optimize_model=True,
    )

    quant_size = output_path.stat().st_size / (1024 * 1024)
    reduction = (1 - quant_size / orig_size) * 100
    print(
        f"  [done] {output_path.name} "
        f"({quant_size:.1f} MB, {reduction:.0f}% reduction)"
    )


def quantize_language(lang: str) -> None:
    """Quantize all ONNX models for one language."""
    print(f"\n── {lang} ──")

    # STT models
    stt_dir = ASSETS_DIR / "stt" / lang
    for model_file in ("encoder.onnx", "decoder.onnx"):
        src = stt_dir / model_file
        dst = stt_dir / model_file.replace(".onnx", ".int8.onnx")
        if src.exists() and not dst.exists():
            quantize_model(src, dst)

    # TTS model
    tts_dir = ASSETS_DIR / "tts" / lang
    for model_file in tts_dir.glob("*.onnx"):
        if ".int8." not in model_file.name:
            dst = model_file.with_suffix("").with_suffix(".int8.onnx")
            if not dst.exists():
                quantize_model(model_file, dst)


def quantize_single(input_path: str) -> None:
    """Quantize a single explicitly-specified model."""
    src = Path(input_path)
    if not src.exists():
        print(f"Error: {src} not found")
        sys.exit(1)
    dst = src.with_suffix("").with_suffix(".int8.onnx")
    quantize_model(src, dst)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="INT8 quantization for iTantra ONNX models"
    )
    parser.add_argument(
        "--input",
        type=str,
        default=None,
        help="Quantize a single specific model file",
    )
    args = parser.parse_args()

    print("=" * 60)
    print("iTantra INT8 Quantization")
    print("=" * 60)

    if args.input:
        quantize_single(args.input)
    else:
        # Auto-discover languages that have model directories.
        lang_dirs = []
        stt_base = ASSETS_DIR / "stt"
        if stt_base.exists():
            lang_dirs = [
                d.name for d in stt_base.iterdir() if d.is_dir()
            ]

        if not lang_dirs:
            print("\nNo language model directories found in assets/models/stt/")
            print("Run fetch_models.py first.")
            sys.exit(1)

        for lang in sorted(lang_dirs):
            quantize_language(lang)

    print("\n✓ Quantization complete.")


if __name__ == "__main__":
    main()
