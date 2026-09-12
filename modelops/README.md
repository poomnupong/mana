# modelops

**A learn-by-doing workspace for the Apple-silicon model pipeline:** download → (optionally abliterate) → convert → quantize → serve via oMLX.

This folder is intentionally **not scripted**. The commands below are the workflow; running them yourself is how you learn the toolchain. The only "automation" here is `pyproject.toml`, which declares the Python tools you'll use.

**Host execution:** these commands run as your macOS user, outside the Hermes VM.
The virtual environment isolates dependencies, not files or Hugging Face credentials.
See the [security model](../docs/security-model.md).

**Validation scope:** this is a manual workflow, not an end-to-end tested pipeline.
The examples are not a memory-sizing recommendation: full-precision 32B processing
can exceed a 64 GiB Mac once working memory is included. Start with a small,
supported model and verify hardware/model compatibility before a large run.

## What this gives you

A reproducible Python environment (managed by [`uv`](https://docs.astral.sh/uv/)) containing:

| Tool | Role |
|------|------|
| `hf` (huggingface-hub) | Download models from HuggingFace, upload your outputs back |
| `mlx_lm.convert` | HF safetensors → MLX safetensors (format adapt), plus a baseline naive quantizer including `mxfp8` |
| `mlx_vlm.convert` / `mlx_vlm.generate` | Same role as `mlx_lm`, but for **vision-language models** (Qwen2-VL, LLaVA, Pixtral, Gemma-VL, Phi-3.5-Vision, …). Use for VLM format-adapt + smoke-testing image+text generation |
| `heretic` | Automated [abliteration](https://github.com/p-e-w/heretic) on Transformers-compatible models (optional workflow step, installed by `uv sync`) |

System-level (installed via Nix, available everywhere):

| Tool | Role |
|------|------|
| `uv` | Project + venv manager (what runs everything in here) |
| `hf` | Same `hf` CLI, system-wide for ad-hoc use |

Optional GGUF tools are not installed by Mana; see the [on-demand shell](#appendix-gguf).

Quantization to MLX is owned by **oMLX's built-in [oQ](https://github.com/jundot/omlx/blob/main/docs/oQ_Quantization.md)** — a calibration-driven, mixed-precision quantizer. It runs in the oMLX server (admin panel at `http://localhost:8000/admin`), **not** in this venv. We document the hand-off below.

## Default contract

- **Input:** HuggingFace **safetensors** — either raw HF (e.g. `meta-llama/...`, `Qwen/...`) or pre-converted MLX (`mlx-community/...`).
- **Output:** MLX safetensors, ready to drop into `~/.omlx/models/` and serve.
- **GGUF is not a supported input.** GGUF → MLX reverse paths are brittle; almost every model on HF also has an upstream safetensors release — use that. If you specifically want GGUF *output* for Ollama, see the [GGUF appendix](#appendix-gguf).

## Layout

```
modelops/
├── pyproject.toml      # declarative Python deps (committed)
├── uv.lock             # pinned versions incl. heretic git SHA (committed)
├── .python-version     # 3.12 (committed)
├── .gitignore          # ignores .venv/, models/, outputs/
├── README.md           # this file
├── models/             # HF downloads land here (gitignored)
└── outputs/            # your converted / abliterated artifacts (gitignored)
```

---

## First-time setup

From any shell configured by Mana:

```bash
modelops          # cd alias to this folder (set in home.nix)
uv sync --locked  # creates .venv/ from the committed lock; fails if it needs updating
```

Sanity-check:

```bash
uv run hf --help
uv run mlx_lm.convert --help
uv run mlx_vlm.convert --help
uv run heretic --help
```

If `hf` asks for auth (needed for gated models like Llama, for uploads, etc.):

```bash
uv run hf auth login
```

---

## Workflow

### 1. Download from HuggingFace

```bash
HF_SOURCE=models/qwen-coder-32b-hf
uv run hf download Qwen/Qwen2.5-Coder-32B-Instruct \
  --local-dir "$HF_SOURCE"
```

Alternatively, download pre-converted MLX weights and skip steps 2 and 3:

```bash
MLX_SOURCE=models/qwen-coder-32b
uv run hf download mlx-community/Qwen2.5-Coder-32B-Instruct-bf16 \
  --local-dir "$MLX_SOURCE"
```

Keep the selected variables in the same shell for the following steps. HF and MLX
can both use safetensors files, but their model layouts are not interchangeable.

Hugging Face uses `hf-xet` for accelerated transfers. For optional high-throughput
mode, prefix a download with `HF_XET_HIGH_PERFORMANCE=1`. This can increase CPU,
disk, and network utilization; leave it unset for normal use. See the
[upstream transfer settings](https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables#hfxethighperformance).

### 2. (Optional) Abliterate with Heretic

[Heretic](https://github.com/p-e-w/heretic) uses PyTorch/Transformers rather than
MLX. Use the raw HF checkpoint before conversion, not the pre-converted MLX branch.
Review `uv run heretic --help` and the
[usage guide at the pinned revision](https://github.com/p-e-w/heretic/blob/2fd163f5e401e6ce81a3d68d4e7dcf9e91a4045c/README.md#usage)
for supported models and hardware requirements.

```bash
uv run heretic "$HF_SOURCE"
```

The pinned version offers save/export interactively after processing; it does not
have a `--save` option. Export a **merged Transformers model** (not just an adapter)
to a new directory such as `outputs/qwen-coder-32b-hf-abl`. After a successful export,
select it as the conversion input:

```bash
HF_SOURCE=outputs/qwen-coder-32b-hf-abl
```

If you skip this step, leave `HF_SOURCE` pointing to the original download.
This path keeps model modification before the MLX quantization step.

### 3. Convert HF → MLX (skip for pre-converted MLX)

For text-only LLMs, convert the selected original or modified HF checkpoint.
Use a fresh output directory so a previous run is not mistaken for this result:

```bash
MLX_SOURCE=outputs/qwen-coder-32b-mlx
uv run mlx_lm.convert \
  --hf-path "$HF_SOURCE" \
  --mlx-path "$MLX_SOURCE"
```

For **vision-language models** (Qwen2-VL, LLaVA, Pixtral, Gemma-VL, Phi-3.5-Vision, …), swap in `mlx_vlm.convert` — same flag shape, but it also carries the vision tower / image processor across:

```bash
MLX_SOURCE=outputs/qwen2-vl-7b-mlx
uv run mlx_vlm.convert \
  --hf-path models/qwen2-vl-7b-hf \
  --mlx-path "$MLX_SOURCE"
```

Smoke-test the converted VLM end-to-end with an image:

```bash
uv run mlx_vlm.generate \
  --model outputs/qwen2-vl-7b-mlx \
  --image path/to/image.jpg \
  --prompt "Describe this image."
```

Both converters can also quantize. Here they are used only for format conversion:
leave `-q` off to keep full-precision weights for the next step.

### 4. Quantize

You have two routes. Pick based on what you want.

Both routes below consume `MLX_SOURCE`, so they use the model selected or produced
above, including the modified checkpoint when step 2 was used. The paths and
CLI example below are for the text-model branch; use the corresponding VLM
converter and model-specific support checks for vision models.

#### Route A — oMLX `oQ` (recommended)

oQ is a data-driven mixed-precision quantizer: it runs calibration inference, measures per-layer sensitivity (MSE of float-vs-quantized outputs), and boosts bits where they matter. **Output is standard MLX safetensors** — usable in any MLX runtime, not just oMLX.

1. Stage the model into oMLX's model directory:

   ```bash
  mkdir -p ~/.omlx/models
  cp -R "$MLX_SOURCE" ~/.omlx/models/qwen-coder-32b-source
   # or symlink if you'd rather not duplicate:
  ln -s "$PWD/$MLX_SOURCE" ~/.omlx/models/qwen-coder-32b-source
   ```

  Choose copy or symlink, not both, and use a destination that does not already exist.

2. Open `http://localhost:8000/admin` → **Models** → **oQ Quantization** tab.
3. Pick the source model and an **oQ level**:

   | Level | Target bpw | Use case |
   |-------|-----------:|----------|
   | oQ2   | ~2.9 | extreme compression (RAM-constrained) |
   | oQ3   | ~3.5 | balanced |
   | oQ3.5 | ~3.8 | quality-balanced |
   | **oQ4** | **~4.6** | **default; recommended starting point** |
   | oQ5   | ~5.5 | high quality |
   | oQ6   | ~6.5 | near-lossless |
   | oQ8   | ~8.6 | near-lossless (mxfp8 base, gs=32) |

   Levels 2–6 use affine quant (gs=64); level 8 uses mxfp8 (gs=32). oQ+ (with GPTQ weight optimization) is opt-in inside the same tab.

4. The server pauses inference while quantizing (clients will see 503s). When done, the quantized model appears as a separately loadable entry.

See [oQ_Quantization.md](https://github.com/jundot/omlx/blob/main/docs/oQ_Quantization.md) for the full algorithm description.

#### Route B — `mlx-lm` naive quant (fast baseline)

Useful for a quick A/B against oQ at the same bits, or when you just want a fast 8-bit version and don't want to wait on calibration.

```bash
# Affine 4-bit (gs=64), the mlx-lm default:
uv run mlx_lm.convert \
  --hf-path "$MLX_SOURCE" \
  -q --q-bits 4 --q-group-size 64 \
  --mlx-path outputs/qwen-coder-32b-mlx-q4
```

For `mxfp8`, consult `uv run mlx_lm.convert --help` for the installed version's
quantization mode and supported group sizes. Do not copy flags from a different
release. This baseline has no oQ calibration or per-layer sensitivity selection;
runtime and memory requirements depend on the model and hardware.

### 5. Serve

```bash
# If you used Route A (oQ), it's already in ~/.omlx/models/
# If you used Route B (mlx-lm), stage it:
cp -R outputs/qwen-coder-32b-mlx-q4 ~/.omlx/models/qwen-coder-32b-mlx-q4
```

Refresh `http://localhost:8000/admin` → Models tab; the new model should auto-detect. Load / pin / set TTL from the UI.

### 6. (Optional) Upload to HuggingFace

**Primary path: oMLX admin → "oQ Uploader" tab.** It generates a model card with the quantization details (bit-allocation breakdown, calibration info, oMLX version) and pushes to your HF account. This is the path designed for oQ outputs.

**Fallback (any model, scripted):**

```bash
uv run hf upload <your-username>/<repo-name> outputs/<dir> . --repo-type model
```

Run `uv run hf auth login` once first if you haven't.

---

## Maintenance

Upgrade one package (the typical case — e.g. bump Heretic to latest `main`):

```bash
uv lock --upgrade-package heretic-llm
uv sync
# run a small smoke test, then commit uv.lock
```

Bump everything within the version constraints in `pyproject.toml`:

```bash
uv lock --upgrade
uv sync
```

Validate by running steps 1–4 end-to-end on a small model (e.g. `Qwen/Qwen2.5-0.5B`) before committing the updated lockfile.

This validation is a manual follow-up, not something `mana doctor` or the lifecycle
tests exercise. Review the pinned Heretic usage link when changing its revision.

---

## Appendix: GGUF

The MLX pipeline above does not consume GGUF. If you specifically need GGUF *output* (e.g. for Ollama or `llama-cli`), open an on-demand shell instead of adding `llama-cpp` to the default system closure:

```bash
nix shell nixpkgs#llama-cpp
```

That shell provides:

```bash
# Convert HF safetensors → GGUF (fp16 base):
# (use llama.cpp's convert_hf_to_gguf.py — installed alongside llama-cpp, path may
#  vary; run `which llama-quantize` and check the same directory)

# Quantize GGUF → smaller K-quant:
llama-quantize input.fp16.gguf output.Q4_K_M.gguf Q4_K_M

# Smoke-run:
llama-cli -m output.Q4_K_M.gguf -p "hello"
```

**GGUF → MLX is not supported here.** If a model is published only as GGUF, you're almost always better off finding the original HF safetensors upload (search the model card for the upstream link) than attempting a reverse conversion.
