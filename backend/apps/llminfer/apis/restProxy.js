/**
 * LLMinfer REST proxy API.
 * Forwards incoming requests transparently to the local LLM engine
 * (llama.cpp or vllm) running at the host/port configured in runner.json.
 *
 * Supports https→http and http→http proxying (the Monkshu server can serve
 * HTTPS while the local LLM is always plain HTTP).
 *
 * The LLM path is derived from the incoming URL by stripping the
 * /apps/<appname> prefix. This means any endpoint registered under
 * /apps/llminfer/v1/... is transparently forwarded as /v1/... to the LLM,
 * so adding new endpoints (e.g. /v1/embeddings) requires only a new entry
 * in apiregistry.json pointing to this same file.
 *
 * runner.json fields used:
 *   inference_host  - LLM server host (0.0.0.0 is rewritten to 127.0.0.1)
 *   inference_port  - LLM server port
 *   ssl             - whether the LLM server itself uses HTTPS (usually false)
 *
 * (C) 2025 TekMonks. All rights reserved.
 */

const rest = require(`${CONSTANTS.LIBDIR}/rest.js`);

const APP_PATH_PREFIX = /^\/apps\/[^/]+/;   // strips /apps/<appname>

exports.doService = async (jsonReq, _servObject, headers, url) => {
    const rawHost = LLMINFER_CONSTANTS.inference_host;
    const host = (!rawHost || rawHost === "0.0.0.0") ? "127.0.0.1" : rawHost;
    const port = LLMINFER_CONSTANTS.inference_port;
    const incomingPath = new URL(url).pathname;
    const llmPath = incomingPath.replace(APP_PATH_PREFIX, "") || "/v1/chat/completions";

    const incomingMethod = ((_servObject.req && _servObject.req.method) || "POST").toLowerCase();
    if (incomingMethod !== "post") return { result: false, error: "Method not allowed", status: 405 };

    // Drop the host header so the LLM receives its own host, not the proxy's
    const forwardHeaders = { ...headers };
    delete forwardHeaders["host"];

    LOG.info(`LLMinfer RestProxy: POST → http://${host}:${port}${llmPath}`);

    const { error, data, status } = await rest.post(host, port, llmPath, forwardHeaders, jsonReq);

    if (error) {
        LOG.error(`LLMinfer RestProxy: LLM returned error (HTTP ${status}): ${error}`);
        return { result: false, error: String(error), status };
    }

    return data;
};
