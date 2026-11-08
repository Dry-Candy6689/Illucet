# Embedded Python

## Pinned runtime

- CPython: 3.14.6
- Source archive SHA-256:
  `143b1dddefaec3bd2e21e3b839b34a2b7fb9842272883c576420d605e9f30c63`
- Generated upstream support archive SHA-256:
  `9d4bacc4b2097668d2d019206453a6775f0aa37f04ad115184a2d7705f7c0ca8`
- Minimum runtime encoded by upstream: iOS 13
- Illucet minimum deployment target: iOS 26

`Scripts/build-python-ios.sh` invokes CPython's official `Apple build iOS`
entry point. The output is not committed. It creates:

```text
Vendor/Frameworks/Python.xcframework
```

The XCFramework contains:

- `ios-arm64`: physical-device arm64;
- `ios-arm64_x86_64-simulator`: arm64 and x86_64 simulator.

`Vendor/PythonSourceDeps.sha256` records the exact downloaded BeeWare
`cpython-apple-source-deps` artifacts. Versions are OpenSSL 3.5.7-1, bzip2
1.0.8-2, libffi 3.4.7-2, mpdecimal 4.0.0-2, XZ 5.6.4-2, and zstd 1.5.7-1.
The complete source URLs are preserved in the native build log.

## Patch

The CPython source itself is unmodified. One packaging-utility patch is applied:

```text
Patches/cpython-3.14-ios-codesign-xattrs.patch
```

The repository is in a Files-managed Documents folder. macOS 27 File Provider
can attach Finder metadata to a generated extension framework between creation
and signing. `codesign` correctly rejects that metadata. The patch calls
`xattr -cr` on each generated extension framework immediately before signing.
It does not modify Python code or binaries.

Build and test DerivedData should live outside a Files-managed folder. The
verified test command uses `/private/tmp/IllucetDerivedData`.

## Runtime initialization

All Python C API access is isolated in `Native/PythonBridge`. The bridge:

1. creates one dedicated pthread;
2. registers the built-in `_illucet_native` module;
3. uses isolated `PyPreConfig` and `PyConfig`;
4. disables environment, user-site, bytecode writes, signal handlers, and
   automatic site import;
5. initializes CPython on the pthread;
6. appends bundled trusted application Python, the writable update directory,
   and bundled third-party packages after the standard-library paths, in that
   precedence order;
7. serializes requests through a mutex/condition-variable FIFO;
8. performs cooperative cancellation through an atomic flag;
9. calls `Py_FinalizeEx` and joins the same pthread.

The native module exposes only:

- `emit_json`;
- `is_cancelled`;
- `is_main_thread`;
- bounded `quickjs_version` and `quickjs_evaluate` calls.

A native audit hook rejects exec, fork, `os.system`, spawn, `posix_spawn`,
`pty.spawn`, and `subprocess.Popen` events. No Python object crosses into
Swift; requests and responses are UTF-8 JSON. The native boundary rejects
requests larger than 16 KiB, individual callback events larger than 64 KiB,
and responses larger than 8 MiB before copying them across the C ABI.

Shutdown marks current and queued work cancelled, but CPython cannot safely be
forcibly killed. A native extension or network call that ignores cancellation
can delay the final `pthread_join` until its own bounded timeout. Live
extraction must therefore configure finite network/native-call timeouts; a
force-quit-safe or instant shutdown guarantee would be false.

## Bundled and writable packages

The build phase copies:

- production modules from `PythonApp` into the signed read-only bundle,
  excluding `tests/`, `__pycache__/`, and `.pyc` files;
- `Vendor/PythonPackages` into the signed read-only bundle;
- the CPython standard library into `python/`.

At runtime the proof creates:

```text
Library/Application Support/PythonPackages/v1
```

and imports a pure-Python module from it. Writable updates must be limited to
validated `.py` and approved data files. iOS binary extensions are packaged as
signed frameworks, so `.so`, `.dylib`, Mach-O, `.fwork`, and other native
payloads cannot be updated in the writable container.

## Disabled or unavailable modules

The stock build reported 35 built-in modules, 67 shared modules, 12 marked
unavailable for iOS, zero disabled, zero missing, and zero import failures.
The configure log explicitly marks these unavailable:

- `_multiprocessing`
- `_posixshmem`
- `grp`
- `pwd`
- `_scproxy`
- `syslog`
- `_curses`
- `_curses_panel`
- `_gdbm`
- `readline`
- `_tkinter`

CPython's build also uses `--disable-test-modules`, although the upstream
support package still contains test-library material. Production size trimming
has not yet been performed.
