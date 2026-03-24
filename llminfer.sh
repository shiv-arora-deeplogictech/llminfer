#!/usr/bin/env bash
# LLMinfer entry point. Sets up the Python venv, downloads the HF model,
# patches runner.json with the resolved configuration, and launches Monkshu.
# Usage: llminfer.sh --model MODEL [--port PORT] [--host HOST] [--ssl]
#                    [--inference-port PORT] [--backend BACKEND] [--hf-token TOKEN]
#                    [--quantization QUANT]   (required for --backend llamacpp)
# (C) 2025 TekMonks. All rights reserved.

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

PYTHON_SH="$SCRIPT_DIR/python/python.sh"
MODELS_DIR="$SCRIPT_DIR/models"
MONKSHU_DIR="$(dirname "$SCRIPT_DIR")/monkshu"
RUNNER_JSON="$SCRIPT_DIR/backend/apps/llminfer/conf/runner.json"

# Defaults
MODEL_NAME=""
QUANTIZATION=""
INFERENCE_PORT=""           # set per-backend below if not overridden
INFERENCE_HOST="0.0.0.0"
BACKEND="vllm"
SSL=false
HF_TOKEN="${HF_TOKEN:-}"   # fall back to environment variable if set

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)            MODEL_NAME="$2";     shift 2 ;;
        --port)             INFERENCE_PORT="$2"; shift 2 ;;
        --host)             INFERENCE_HOST="$2"; shift 2 ;;
        --inference-port)   INFERENCE_PORT="$2"; shift 2 ;;
        --backend)          BACKEND="$2";        shift 2 ;;
        --quantization)     QUANTIZATION="$2";   shift 2 ;;
        --ssl)              SSL=true;            shift ;;
        --hf-token)         HF_TOKEN="$2";       shift 2 ;;
        *)                  shift ;;
    esac
done

# Set default inference port if not explicitly provided
if [ -z "$INFERENCE_PORT" ]; then
    INFERENCE_PORT=8080
fi

if [ -z "$MODEL_NAME" ]; then
    echo "Usage: llminfer.sh --model MODEL [--port PORT] [--host HOST] [--ssl]"
    echo "                   [--inference-port PORT] [--backend BACKEND] [--hf-token TOKEN]"
    echo "                   [--quantization QUANT]"
    echo ""
    echo "Examples:"
    echo "  llminfer.sh --model google/gemma-3-4b-it --hf-token hf_xxxx"
    echo "  llminfer.sh --model Qwen/Qwen2.5-0.5B-Instruct-GGUF --backend llamacpp --quantization Q5_K_M"
    echo ""
    echo "Tip: set HF_TOKEN in your environment to avoid passing it each time."
    exit 1
fi

if [ "$BACKEND" = "llamacpp" ] && [ -z "$QUANTIZATION" ]; then
    echo "LLMinfer: --quantization is required for --backend llamacpp"
    echo "LLMinfer: Example: --quantization Q5_K_M"
    exit 1
fi

MODEL_SLUG=$(echo "$MODEL_NAME" | tr '/' '--' | tr ':' '-')
QUANT_LOWER=$(echo "$QUANTIZATION" | tr '[:upper:]' '[:lower:]')
QUANT_UPPER=$(echo "$QUANTIZATION" | tr '[:lower:]' '[:upper:]')
GGUF_FILE=""

echo "LLMinfer: model=$MODEL_NAME backend=$BACKEND inference=$INFERENCE_HOST:$INFERENCE_PORT${QUANTIZATION:+ quantization=$QUANTIZATION}"

export LLMINFER_BACKEND="$BACKEND"

# Step 1 - Bootstrap Python venv (idempotent)
echo "LLMinfer: Initializing Python environment..."
bash "$PYTHON_SH" -c "print('Python environment ready.')"

    # Step 2 - Download model into models/ (idempotent)
    export HF_HOME="$MODELS_DIR"
    # For llamacpp: ready when a matching GGUF file is present.
    # For vllm: ready when a config file is present.
    _model_ready() {
        if [ "$BACKEND" = "llamacpp" ]; then
            find "$MODELS_DIR/$MODEL_SLUG" -maxdepth 3 \( -iname "*${QUANT_LOWER}*.gguf" -o -iname "*${QUANT_UPPER}*.gguf" \) 2>/dev/null | grep -q .
        else
            [ -f "$MODELS_DIR/$MODEL_SLUG/config.json" ] || [ -f "$MODELS_DIR/$MODEL_SLUG/params.json" ]
        fi
    }

    if _model_ready; then
        echo "LLMinfer: Model already present at $MODELS_DIR/$MODEL_SLUG"
    else
        echo "LLMinfer: Downloading $MODEL_NAME..."

        _do_download() {
            local _hf_tok="$1"
            if [ "$BACKEND" = "llamacpp" ]; then
                # Download only the GGUF file matching the requested quantization.
                if [ -n "$_hf_tok" ]; then
                    bash "$PYTHON_SH" -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='$MODEL_NAME', local_dir='$MODELS_DIR/$MODEL_SLUG',
    allow_patterns=['*${QUANT_LOWER}*.gguf', '*${QUANT_UPPER}*.gguf'], token='$_hf_tok')
