# Generic inference server launcher.
# Each backend has its own runner (e.g. vllm_runner.py) with backend-specific
# setup. This file is kept as a thin fallback / convenience entry point.
# Called via: python.sh llm_runner.py <backend> <model_path> [host] [port] [device]
# (C) 2025 TekMonks. All rights reserved.

import sys

RUNNERS = {
    "vllm": "vllm_runner",
}

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: llm_runner.py <backend> <model_path> [host] [port] [device]")
        sys.exit(1)

    backend    = sys.argv[1]
    model_path = sys.argv[2]
    host       = sys.argv[3] if len(sys.argv) > 3 else "0.0.0.0"
    port       = int(sys.argv[4]) if len(sys.argv) > 4 else 8080
    device     = sys.argv[5] if len(sys.argv) > 5 else "auto"

    if backend not in RUNNERS:
        print(f"Unknown backend: {backend}. Available: {', '.join(RUNNERS.keys())}")
        sys.exit(1)

    import importlib
    runner = importlib.import_module(RUNNERS[backend])
    runner.run(model_path, host, port, device)
