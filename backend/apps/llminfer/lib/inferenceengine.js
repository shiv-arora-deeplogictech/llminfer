/**
 * Inference engine factory and facade for LLMinfer.
 * This is the only module the rest of the app uses for inference.
 * Adding a new backend: create engines/<name>.js and add one line to ENGINES below.
 * (C) 2025 TekMonks. All rights reserved.
 */

const ENGINES = {
    vllm: require(`${__dirname}/engines/vllm.js`)
};

let _engine;

/**
 * Initializes the configured inference backend.
 * @param {Object} config Full LLMINFER_CONSTANTS object.
 * @returns {Promise<void>} Resolves when the engine is ready to serve requests.
 */
function init(config) {
    const backendName = config.backend || "vllm";
    if (!ENGINES[backendName]) throw new Error(`LLMinfer: Unknown backend: ${backendName}`);
    _engine = ENGINES[backendName];
    return _engine.init(config);
}

/**
 * Runs inference using the active backend.
 * @param {string} prompt The user prompt.
 * @param {Object} options { stream, max_tokens, temperature }
 * @returns {Promise<string|AsyncGenerator>}
 */
async function infer(prompt, options) {
    return _engine.infer(prompt, options);
}

/**
 * Shuts down the active inference backend.
 */
async function shutdown() {
    if (_engine) await _engine.shutdown();
}

module.exports = { init, infer, shutdown };
