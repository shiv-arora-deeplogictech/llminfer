/**
 * LLMinfer CLI debug entry point.
 * Starts the inference engine and sends a test prompt via the same HTTP path
 * that the production REST proxy uses (/v1/chat/completions on the engine port).
 * Production startup path: llminfer.sh -> node monkshu/backend/server/server.js
 *
 * Usage: node main.js "Your prompt here"
 * (C) 2025 TekMonks. All rights reserved.
 */

const http = require("http");
const path = require("path");

async function main() {
    // Manually bootstrap LLMINFER_CONSTANTS — Monkshu is not running here.
    const approot = path.resolve(`${__dirname}/backend/apps/llminfer`);
    const appInit = require(`${approot}/lib/app.js`);

    // Provide a minimal LOG shim for CLI use.
    if (!global.LOG) global.LOG = { info: console.log, error: console.error, warn: console.warn };

    appInit.preinitSync("llminfer", approot);

    const inferenceengine = require(`${LLMINFER_CONSTANTS.LIBDIR}/inferenceengine.js`);
    await inferenceengine.init(LLMINFER_CONSTANTS);

    const prompt = process.argv[2] || "Hello!";
    console.log(`Prompt: ${prompt}`);

    // Mirror the REST proxy: POST directly to the engine's OpenAI-compatible endpoint.
    const host = (!LLMINFER_CONSTANTS.inference_host || LLMINFER_CONSTANTS.inference_host === "0.0.0.0")
        ? "127.0.0.1" : LLMINFER_CONSTANTS.inference_host;
    const port = LLMINFER_CONSTANTS.inference_port;

    const payload = JSON.stringify({
        model:       LLMINFER_CONSTANTS.MODEL_PATH,
        messages:    [{ role: "user", content: prompt }],
        max_tokens:  512,
        temperature: 0.7
    });

    const result = await new Promise((resolve, reject) => {
        const req = http.request({
            hostname: host, port,
            path: "/v1/chat/completions",
            method: "POST",
            headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }
        }, res => {
            let data = "";
            res.on("data", chunk => data += chunk);
            res.on("end", () => {
                try { resolve(JSON.parse(data)?.choices?.[0]?.message?.content || ""); }
                catch (e) { reject(e); }
            });
        });
        req.on("error", reject);
        req.write(payload);
        req.end();
    });

    console.log(`Response: ${result}`);

    await inferenceengine.shutdown();
    process.exit(0);
}

main().catch(err => { console.error(err); process.exit(1); });
