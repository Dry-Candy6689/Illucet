// Illucet's on-device adapter. BgUtils itself retains its MIT license.
import { BotGuardClient, getChallenge } from './upstream/dist/exports/botguard.js';
import { WebPoMinter } from './upstream/dist/exports/webpo.js';
import { buildURL, getHeaders } from './upstream/dist/exports/utils.js';

let initialized;
let stage = 'setup';
const requestKey = 'O43z0dpjhgX20SCx4KAo'; // Public YouTube web-client parameter.
const allowed = new Set(['www.youtube.com', 'www.google.com', 'www.gstatic.com', 'jnn-pa.googleapis.com']);
async function boundedFetch(input, options = {}) {
  const url = new URL(input, 'https://www.youtube.com');
  if (url.protocol !== 'https:' || !allowed.has(url.hostname)) throw new Error('unavailable');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(url, { ...options, credentials: 'omit', signal: controller.signal });
    const reader = response.body?.getReader();
    const chunks = [];
    let length = 0;
    if (reader) {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > 4 * 1024 * 1024) throw new Error('oversize');
        chunks.push(value);
      }
    }
    return new Response(new Blob(chunks), { status: response.status, headers: response.headers });
  }
  finally { clearTimeout(timer); }
}
async function initialize() {
  const began = performance.now();
  stage = 'challenge';
  const challenge = await getChallenge({ requestKey, fetchFunction: boundedFetch, useYouTubeAPI: false });
  stage = 'interpreter';
  let interpreter = challenge.interpreterJavascript?.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (!interpreter) {
    const location = challenge.interpreterUrl?.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue;
    if (!location) throw new Error('unavailable');
    interpreter = await (await boundedFetch(location)).text();
  }
  if (!interpreter || interpreter.length > 4 * 1024 * 1024) throw new Error('unavailable');
  new Function(interpreter)();
  stage = 'attestation';
  const guard = await BotGuardClient.create({ globalObject: globalThis, globalName: challenge.globalName, program: challenge.program });
  const webPoSignalOutput = [];
  const proof = await guard.snapshot({ webPoSignalOutput });
  stage = 'integrity';
  const response = await boundedFetch(buildURL('GenerateIT', false), {
    method: 'POST', headers: getHeaders(), body: JSON.stringify([requestKey, proof])
  });
  if (!response.ok) throw new Error('unavailable');
  const [integrityToken, ttl] = await response.json();
  const lifetime = Number.isFinite(ttl) && ttl > 0 ? Math.min(ttl, 21600) : 300;
  stage = 'minter';
  const minter = await WebPoMinter.create({ integrityToken }, webPoSignalOutput);
  return { minter, expires: Date.now() + lifetime * 1000, setupMilliseconds: Math.round(performance.now() - began) };
}
globalThis.illucetMintToken = async function(binding) {
  if (typeof binding !== 'string' || !binding.length || binding.length > 4096) throw new Error('invalid_request');
  try {
    if (!initialized) initialized = initialize().catch(error => { initialized = undefined; throw error; });
    let state = await initialized;
    if (state.expires <= Date.now() + 60000) { initialized = initialize(); state = await initialized; }
    stage = 'mint';
    const began = performance.now();
    const token = await state.minter.mintAsWebsafeString(binding);
    return JSON.stringify({ token, expires: state.expires / 1000, setupMilliseconds: state.setupMilliseconds,
      mintMilliseconds: Math.round(performance.now() - began) });
  } catch {
    return JSON.stringify({ failure: stage });
  }
};
