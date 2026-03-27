# llminfer

**v0.2** — LLM Model Runtime for Private AI Models

LLMinfer is a 100% TekMonks-developed LLM inference runtime. It uses **Monkshu** as its API server and either **vLLM** or **llama.cpp** for model execution. The goal is to reduce any private AI deployment to: deploy Monkshu → clone llminfer → run it.

Supports:
- **vLLM** backend — any Hugging Face model (e.g. `google/gemma-3-4b-it`)
- **llama.cpp** backend — GGUF-format quantized models (e.g. `Qwen/Qwen2.5-0.5B-Instruct-GGUF`)
- **OpenAI-compatible REST proxy** — drop-in replacement for any client targeting `POST /v1/chat/completions`

---

## How It Works

```
llminfer.sh --model MODEL [opts]
    │
    ├── Bootstrap Python venv (python/python.sh)
    ├── Download HF model → models/<slug>/
    ├── Write backend/apps/llminfer/conf/runner.json  (resolved config)
    └── node monkshu/backend/server/server.js
            │
            ├── Monkshu starts, registers routes from apiregistry.json
            ├── app.js preinitSync → loads runner.json → sets global.LLMINFER_CONSTANTS
            └── app.js initSync   → spawns inference engine (vLLM or llama.cpp)
                    │
                    engine is healthy → all requests are proxied / served

```

`llminfer.sh` owns all configuration. It resolves the model, ports, and backend, then writes `runner.json` before handing off to Monkshu. The engine (vLLM or llama.cpp) starts inside Monkshu's `initSync` and exposes a local OpenAI-compatible HTTP server on the **inference port** (default `8080`). Incoming requests are forwarded through `restProxy.js` to the engine's `/v1/chat/completions` endpoint.

`main.js` is a **CLI debug tool only** — it starts the engine directly and sends a test prompt via HTTP to the engine's OpenAI endpoint, exercising the same code path as the production REST proxy.

---

## Setup

### Prerequisites

- **Node.js** (v18+)
- **Python 3.9+**
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

This symlinks `llminfer/backend/apps` and `llminfer/frontend/apps` into Monkshu so the server discovers the app automatically at startup.

### 3. Run llminfer

```bash
cd llminfer
./llminfer.sh --model <model_name> [options]
```

The script handles everything: Python venv setup, model download, config generation, and server launch.

---

## Usage

```
./llminfer.sh --model MODEL [--port PORT] [--host HOST] [--ssl]
              [--inference-port PORT] [--backend BACKEND]
              [--quantization QUANT] [--hf-token TOKEN]
```

| Flag | Default | Description |
|---|---|---|
| `--model` | required | Hugging Face model name |
| `--backend` | `vllm` | Inference backend: `vllm` or `llamacpp` |
| `--port` / `--inference-port` | `8080` | Port the LLM engine listens on (both flags are equivalent) |
| `--host` | `0.0.0.0` | Host the LLM engine binds to |
| `--quantization` | — | GGUF quantization level, required for `llamacpp` (e.g. `Q5_K_M`) |
| `--ssl` | off | Enable SSL on the Monkshu server |
| `--hf-token` | — | Hugging Face access token (or set `HF_TOKEN` env var) |

**Ports summary:**
- **Inference engine** — `8080` (set via `--inference-port`; internal, not exposed directly)
- **Monkshu API server** — `9095` (configured in `httpd.json`; this is what clients call)

### Examples

```bash
# vLLM — public model
./llminfer.sh --model google/gemma-3-4b-it

# vLLM — gated model
./llminfer.sh --model google/gemma-3-4b-it --hf-token hf_xxxx

# llama.cpp — GGUF quantized model
./llminfer.sh --model Qwen/Qwen2.5-0.5B-Instruct-GGUF --backend llamacpp --quantization Q5_K_M

# Custom inference port
./llminfer.sh --model google/gemma-3-4b-it --inference-port 9001

# Tip: set HF_TOKEN in your environment to avoid passing it each time
export HF_TOKEN=hf_xxxx
./llminfer.sh --model google/gemma-3-4b-it
```

