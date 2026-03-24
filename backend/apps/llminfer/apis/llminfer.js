/**
 * Monkshu API class for LLMinfer inference.
 * Handles both JSON (/infer) and SSE streaming (/sseinfer) via the same handler.
 * The sse=true flag in apiregistry.json switches transport - no extra code needed here.
 * (C) 2025 TekMonks. All rights reserved.
 */

const inferenceengine = require(`${LLMINFER_CONSTANTS.LIBDIR}/inferenceengine.js`);

/**
 * API request:
 *   prompt - The user's prompt (required)
 *   stream - true for SSE streaming, false or omitted for JSON response
 *   max_tokens - optional, default 512
 *   temperature - optional, default 0.7
 *
 * API response (JSON):
 *   result - true or false
 *   response - the model's response text
 */
exports.doService = async function(jsonReq, _env, _headers, _servObj) {
    if (!validateRequest(jsonReq)) { LOG.error("LLMinfer: Validation failure - missing prompt."); return CONSTANTS.FALSE_RESULT; }

    await LLMINFER_CONSTANTS.engineReady;

    const options = {
        stream:      false,
        max_tokens:  jsonReq.max_tokens  || 512,
        temperature: jsonReq.temperature || 0.7
    };

    try {
        const response = await inferenceengine.infer(jsonReq.prompt, options);
        return { result: true, response };
    } catch (err) {
        LOG.error(`LLMinfer: Inference error: ${err.message || err}`);
        return { result: false, error: err.message || String(err) };
    }
}

const validateRequest = jsonReq => (jsonReq && jsonReq.prompt);
