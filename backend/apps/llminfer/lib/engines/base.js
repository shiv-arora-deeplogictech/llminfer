/**
 * Abstract base interface for all LLMinfer inference engines.
 * All engines must implement init, infer, and shutdown.
 * (C) 2025 TekMonks. All rights reserved.
 */

const BaseEngine = {
    // Initialize: start the inference server/process and wait until ready.
    // config: full LLMINFER_CONSTANTS object.
    // Returns: Promise that resolves when the engine is ready.
    init: async (_config) => { throw new Error("Not implemented"); },

    // Run inference.
    // prompt: string
    // options: { stream: bool, max_tokens: number, temperature: number }
    // Returns: string (non-stream) or async generator (stream)
    infer: async (_prompt, _options) => { throw new Error("Not implemented"); },

    // Graceful shutdown - kill the inference process.
    shutdown: async () => { throw new Error("Not implemented"); },

    name: "base"
};

module.exports = { BaseEngine };
