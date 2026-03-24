/**
 * llama.cpp inference engine for LLMinfer.
 * Spawns a llama-cpp-python OpenAI-compatible server via python.sh and proxies requests to it.
 * Requires a GGUF-format model file in MODEL_PATH.
 * (C) 2025 TekMonks. All rights reserved.
 */

const http = require("http");
const { execFile } = require("child_process");
const fs = require("fs");
const path = require("path");

const HEALTH_RETRIES = 60, HEALTH_INTERVAL_MS = 2000;

let _config, _proc;

/**
 * Starts the llama-cpp-python server and returns a Promise that resolves when it is healthy.
 * @param {Object} config Full LLMINFER_CONSTANTS object.
 * @returns {Promise<void>}
 */
function init(config) {
    _config = config;

    const pythonSh = `${LLMINFER_CONSTANTS.PYTHONDIR}/python.sh`;
    const ggufFile = config.gguf_file
        ? path.join(config.MODEL_PATH, config.gguf_file)
        : _findGgufFile(config.MODEL_PATH);

    _proc = execFile("bash", [
        pythonSh, "-m", "llama_cpp.server",
        "--model", ggufFile,
        "--host", config.inference_host,
        "--port", String(config.inference_port),
        "--n_ctx", "4096"
    ]);

    _proc.stderr.on("data", d => LOG.info(`llamacpp: ${d.toString().trim()}`));
    _proc.stdout.on("data", d => LOG.info(`llamacpp: ${d.toString().trim()}`));
    _proc.on("exit", code => { if (code !== null) LOG.error(`LLMinfer: llama.cpp process exited with code ${code}`); });

    return _waitForHealth(config.inference_host, config.inference_port);
}

/**
 * Runs inference against the llama-cpp-python OpenAI-compatible endpoint.
 * @param {string} prompt The user prompt.
 * @param {Object} options { stream, max_tokens, temperature }
 * @returns {Promise<string|AsyncGenerator>}
 */
async function infer(prompt, options = {}) {
    const payload = JSON.stringify({
        model: LLMINFER_CONSTANTS.MODEL_PATH,
        messages: [{ role: "user", content: prompt }],
        stream: options.stream || false,
        max_tokens: options.max_tokens || 512,
        temperature: options.temperature || 0.7
    });

    if (options.stream) return _streamRequest(payload);
    return _jsonRequest(payload);
}

/**
 * Kills the llama.cpp child process.
 */
async function shutdown() {
    if (_proc) _proc.kill();
}

function _findGgufFile(modelPath) {
    const files = fs.readdirSync(modelPath);
    const gguf = files.find(f => f.toLowerCase().endsWith(".gguf"));
    if (!gguf) throw new Error(
        `LLMinfer: No .gguf file found in ${modelPath}. ` +
        `llama.cpp requires GGUF-format models. ` +
        `Try a repo ending in -GGUF (e.g. Qwen/Qwen2.5-0.5B-Instruct-GGUF).`
    );
    return path.join(modelPath, gguf);
}

function _waitForHealth(host, port) {
    return new Promise((resolve, reject) => {
        let attempts = 0;
        const check = () => {
            const req = http.get(`http://${host}:${port}/v1/models`, res => {
                if (res.statusCode === 200) { resolve(); return; }
                retry();
            });
            req.on("error", retry);
            req.end();
        };
        const retry = () => {
            attempts++;
            if (attempts >= HEALTH_RETRIES) { reject(new Error("LLMinfer: llama.cpp startup timed out (GET /v1/models never returned 200).")); return; }
            setTimeout(check, HEALTH_INTERVAL_MS);
        };
        check();
    });
}

function _jsonRequest(payload) {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: _config.inference_host === "0.0.0.0" ? "127.0.0.1" : _config.inference_host,
            port: _config.inference_port,
            path: "/v1/chat/completions",
            method: "POST",
            headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }
        };
        const req = http.request(options, res => {
            let data = "";
            res.on("data", chunk => data += chunk);
            res.on("end", () => {
                try {
                    const parsed = JSON.parse(data);
                    resolve(parsed.choices?.[0]?.message?.content || "");
                } catch (e) { reject(e); }
            });
        });
        req.on("error", reject);
        req.write(payload);
        req.end();
    });
}

async function* _streamRequest(payload) {
    // Yields text chunks as they arrive from the llama-cpp-python SSE stream.
    const chunks = await new Promise((resolve, reject) => {
        const options = {
            hostname: _config.inference_host === "0.0.0.0" ? "127.0.0.1" : _config.inference_host,
            port: _config.inference_port,
            path: "/v1/chat/completions",
            method: "POST",
            headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }
        };
        const collected = [];
        const req = http.request(options, res => {
            res.on("data", chunk => collected.push(chunk.toString()));
            res.on("end", () => resolve(collected));
        });
        req.on("error", reject);
        req.write(payload);
        req.end();
    });

    for (const raw of chunks) {
        for (const line of raw.split("\n")) {
            if (!line.startsWith("data: ") || line === "data: [DONE]") continue;
            try {
                const parsed = JSON.parse(line.slice(6));
                const text = parsed.choices?.[0]?.delta?.content;
                if (text) yield text;
            } catch (_e) { /* skip malformed lines */ }
        }
    }
}

module.exports = { init, infer, shutdown, name: "llamacpp" };
