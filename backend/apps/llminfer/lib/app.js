/**
 * LLMinfer app init - called by Monkshu on server startup.
 * (C) 2025 TekMonks. All rights reserved.
 */

const path = require("path");

exports.preinitSync = function(_app, approot) {
    const LLMINFER_LIBDIR = `${approot}/lib`;
    global.LLMINFER_CONSTANTS = require(`${LLMINFER_LIBDIR}/llminferconstants.js`);

    const runnerConf = require(`${LLMINFER_CONSTANTS.CONFDIR}/runner.json`);
    Object.assign(global.LLMINFER_CONSTANTS, runnerConf);

    global.LLMINFER_CONSTANTS.MODEL_PATH = path.resolve(
        `${LLMINFER_CONSTANTS.MODELS_DIR}/${runnerConf.model_slug}`
    );
};

exports.initSync = function(_app, _approot) {
    const inferenceengine = require(`${LLMINFER_CONSTANTS.LIBDIR}/inferenceengine.js`);
    const backendName = LLMINFER_CONSTANTS.backend || "vllm";

    LLMINFER_CONSTANTS.engineReady = inferenceengine.init(LLMINFER_CONSTANTS);

    LLMINFER_CONSTANTS.engineReady
        .then(() => LOG.info(`LLMinfer: ${backendName} inference engine is ready.`))
        .catch(err => LOG.error(`LLMinfer: ${backendName} failed to start: ${err}`));
};
