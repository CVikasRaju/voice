#!/usr/bin/env python3
"""Fetch iTantra ML models — docs/SETUP_AND_BUILD.md §3.

Downloads pre-converted AI4Bharat IndicConformer INT8 ONNX models from
HuggingFace for fully offline on-device speech recognition.

STT Models: parismitaglobalsolutions/indicconformer-sherpa-onnx
  - AI4Bharat IndicConformer (NeMo CTC), INT8 quantized
  - ~150-200MB per language
  - Shared tokens.txt across all 10 Indic languages
  - English has its own model family (NeMo fast-conformer)

Usage:
    python scripts/fetch_models.py --lang hi,kn
    python scripts/fetch_models.py --lang all

Models are downloaded to assets/models/ (development) or the app's
documents directory (production).
"""

import argparse
import os
import sys
import urllib.request
from pathlib import Path

# ── Model Sources ────────────────────────────────────────────────────
# Pre-converted AI4Bharat IndicConformer models for sherpa-onnx.
# Source: https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx

BASE_URL = "https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx/resolve/main"

# Shared tokens file for all 10 Indic languages (verified identical).
INDIC_TOKENS_URL = f"{BASE_URL}/tokens.txt"

# Per-language INT8 ONNX models.
# Each is a NeMo CTC model exported from AI4Bharat's IndicConformer,
# quantized to INT8 with ~60% size reduction and no measurable quality loss.
STT_MODELS = {
    "hi": f"{BASE_URL}/hi/model.int8.onnx",
    "gu": f"{BASE_URL}/gu/model.int8.onnx",
    "mr": f"{BASE_URL}/mr/model.int8.onnx",
    "kn": f"{BASE_URL}/kn/model.int8.onnx",
    "ta": f"{BASE_URL}/ta/model.int8.onnx",
    "te": f"{BASE_URL}/te/model.int8.onnx",
    "ml": f"{BASE_URL}/ml/model.int8.onnx",
    # "or": Odia model not yet available on HuggingFace.
    # Convert manually from AI4Bharat checkpoint:
    #   https://github.com/AI4Bharat/IndicConformer
    "bn": f"{BASE_URL}/bn/model.int8.onnx",
    "en": f"{BASE_URL}/en/model.int8.onnx",
}

# English has its own tokens file (different model family).
EN_TOKENS_URL = f"{BASE_URL}/en/tokens.txt"

# All supported language codes.
ALL_LANGUAGES = list(STT_MODELS.keys())

ASSETS_DIR = Path("assets/models")


def download(url: str, dest: Path) -> None:
    """Download a file with progress indicator."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        size_mb = dest.stat().st_size / (1024 * 1024)
        print(f"  [skip] {dest.name} already exists ({size_mb:.1f} MB)")
        return

    print(f"  [download] {dest.name} ← {url[:80]}...")
    try:
        urllib.request.urlretrieve(url, dest)
        size_mb = dest.stat().st_size / (1024 * 1024)
        print(f"  [done] {dest.name} ({size_mb:.1f} MB)")
    except Exception as e:
        print(f"  [error] {dest.name}: {e}")
        # Remove partial download.
        if dest.exists():
            dest.unlink()


def fetch_language(lang: str) -> None:
    """Download STT model + tokens for one language."""
    if lang not in STT_MODELS:
        print(f"\n⚠ Unknown language '{lang}' — skip")
        return

    print(f"\n── {lang} ──")

    # Download model.
    model_url = STT_MODELS[lang]
    model_dir = ASSETS_DIR / "stt" / lang
    download(model_url, model_dir / "model.int8.onnx")

    # Download tokens (shared for Indic, separate for English).
    tokens_url = EN_TOKENS_URL if lang == "en" else INDIC_TOKENS_URL
    download(tokens_url, model_dir / "tokens.txt")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fetch iTantra ML models (AI4Bharat IndicConformer INT8)"
    )
    parser.add_argument(
        "--lang",
        type=str,
        default="hi",
        help="Comma-separated language codes (e.g. hi,kn,ta) or 'all'",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=None,
        help="Override output directory (default: assets/models/)",
    )
    args = parser.parse_args()

    global ASSETS_DIR
    if args.output_dir:
        ASSETS_DIR = Path(args.output_dir)

    print("=" * 60)
    print("iTantra Model Fetcher")
    print("AI4Bharat IndicConformer INT8 ONNX for sherpa-onnx")
    print("=" * 60)

    # Parse language list.
    if args.lang.strip().lower() == "all":
        languages = ALL_LANGUAGES
    else:
        languages = [l.strip() for l in args.lang.split(",")]

    # Fetch models.
    for lang in languages:
        fetch_language(lang)

    # Summary.
    print("\n" + "=" * 60)
    print("Download complete!")
    print(f"Models stored in: {ASSETS_DIR}")
    print("\nPer-language model sizes (INT8):")
    print("  ~150-200 MB each")
    print(f"  Total for {len(languages)} languages: ~{len(languages) * 175} MB")
    print("\nNext steps:")
    print("  1. Uncomment assets block in mobile/pubspec.yaml")
    print("  2. Run: flutter pub get")
    print("  3. Models are loaded on-demand when a language is selected")


if __name__ == "__main__":
    main()
