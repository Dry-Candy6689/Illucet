# Embedded JavaScript runtime

QuickJS-ng evaluates the bounded JavaScript challenges requested by the embedded yt-dlp/EJS provider. Native host limits and typed JSON preserve the extraction boundary.

## Versions and source integrity

- QuickJS-ng 0.15.0, official `quickjs-amalgam.zip`
- Archive SHA-256:
  `43752d204423da6e86eb4a62f45de1cd3948bb23f2e06a04b150fcb32b5d5427`
- yt-dlp 2026.07.04
- yt-dlp EJS 0.8.0
- EJS core SHA-256:
  `18da6ce0758b416e7ae645084f4f8801f9f9d59d6c477c05eaa0ff94ebd8cc00`
- EJS library SHA-256:
  `c55987fe697e5b9ee18830163f7af85327e9bb5c3e674b969d38c8d205eaa577`

`Scripts/build-quickjs-ios.sh` verifies the archive before extracting it. It
also requires the ZIP to contain exactly the three pinned amalgamation files
before extraction. It compiles the core with Apple clang, `-std=c11`, `-O2`,
`-DNDEBUG`, PIC, hidden visibility, `QUICKJS_NG_BUILD`, and the iOS 26
deployment target. It does not define `QJS_BUILD_LIBC`, compile a CLI entry
point, or place `qjs` in the app. It produces device arm64 and simulator
arm64/x86_64 static slices. Replacement keeps a recoverable previous framework
until the new one has moved into place.

## Bridge architecture

`Native/JavaScriptBridge/IllucetQuickJSBridge.c` owns one fresh runtime and
context per evaluation:

1. Create `JSRuntime` and apply memory, stack, blocking, and interrupt limits.
2. Create `JSContext`.
3. Install only capture-backed `console.log`/`print` output and an empty
   `scriptArgs` array matching restricted `qjs` script mode.
4. Evaluate one global script assembled by yt-dlp EJS.
5. Drain pending jobs.
6. Convert a bounded result or typed error to native-owned UTF-8.
7. Free every value, context, and runtime before returning.

QuickJS is invoked on CPython's dedicated interpreter pthread. Runtime/context
objects never cross threads and no QuickJS object crosses into Swift. Each
evaluation is isolated; extraction requests remain FIFO-serialized by the
Python engine. That pthread reserves an 8 MiB native stack; the QuickJS runtime
limit is lower so QuickJS can reject excessive recursion before reaching the
pthread guard.

The built-in `_illucet_native.quickjs_evaluate` is the only Python entry point.
It accepts source and bounded numeric limits. `IllucetQuickJSJCP` subclasses
the pinned private yt-dlp `EJSBaseJCP` seam and overrides only
`_run_js_runtime`, returning captured stdout exactly as EJS expects. All stock
external runtime configuration will be disabled in the live extractor.
The provider buffers and validates the complete response set before yielding
anything to yt-dlp's director. Missing, extra, malformed, error-bearing, or
semantically invalid responses raise a redacted fail-closed error outside the
director's normal fallback handling.

## Resource and error rules

Production provider defaults:

- JavaScript heap: 160 MiB
- JavaScript stack: 2 MiB
- wall-clock timeout: 30 seconds
- captured output: 8 MiB

The native API rejects source above 16 MiB, heap limits outside 16–256 MiB,
stack limits outside 256 KiB–4 MiB, timeouts outside 1–60 seconds, and output
above 16 MiB.
The live simulator player program failed closed at both 128 MiB and 144 MiB
with sanitized reason `runtime_thrown_null`; the same extraction passed at
160 MiB. No JavaScript source, stack trace, signed URL, or challenge value was
included in that error. Physical-device measurements may justify changing the
heap limit later, but 160 MiB is the current proven simulator configuration.

The interrupt callback reads only the current job's atomic cancellation flag
and a monotonic deadline. It never calls Python or Swift. Timeout, cancellation,
output overflow, and general JavaScript errors map to distinct Python exception
types. Normal errors contain no source text or JavaScript stack trace; signed
challenge inputs are not logged.

## Security boundary

YouTube player JavaScript is untrusted input executed by native QuickJS inside
the app process. The bridge supplies no filesystem, network, process, or
arbitrary native host callbacks, and execution is isolated per request with
resource limits. This reduces capability and denial-of-service exposure; it
does not make a native-engine memory-safety defect harmless. Any such defect
would inherit the app sandbox's privileges. The production target must keep
entitlements minimal, keep sensitive cookies out of this runtime, and update
the native engine only through a reviewed Xcode rebuild.

## Update compatibility and licenses

The adapter uses a private yt-dlp class. Pure-Python yt-dlp/EJS updates must not
activate independently. Every candidate pair must pass pinned imports, provider
registration, EJS hashes/contract checks, and a live authorized extraction
self-test before atomic activation; otherwise it must roll back.

QuickJS-ng is MIT licensed. yt-dlp and EJS core are Unlicense; bundled EJS
dependencies include Meriyah (ISC) and Astring (MIT). The native QuickJS
library cannot update over the network and requires an Xcode rebuild.
