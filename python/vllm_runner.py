# Starts the vLLM OpenAI-compatible inference server.
# Handles all vLLM-specific setup: LD_PRELOAD, env vars.
# Called via: python.sh vllm_runner.py <model_path> [host] [port] [device]
# (C) 2025 TekMonks. All rights reserved.

import subprocess
import sys
import os

def run(model_path, host="0.0.0.0", port=8080, device="cuda"):
    env = os.environ.copy()
    env["TRANSFORMERS_OFFLINE"]  = "1"
    env["HF_DATASETS_OFFLINE"]   = "1"

    server_args = [
        "--model",               model_path,
        "--host",                host,
        "--port",                str(port),
        "--enforce-eager",
        "--trust-remote-code",
        "--no-enable-log-requests"
    ]

    cmd = [sys.executable, "-m", "vllm.entrypoints.openai.api_server"] + server_args

    proc = subprocess.Popen(cmd, env=env)
    proc.wait()

if __name__ == "__main__":
    model_path = sys.argv[1]
    host       = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
    port       = int(sys.argv[3]) if len(sys.argv) > 3 else 8080
    device     = sys.argv[4] if len(sys.argv) > 4 else "cuda"
    run(model_path, host, port, device)
