# TTS Models Directory

This directory is empty because AI4Bharat Indic-TTS models use **FastPitch + HiFi-GAN** (PyTorch), not VITS. No pre-converted ONNX models exist for Indic TTS in the sherpa-onnx ecosystem.

## Current Status

- **Platform TTS** is used as the fallback (fully on-device on Android).
- Android ships with Indic language TTS voices in most OEM builds.
- Quality is acceptable for the hackathon demo.

## How to Add ONNX TTS Models

### Option 1: Convert AI4Bharat Indic-TTS

```bash
# From the AI4Bharat/Indic-TTS repo:
git clone https://github.com/AI4Bharat/Indic-TTS
cd Indic-TTS

# Convert FastPitch to ONNX
python -c "
import torch
model = torch.load('hi/fastpitch/best_model.pth')
torch.onnx.export(model, dummy_input, 'hi/fastpitch.onnx')
"

# Convert HiFi-GAN vocoder to ONNX
python -c "
import torch
model = torch.load('hi/hifigan/best_model.pth')
torch.onnx.export(model, dummy_input, 'hi/hifigan.onnx')
"
```

### Option 2: Use Meta MMS-TTS

Meta's MMS-TTS already has ONNX exports for Indic languages:

```bash
# Download from HuggingFace
pip install huggingface_hub
python -c "
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id='facebook/mms-tts-hin', filename='model.onnx', local_dir='hi')
"
```

### Option 3: Use sherpa-onnx VITS Models

See sherpa-onnx TTS documentation:
https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/index.html

## Integration

Once you have ONNX TTS models, place them in this directory:

```
tts/
├── hi/
│   ├── model.onnx
│   └── tokens.txt
├── kn/
│   ├── model.onnx
│   └── tokens.txt
└── ...
```

Then update `mobile/lib/ml/tts_engine.dart` to use sherpa-onnx instead of platform TTS.