---

## API

All endpoints are available on the Monkshu server (default port `9095`).

### OpenAI-compatible REST Proxy

Registered in `apiregistry.json`:
```json
{
    "/apps/llminfer/v1/chat/completions": "/apis/restProxy.js"
}
```

```
POST /apps/llminfer/v1/chat/completions
```

The request body is forwarded unchanged to the local LLM engine. Any OpenAI-compatible client works without modification.

**Example:**
```bash
curl -X POST https://localhost:9095/apps/llminfer/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

**Adding more endpoints** (e.g. `/v1/embeddings`, `/v1/completions`) requires only a new line in `apiregistry.json` pointing to the same `restProxy.js`:
```json
{
    "/apps/llminfer/v1/chat/completions": "/apis/restProxy.js",
    "/apps/llminfer/v1/embeddings":       "/apis/restProxy.js"
}
```

The proxy derives the LLM path from the URL by stripping the `/apps/llminfer` prefix.

---

## HTTPS → HTTP proxying

The Monkshu server (`httpd.json`) is configured with SSL on port `9095`. The local LLM engine always runs as plain HTTP on the inference port. `restProxy.js` handles this transparently — no additional configuration needed.

---

## CLI Debug Mode

`main.js` starts the inference engine directly (no Monkshu), then sends a test prompt via HTTP POST to the engine's `/v1/chat/completions` endpoint — the same path used by the production REST proxy.

```bash
# Run llminfer.sh once first to set up the venv and download the model, then:
node main.js "Explain transformers in one paragraph"
```

The engine must not already be running on the configured inference port when you invoke `main.js`.

---

## Repository Layout

```
llminfer/
├── llminfer.sh                            # Entry point — venv, download, config, launch
├── main.js                                # CLI debug tool (not in production path)
├── models/                                # Downloaded HF models (gitignored)
│   └── <model-slug>/
├── backend/
│   └── apps/
│       └── llminfer/
│           ├── conf/
│           │   ├── apiregistry.json       # Route registry
│           │   ├── httpd.json             # Monkshu HTTP server config (port 9095, SSL)
│           │   └── runner.json            # Runtime config (written by llminfer.sh)
│           ├── apis/
│           │   └── restProxy.js           # OpenAI-compatible transparent REST proxy
│           └── lib/
│               ├── app.js                 # Monkshu init hooks (preinitSync + initSync)
│               ├── llminferconstants.js   # Path constants
│               ├── inferenceengine.js     # Backend factory
│               └── engines/
│                   ├── vllm.js            # vLLM engine
│                   └── llamacpp.js        # llama.cpp engine
├── frontend/
│   └── apps/llminfer/conf/httpd.json
└── python/
    ├── python.sh                          # Python venv bootstrap
    └── vllm_runner.py                     # Starts vLLM OpenAI-compatible server
```

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Monkshu as API server | 100% TekMonks stack — no Express, no Flask, no third-party server runtime |
| `runner.json` written by `llminfer.sh` | Single config authority; loaded by Monkshu's `preinitSync` before any request |
| `global.LLMINFER_CONSTANTS` | No relative path chains anywhere in the app |
| Engine starts inside Monkshu's `initSync` | Monkshu is serving when the engine warms up; `engineReady` promise gates the first proxy call |
| REST proxy as API layer | `restProxy.js` forwards all `/v1/...` requests to the engine; adding endpoints is a one-liner in `apiregistry.json` |
| Path-derived LLM routing in proxy | Stripping `/apps/llminfer` from the URL makes every new endpoint a one-liner in `apiregistry.json` |
| `models/` inside llminfer root | Self-contained; gitignored; `MODELS_DIR` always resolves correctly |

---

(C) 2025 TekMonks. All rights reserved.
