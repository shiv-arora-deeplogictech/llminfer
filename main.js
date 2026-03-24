/**
 * LLMinfer CLI debug entry point.
 * Use this to test inference directly from the command line without HTTP.
 * Production startup path: llminfer.sh -> node monkshu/backend/server/server.js
 *
 * Usage: node main.js "Your prompt here"
 * (C) 2025 TekMonks. All rights reserved.
 */

const path = require("path");

async function main() {
    // Manually bootstrap LLMINFER_CONSTANTS - Monkshu is not running here.
    const approot = path.resolve(`${__dirname}/backend/apps/llminfer`);
    const appInit = require(`${approot}/lib/app.js`);

    // Provide a minimal LOG shim for CLI use.
    if (!global.LOG) global.LOG = { info: console.log, error: console.error, warn: console.warn };

    appInit.preinitSync("llminfer", approot);

    const inferenceengine = require(`${LLMINFER_CONSTANTS.LIBDIR}/inferenceengine.js`);
    await inferenceengine.init(LLMINFER_CONSTANTS);

    const prompt = process.argv[2] || "Hello!";
    console.log(`Prompt: ${prompt}`);

    const result = await inferenceengine.infer(prompt, {});
    console.log(`Response: ${result}`);

    await inferenceengine.shutdown();
    process.exit(0);
}

main().catch(err => { console.error(err); process.exit(1); });