print('Model download complete.')
"
                else
                    bash "$PYTHON_SH" -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='$MODEL_NAME', local_dir='$MODELS_DIR/$MODEL_SLUG',
    allow_patterns=['*${QUANT_LOWER}*.gguf', '*${QUANT_UPPER}*.gguf'])
print('Model download complete.')
"
                fi
            else
                if [ -n "$_hf_tok" ]; then
                    bash "$PYTHON_SH" -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='$MODEL_NAME', local_dir='$MODELS_DIR/$MODEL_SLUG', token='$_hf_tok')
print('Model download complete.')
"
                else
                    bash "$PYTHON_SH" -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='$MODEL_NAME', local_dir='$MODELS_DIR/$MODEL_SLUG')
print('Model download complete.')
"
                fi
            fi
        }

        # Capture download output so we can detect gated-access vs auth errors.
        _download_output=""
        _try_download() {
            _download_output=$(_do_download "$1" 2>&1)
            local rc=$?
            echo "$_download_output"
            return $rc
        }

        if [ -n "$HF_TOKEN" ]; then
            # Token already provided via --hf-token or env var — use it directly.
            _try_download "$HF_TOKEN"
        else
            # Try without a token first (works for public models).
            _try_download "" 2>/dev/null
        fi

        if ! _model_ready; then
            # Check if this is a gated-access issue (token is valid but license not accepted).
            if echo "$_download_output" | grep -qi "restricted\|gated\|authorized list\|access.*restricted"; then
                echo ""
                echo "LLMinfer: The model '$MODEL_NAME' is a gated model."
                echo "LLMinfer: You must accept the license agreement before downloading."
                echo "LLMinfer: Visit: https://huggingface.co/$MODEL_NAME and click 'Agree and access'."
                echo ""
                if [ -n "$HF_TOKEN" ]; then
                    echo "LLMinfer: Your token is valid, but you haven't been granted access yet."
                    echo "LLMinfer: After accepting the license, re-run this script."
                else
                    echo "LLMinfer: After accepting the license, re-run with your token:"
                    echo "LLMinfer:   ./llminfer.sh --model $MODEL_NAME --hf-token <your_token>"
                fi
                exit 1
            fi

            # No gated-access error — likely just needs a token (private/gated model).
            echo ""
            echo "LLMinfer: The model '$MODEL_NAME' appears to require authentication."
            echo "LLMinfer: You need a Hugging Face access token to download this model."
            echo "LLMinfer: (Create one at https://huggingface.co/settings/tokens)"
            echo ""
            echo "LLMinfer: Note - If this is a gated model, you must also accept the license at:"
            echo "LLMinfer:   https://huggingface.co/$MODEL_NAME"
            echo ""
            read -rp "Enter your Hugging Face token (or press Enter to abort): " USER_TOKEN
            if [ -z "$USER_TOKEN" ]; then
                echo "LLMinfer: No token provided. Aborting."
                exit 1
            fi
            HF_TOKEN="$USER_TOKEN"
            _try_download "$HF_TOKEN"
            if ! _model_ready; then
                if echo "$_download_output" | grep -qi "restricted\|gated\|authorized list\|access.*restricted"; then
                    echo ""
                    echo "LLMinfer: Your token is valid, but access to '$MODEL_NAME' is restricted."
                    echo "LLMinfer: Visit https://huggingface.co/$MODEL_NAME and accept the license agreement."
                    echo "LLMinfer: After approval, re-run this script."
                else
                    echo "LLMinfer: Model download failed. Check your token and model name, then retry."
                fi
                exit 1
            fi
        fi
    fi

# Resolve the exact GGUF filename for llamacpp (after download or if already present)
if [ "$BACKEND" = "llamacpp" ]; then
    GGUF_FILE=$(find "$MODELS_DIR/$MODEL_SLUG" -maxdepth 3 \( -iname "*${QUANT_LOWER}*.gguf" -o -iname "*${QUANT_UPPER}*.gguf" \) 2>/dev/null | head -1 | xargs -I{} basename {})
    if [ -z "$GGUF_FILE" ]; then
        echo "LLMinfer: Error: No GGUF file matching '$QUANTIZATION' found in $MODELS_DIR/$MODEL_SLUG"
        exit 1
    fi
    echo "LLMinfer: Using GGUF file: $GGUF_FILE"
fi

# Step 3 - Write runner.json with all resolved configuration
echo "LLMinfer: Writing runner.json..."
node -e "
const fs = require('fs');
const conf = {
    model:            '$MODEL_NAME',
    model_slug:       '$MODEL_SLUG',
    backend:          '$BACKEND',
    inference_host:   '$INFERENCE_HOST',
    inference_port:   $INFERENCE_PORT,
    ssl:              $SSL,
    disable_thinking: true,
    hf_offline:       true
};
if ('$GGUF_FILE') conf.gguf_file = '$GGUF_FILE';
fs.writeFileSync('$RUNNER_JSON', JSON.stringify(conf, null, 4));
console.log('LLMinfer: runner.json updated.');
"

# Step 4 - Launch Monkshu (engine starts inside Monkshu's app initSync)
echo "LLMinfer: Starting Monkshu server..."
node "$MONKSHU_DIR/backend/server/server.js"
