# Generated Dependencies

`Vendor/Downloads`, `Vendor/Source`, `Vendor/Build`, `Vendor/Frameworks`, and
`Vendor/PythonPackages` are generated and intentionally ignored by Git.

Pinned versions and digests live in `Config/Dependencies.sh`. Fetch them with:

```sh
./Scripts/fetch-stage0-dependencies.sh
```

The script verifies SHA-256 for every archive/wheel and additionally verifies
FFmpeg's detached release signature against fingerprint
`FCF986EA15E6E293A5644F10B4322F04D67658D8`.

The generated Python package directory is pure source/data. The setup rejects
native `.so`, `.dylib`, and `.fwork` content because unsigned executable code
cannot be activated from an iOS writable container.
