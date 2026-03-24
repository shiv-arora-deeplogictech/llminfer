# This script will init a Python environment with packages needed
# to run the LLMinfer vLLM inference server.
#
# If the environment exists (already initialized), then it will activate
# it and run the given Python script within it.
# (C) 2025 TekMonks. All rights reserved.

#!/usr/bin/env bash
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, resolve it relative to the symlink location
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
PYTHON3=$( which python3 )

function init_python_env() {
  $PYTHON3 -m venv "$SCRIPT_DIR/llminferpy"
  source "$SCRIPT_DIR/llminferpy/bin/activate"
  # Install CPU build of vLLM — the standard 'pip install vllm' is CUDA-only
  # and crashes at startup when no GPU is present. The CPU build is identified
  # by having "cpu" in its version string, which enables the CPU platform plugin.
  pip install vllm --extra-index-url https://download.pytorch.org/whl/cpu
  pip install huggingface_hub
  pip install transformers
  pip install accelerate
}

if [ -d "$SCRIPT_DIR/llminferpy" ]; then
  source "$SCRIPT_DIR/llminferpy/bin/activate"
else
  init_python_env
fi

PYTHON3="$SCRIPT_DIR/llminferpy/bin/python3" # run the version of python inside the virtual environment
"$PYTHON3" "$@"
