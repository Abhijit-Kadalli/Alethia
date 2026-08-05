# Model weights

This directory holds optional local inference weights. Binaries are **gitignored**.

CrisperWhisper checkpoints are downloaded by the Python sidecar into the Hugging Face cache on first use (default size: `turbo`).

```bash
./Scripts/setup-crisperwhisper.sh
./Scripts/start-crisper-sidecar.sh
# optional notes / ECAPA placeholder:
./Scripts/download-models.sh
```
