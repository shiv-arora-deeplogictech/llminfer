# llminfer

**v0.1** — LLM Model Runtime for Private AI Models

LLMinfer is a 100% TekMonks-developed LLM inference runtime. It uses **Monkshu** as its API server and **vLLM** for model execution. The goal is to reduce any AI deployment to: deploy Monkshu → clone llminfer → run it.

Supports:
- **vLLM** backend — any Hugging Face model (e.g. `google/gemma-3-4b-it`)
- Both **JSON** and **SSE (streaming)** APIs — zero extra code, handled automatically by Monkshu's API registry

---

## How It Works

```
llminfer.sh [model] [opts]
    │
    ├── Bootstrap Python venv (python/python.sh)
    ├── Download HF model → models/<slug>/   [vLLM only; skipped for Ollama]
    ├── Write backend/apps/llminfer/conf/runner.json  (all resolved config)
    └── node monkshu/backend/server/server.js
            │
            ├── Monkshu starts, registers routes from apiregistry.json
            ├── app.js preinitSync → loads runner.json → sets global.LLMINFER_CONSTANTS
            └── app.js initSync   → starts inference engine (vLLM or Ollama)
                    │
                    first /infer request → engine ready → response returned
```

`llminfer.sh` owns all configuration. It resolves the model, ports, backend, and writes `runner.json` before handing off to Monkshu. Monkshu then discovers the llminfer app automatically via symlinks set up by `mklink.sh`.

`main.js` is a **CLI debug tool only** — useful for testing inference directly without HTTP. It is not in the production startup path.

---

## Setup

### Prerequisites

- **Node.js** (v18+)
- **Python 3** (for vLLM backend)
- **Ollama** installed and running (for Ollama backend only)
- `monkshu` and `llminfer` must be **sibling directories** under the same parent

### 1. Clone both repos side by side

```bash
git clone https://github.com/TekMonksGitHub/monkshu
git clone https://github.com/TekMonksGitHub/llminfer
```

Directory layout must be:
```
<parent>/
├── monkshu/
└── llminfer/
```

### 2. Link llminfer into Monkshu (one-time setup)

```bash
cd monkshu
./mklink.sh llminfer
```

This symlinks `llminfer/backend/apps` and `llminfer/frontend/apps` into Monkshu so the server discovers the app automatically at startup. No changes to Monkshu's config files are needed.

### 3. Run llminfer

```bash
cd llminfer
./llminfer.sh <model_name> [options]
```

The script handles everything: Python venv setup, model download, config generation, and server launch.

---

## Usage

```
./llminfer.sh <model_name> [--port PORT] [--host HOST] [--ssl]
                           [--inference-port PORT] [--backend BACKEND]
                           [--device DEVICE] [--hf-token TOKEN] [--ollama]
```

| Flag | Default | Description |
|---|---|---|
| `<model_name>` | required | Hugging Face model name (e.g. `google/gemma-3-4b-it`) |
| `--backend` | `vllm` | Inference backend (currently: `vllm`) |
| `--port` | `8081` | Monkshu API server port |
| `--host` | `0.0.0.0` | Monkshu API server host |
| `--inference-port` | `8080` | vLLM inference engine port |
| `--device` | `cpu` | Device for inference (`cpu`, `cuda`, etc.) |
| `--ssl` | off | Enable SSL on the Monkshu server |
| `--hf-token` | — | Hugging Face access token (or set `HF_TOKEN` env var) |

### Examples

```bash
# Public HF model
./llminfer.sh google/gemma-3-4b-it

# Gated model (requires HF token)
./llminfer.sh google/gemma-3-4b-it --hf-token hf_xxxx

# Custom ports
./llminfer.sh google/gemma-3-4b-it --port 9000 --inference-port 9001

# Tip: set HF_TOKEN in your environment to avoid passing it each time
export HF_TOKEN=hf_xxxx
./llminfer.sh google/gemma-3-4b-it
```

---

## API Endpoints

Once running, Monkshu serves two endpoints (default port `8081`):

| Endpoint | Type | Description |
|---|---|---|
| `POST /apps/llminfer/infer` | JSON | Single-shot inference, returns full response |
| `POST /apps/llminfer/sseinfer` | SSE (streaming) | Streaming inference via Server-Sent Events |

**JSON request body:**
```json
{
    "prompt": "Explain transformers in one paragraph",
    "stream": false
}
```

**JSON response:**
```json
{
    "result": "..."
}
```

**SSE:** Set `"stream": true` or use the `/sseinfer` endpoint. Monkshu handles the SSE transport automatically — no code change needed.

---

## CLI Debug Mode

To test inference directly from the command line (without the HTTP server):

```bash
# First run llminfer.sh once to set up the venv and download the model.
# Then:
node main.js "Explain transformers in one paragraph"
```

This runs the inference engine in-process and prints the response. Useful for debugging model issues without HTTP overhead.

---

## Repository Layout

```
llminfer/
├── llminfer.sh                            # Entry point — venv, model download, config, launch
├── main.js                                # CLI debug tool (not in production path)
├── models/                                # Downloaded HF models (gitignored)
│   └── <model-slug>/                      # e.g. google--gemma-3-4b-it/
├── backend/
│   └── apps/
│       └── llminfer/
│           ├── conf/
│           │   ├── apiregistry.json       # Monkshu route registry
│           │   └── runner.json            # Runtime config (written by llminfer.sh)
│           ├── apis/
│           │   └── llminfer.js            # Monkshu API handler (JSON + SSE)
│           └── lib/
│               ├── app.js                 # Monkshu init hooks (preinitSync + initSync)
│               ├── llminferconstants.js   # Path constants
│               ├── inferenceengine.js     # Backend factory + abstraction
│               └── engines/
│                   ├── base.js            # Abstract engine interface
│                   └── vllm.js            # vLLM engine
├── frontend/
│   └── apps/
│       └── llminfer/
│           └── conf/
│               └── httpd.json
└── python/
    ├── python.sh                          # Python venv bootstrap + runner
    └── vllm_runner.py                     # Starts vLLM OpenAI-compatible server
```

---

## Adding a New Inference Backend

1. Create `backend/apps/llminfer/lib/engines/<newengine>.js` implementing `{ init, infer, shutdown, name }`
2. Register it in `inferenceengine.js`: `newengine: require("./engines/newengine")`
3. Add its Python deps to `python/python.sh` if needed
4. Pass `--backend newengine` to `llminfer.sh`

No changes to `llminfer.sh`, `main.js`, the API class, or Monkshu config.

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Monkshu as API server | 100% TekMonks stack — no Express, no Flask, no third-party server runtime |
| `runner.json` written by `llminfer.sh` | Single config authority; loaded by Monkshu's `preinitSync` before any request |
| `global.LLMINFER_CONSTANTS` | Same pattern as Neuranet — no relative path chains anywhere in the app |
| vLLM starts inside Monkshu's `initSync` | Monkshu is already serving when vLLM warms up; first request queues on `vllmReady` |
| SSE + JSON from one handler | Monkshu's API registry `sse=true` flag switches transport — zero extra code |
| `models/` inside llminfer root | Self-contained; gitignored; `MODELS_DIR` constant always resolves correctly |

---

(C) 2025 TekMonks. All rights reserved.
