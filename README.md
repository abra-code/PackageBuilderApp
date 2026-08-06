# PackageBuilder.app

A macOS applet that turns pre-built artifacts into a signed installer package.

Point it at files that already exist, choose where each one installs, press Build
Package. It runs `pkgbuild`, `productbuild` and `productsign`, and applies the
handful of non-obvious corrections that a hand-rolled `pkgbuild` invocation gets
wrong.

Built with [OMC](https://github.com/abracode/OMC) 5.1 and ActionUI. Shell
handlers only - no embedded interpreter.

## Scope

```
   [ your build ]  ->  PackageBuilder  ->  [ Notarize.app ]
    not our job       artifacts in,          not our job
                    signed package out
```

**It does not build your product.** How the artifacts are produced - Xcode, make,
swift build, a CI job on another machine - is project-specific and changes over a
project's life. Packaging does not. So the build stays where it belongs, and this
app starts from whatever that build produced.

**It does not notarize.** Notarize.app already does that, with its own credential
wizard and submit/wait loop, and accepts a flat `.pkg` as a first-class target.
PackageBuilder ends at a signed package and hands it over.

## The document

A project is a `.pkgbuilderproj` file: plain JSON, meant to live in the
repository next to the sources it packages, so a version bump is a one-line diff.

```json
{
  "FORMAT_VERSION": 1,
  "PROJECT": {
    "NAME": "replay",
    "VERSION": "2.2",
    "ARTIFACTS_DIR": "../replay-Distributions/build",
    "OUTPUT_DIR": "../replay-Distributions",
    "PACKAGE_NAME": "${NAME}_${VERSION}.pkg"
  },
  "COMPONENTS": [
    {
      "IDENTIFIER": "com.abracode.pkg.replay",
      "INSTALL_LOCATION": "/",
      "OVERWRITE_PERMISSIONS": false,
      "RELOCATABLE": false,
      "PAYLOAD": [
        { "SOURCE": "${ARTIFACTS_DIR}/replay",
          "DESTINATION": "/usr/local/bin/replay",
          "MODE": "0755" }
      ]
    }
  ]
}
```

`ARTIFACTS_DIR` is the one field that changes between releases: repoint it and
every payload source follows.

## What it gets right that a raw pkgbuild does not

- **`overwrite-permissions` is forced to false.** `pkgbuild` writes `true`, which
  tells Installer to re-own directories that already exist. With a payload under
  `/usr/local/bin`, installing resets `/usr/local` to `root:wheel` and leaves
  Homebrew unable to write.
- **Bundles are not relocatable by default.** `pkgbuild` marks them relocatable,
  so Installer hunts for an existing copy by bundle id via Spotlight and installs
  *there* - a stale copy in `~/Downloads` silently becomes the install target.
- **Unsigned intermediates never reach the output folder**, so an unsigned
  package can never sit one word away in the filename from the one you upload.
- **Artifacts are verified before packaging**: architectures, Developer ID
  authority, hardened runtime, secure timestamp, and a cross-check that the
  binary's own reported version matches the document's. That last one is what
  catches a stale artifacts folder shipping old code under a new version number.

## Status

Under development. Phase 1 (document lifecycle) is implemented; the build
pipeline is not yet. See `Private/Design.md` for the full specification and the
phasing plan.

## Building the applet

```sh
AB="/path/to/OMC/Distribution/AppletBuilder.app/Contents/Resources/Agents/appletbuilder"
"$AB" validate PackageBuilder.app
"$AB" build PackageBuilder.app
```

Handler scripts must be validated with `sh -n`, never `bash -n`: they run under
macOS `/bin/sh` (bash 3.2 in POSIX mode), and `bash -n` accepts constructs that
are fatal there.

To trace handler execution, `touch /tmp/packagebuilder_debug` and read
`/tmp/packagebuilder_debug.log`.

## License

Apache 2.0. See `LICENSE`.
