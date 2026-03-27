#!/usr/bin/env bash
# LLMinfer entry point. Sets up the Python venv, downloads the HF model,
# writes runner.json with the resolved configuration, and launches Monkshu.
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
INFERENCE_PORT=""
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

if [ -z "$INFERENCE_PORT" ]; then
    INFERENCE_PORT=8080
fi

if [ -z "$MODEL_NAME" ]; then
    echo "Usage: llminfer.sh --model MODEL [--port PORT] [--host HOST] [--ssl]"
    echo "                   [--inference-port PORT] [--backend BACKEND] [--hf-token TOKEN]"
    echo "                   [--quantization QUANT]"
    echo ""
    echo "Examples:"
    echo "  llminfer.sh --model google/gemma-3-4b-it"
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
TARGET_DIR="$MODELS_DIR/$MODEL_SLUG"
GGUF_FILE=""

echo "LLMinfer: model=$MODEL_NAME backend=$BACKEND inference=$INFERENCE_HOST:$INFERENCE_PORT${QUANTIZATION:+ quantization=$QUANTIZATION}"

# Step 1 - Bootstrap Python venv (idempotent)
echo "LLMinfer: Initializing Python environment..."
bash "$PYTHON_SH" -c "print('Python environment ready.')"

HF_CLI="$SCRIPT_DIR/python/llminferpy/bin/hf"

# Step 2 - Download model (idempotent)
_model_ready() {
    if [ "$BACKEND" = "llamacpp" ]; then
        find "$TARGET_DIR" -maxdepth 3 -iname "*${QUANTIZATION}*.gguf" 2>/dev/null | grep -q .
    else
        [ -f "$TARGET_DIR/config.json" ] || [ -f "$TARGET_DIR/params.json" ]
    fi
}

# GGUF_REMOTE_FILE is resolved by _resolve_remote_gguf for llamacpp downloads
GGUF_REMOTE_FILE=""

# List repo files and find the GGUF matching the requested quantization.
# Sets GGUF_REMOTE_FILE on success. Returns 1 if not found, 2 on auth/other error.
_resolve_remote_gguf() {
    local _tok="$1"
    local _tok_arg=""
    [ -n "$_tok" ] && _tok_arg="--token $_tok"

    echo "LLMinfer: Listing $MODEL_NAME repo files..."
    local _out _rc
    _out=$("$HF_CLI" repo-files "$MODEL_NAME" $_tok_arg 2>&1)
    _rc=$?
    if [ $_rc -ne 0 ]; then
        echo "$_out"
        return 2   # auth or network error
    fi

    GGUF_REMOTE_FILE=$(echo "$_out" | grep -i "\.gguf$" | grep -i "$QUANTIZATION" | head -1)
    if [ -z "$GGUF_REMOTE_FILE" ]; then
        echo "LLMinfer: No GGUF file matching '$QUANTIZATION' found in $MODEL_NAME"
        echo "LLMinfer: Available GGUF files:"
        echo "$_out" | grep -i "\.gguf$" || echo "  (none)"
        return 1   # quantization not found — fatal, no point retrying with a token
    fi
    echo "LLMinfer: Resolved remote file: $GGUF_REMOTE_FILE"
    return 0
}

_TMPOUT=$(mktemp)
trap 'rm -f "$_TMPOUT"' EXIT

_do_download() {
    local _tok="$1"
    local _tok_arg=""
    [ -n "$_tok" ] && _tok_arg="--token $_tok"

    mkdir -p "$TARGET_DIR"

    if [ "$BACKEND" = "llamacpp" ]; then
        # Normalize to lowercase — GGUF filenames are always lowercase
        local _quant_lower
        _quant_lower=$(echo "$QUANTIZATION" | tr '[:upper:]' '[:lower:]')
        "$HF_CLI" download "$MODEL_NAME" \
            --include "*${_quant_lower}*.gguf" \
            --local-dir "$TARGET_DIR" \
            $_tok_arg
    else
        "$HF_CLI" download "$MODEL_NAME" \
            --local-dir "$TARGET_DIR" \
            $_tok_arg
    fi
}

_try_download() {
    _do_download "$1" > "$_TMPOUT" 2>&1
    local _rc=$?
    cat "$_TMPOUT"
    return $_rc
}

if _model_ready; then
    echo "LLMinfer: Model already present at $TARGET_DIR"
else
    echo "LLMinfer: Downloading $MODEL_NAME..."

    if [ -n "$HF_TOKEN" ]; then
        _try_download "$HF_TOKEN"
    else
        _try_download ""
    fi

    if ! _model_ready; then
        if grep -qi "restricted\|gated\|authorized list\|access.*restricted" "$_TMPOUT"; then
            echo ""
            echo "LLMinfer: '$MODEL_NAME' is a gated model — you must accept the license first."
            echo "LLMinfer: Visit https://huggingface.co/$MODEL_NAME and click 'Agree and access'."
            [ -n "$HF_TOKEN" ] && echo "LLMinfer: Your token is valid; re-run after accepting the license."
            exit 1
        fi

        echo ""
        echo "LLMinfer: '$MODEL_NAME' requires a Hugging Face access token."
        echo "LLMinfer: Create one at https://huggingface.co/settings/tokens"
        echo ""
        read -rp "Enter your Hugging Face token (or press Enter to abort): " USER_TOKEN
        if [ -z "$USER_TOKEN" ]; then
            echo "LLMinfer: No token provided. Aborting."
            exit 1
        fi
        HF_TOKEN="$USER_TOKEN"

        # Re-resolve GGUF filename with the new token if we didn't get it earlier
        if [ "$BACKEND" = "llamacpp" ] && [ -z "$GGUF_REMOTE_FILE" ]; then
            _resolve_remote_gguf "$HF_TOKEN" || exit 1
        fi

        _try_download "$HF_TOKEN"

        if ! _model_ready; then
            if grep -qi "restricted\|gated\|authorized list\|access.*restricted" "$_TMPOUT"; then
                echo "LLMinfer: Token is valid but access to '$MODEL_NAME' is restricted."
                echo "LLMinfer: Accept the license at https://huggingface.co/$MODEL_NAME then retry."
            else
                echo "LLMinfer: Download failed. Check your token and model name, then retry."
            fi
            exit 1
        fi
    fi
fi

# Resolve the exact local GGUF filename for llamacpp
if [ "$BACKEND" = "llamacpp" ]; then
    GGUF_FILE=$(find "$TARGET_DIR" -maxdepth 3 -iname "*${QUANTIZATION}*.gguf" 2>/dev/null | head -1 | xargs -I{} basename {})
    if [ -z "$GGUF_FILE" ]; then
        echo "LLMinfer: No GGUF file matching '$QUANTIZATION' found in $TARGET_DIR"
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
