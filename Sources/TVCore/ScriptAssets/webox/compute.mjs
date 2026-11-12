// WeBox `ctx.compute.run` — the one capability QuickJS cannot offer: WebAssembly.
//
// A plugin hands over a function's source, its input, and the binaries that function instantiates
// (4k影视 builds its play request with a wasm-bindgen module). This file runs that function in Node, whose
// WebAssembly is V8's, so the plugin's own code runs unchanged. Two callers share it: the Mac host runs it
// as a program (JSON on stdin, JSON on stdout), and the iOS host imports runCompute inside the embedded
// Node (Runtime/NodeHost/main.mjs), so there is one implementation.
import { pathToFileURL } from 'node:url';

/// The function source arrives as `kvmBuildRequest.toString()`, so it is an expression, not a module.
function build(code) {
    const factory = new Function('"use strict"; return (' + code + '\n);');
    const value = factory();
    if (typeof value !== 'function') throw new Error('计算入口不是函数');
    return value;
}

export async function runCompute(request) {
    const values = request.input == null ? {} : request.input;
    const binaries = {};
    for (const [name, value] of Object.entries(request.binaries || {})) {
        binaries[name] = Buffer.from(String(value == null ? '' : value), 'base64');
    }
    const limit = Number(request.timeoutMs) > 0 ? Number(request.timeoutMs) : 10000;
    let timer = null;
    const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('计算超时')), limit);
    });
    try {
        return await Promise.race([Promise.resolve(build(request.code)(values, binaries)), timeout]);
    } finally {
        if (timer) clearTimeout(timer);
    }
}

// Program mode: one request in, one answer out. Imported by the iOS host, this block stays asleep.
const invokedDirectly = () => {
    try { return import.meta.url === pathToFileURL(process.argv[1]).href; } catch { return false; }
};

if (invokedDirectly()) {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    let answer;
    try {
        const result = await runCompute(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        answer = { result: result === undefined ? null : result };
    } catch (error) {
        answer = { error: String((error && error.message) || error) };
    }
    process.stdout.write(JSON.stringify(answer));
}
