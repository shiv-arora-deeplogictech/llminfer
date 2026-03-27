/**
 * vLLM inference engine for LLMinfer.
 * Spawns a vLLM OpenAI-compatible server via python.sh and proxies requests to it.
 * (C) 2025 TekMonks. All rights reserved.
 */

const http = require("http");
const { execFile } = require("child_process");

const HEALTH_RETRIES = 60, HEALTH_INTERVAL_MS = 2000;

let _config, _proc;

/**
 * Starts the vLLM server and returns a Promise that resolves when it is healthy.
 * @param {Object} config Full LLMINFER_CONSTANTS object.
 * @returns {Promise<void>}
 */
function init(config) {
    _config = config;

    const pythonSh   = `${LLMINFER_CONSTANTS.PYTHONDIR}/python.sh`;
    const vllmRunner = `${LLMINFER_CONSTANTS.PYTHONDIR}/vllm_runner.py`;

    _proc = execFile("bash", [
        pythonSh, vllmRunner,
        config.MODEL_PATH,
        config.inference_host,
        String(config.inference_port),
        config.device || "auto"
    ]);

    _proc.stderr.on("data", d => LOG.info(`vLLM: ${d.toString().trim()}`));
    _proc.stdout.on("data", d => LOG.info(`vLLM: ${d.toString().trim()}`));
    _proc.on("exit", code => { if (code !== null) LOG.error(`LLMinfer: vLLM process exited with code ${code}`); });

    return _waitForHealth(config.inference_host, config.inference_port);
}

// Fields from the Monkshu request envelope that must not be forwarded to the model.
const INTERNAL_KEYS = new Set(["prompt", "jobrequest", "jobresponse", "id", "message_id", "clientid"]);

/**
 * Runs inference against the vLLM OpenAI-compatible endpoint.
 * All OpenAI-compatible fields present in options (top_p, top_k, stop, seed, etc.)
 * are forwarded to the model. Internal Monkshu fields are stripped.
 * @param {string} prompt The user prompt (used only when options.messages is absent).
 * @param {Object} options Full request object forwarded from the API layer.
 * @returns {Promise<string|AsyncGenerator>}
 */
async function infer(prompt, options = {}) {
    const messages = options.messages || [{ role: "user", content: prompt }];
    const model    = options.model    || LLMINFER_CONSTANTS.MODEL_PATH;

    const payload = { model, messages };
    for (const [key, val] of Object.entries(options))
        if (!INTERNAL_KEYS.has(key) && key !== "messages" && key !== "model")
            payload[key] = val;

    if (payload.max_tokens  == null) payload.max_tokens  = 512;
    if (payload.temperature == null) payload.temperature = 0.7;
    if (payload.stream      == null) payload.stream      = false;

    const payloadStr = JSON.stringify(payload);

    if (payload.stream) return _streamRequest(payloadStr);
    return _jsonRequest(payloadStr);
}

/**
 * Kills the vLLM child process.
 */
async function shutdown() {
    if (_proc) _proc.kill();
}

function _waitForHealth(host, port) {
    return new Promise((resolve, reject) => {
        let attempts = 0;
        const check = () => {
            const req = http.get(`http://${host}:${port}/health`, res => {
                if (res.statusCode === 200) { resolve(); return; }
                retry();
            });
            req.on("error", retry);
            req.end();
        };
        const retry = () => {
            attempts++;
            if (attempts >= HEALTH_RETRIES) { reject(new Error("LLMinfer: vLLM health check timed out.")); return; }
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
    // Yields text chunks as they arrive from the vLLM SSE stream.
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

module.exports = { init, infer, shutdown, name: "vllm" };
