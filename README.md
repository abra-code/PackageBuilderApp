# PackageBuilder.app
![PackageBuilder Icon](Icon/PackageBuilder-macOS-256x256@1x.png)

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

A project is a `.pkgbld` file: plain JSON, meant to live in the repository next
to the sources it packages, so a version bump is a one-line diff.

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

## Adding artifacts

Drop files on the payload table, or use the buttons below it: `+` adds one
artifact, the folder button searches a folder and adds everything it finds.

The search descends into ordinary directories and stops at a bundle, so an
`.app` arrives as one payload entry rather than as the four hundred files inside
it. It picks up loose Mach-O images at any depth, which is what finds
`build/Release/Widget.app` and `build/Release/widget` in one pass. It skips
symlinks, hidden entries, `.dSYM` bundles and relocatable object files - every
`.o` in a build folder is a Mach-O, and a list of three hundred of them helps
nobody. Choosing a bundle itself as the folder to scan adds that bundle, not its
contents. Running it twice over the same folder adds nothing the second time.

However an artifact arrives, its destination and permissions are guessed from
its kind, the verify checks start on for a Mach-O, and its source is stored
against `ARTIFACTS_DIR` when it lives below that folder.

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

Working end to end. A document opens, a payload is assembled, and Build Package
runs verify, component, distribution and sign in order, writing a signed `.pkg`.

Implemented: the document lifecycle, including close confirmation and noticing
that the file changed on disk; the payload tab with drop, folder scan, reorder
and the per-item inspector; the verify stage with its diagnostics and a Stop
that asks the build to stop rather than killing it; `pkgbuild` with the
`overwrite-permissions` and `--component-plist` corrections; `Distribution.xml`
generation; `productbuild` and `productsign`; export as a standalone packaging
script; import of a Packages.app `.pkgproj`; and the handoff to Notarize.app.
Beyond the original plan there is an agent CLI at
`Contents/Resources/Agents/pkgbuilder`, a document format verifier, and a skill.

Not implemented: **Inspect Built Package** is a disabled placeholder in the
Actions menu, and per-project preferences are unwired.

See `Private/Design.md` for the full specification and the phasing plan.

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

## Tests

```sh
"$AB" test PackageBuilder.app --tests Tests
```

Eight files, around 670 checks. They drive the handler scripts under a
simulated OMC environment and assert on the model file and the window calls the
handlers produce, so the whole app is testable headlessly.

One test is machine-dependent by design: the BOM acceptance check in
`50-distribution.test.sh` expands a package the app just built and compares it
against the shipped `replay_2.2.pkg`. It skips itself when that package is not
on the machine; set `PACKAGEBUILDER_REFERENCE_PKG` to point at a copy.

## License

Apache 2.0. See `LICENSE`.

### App icon

The icon artwork is a separate work under different terms. "Cardboard Boxes
Vectors" by [Creative Alys](https://www.creativealys.com), obtained via
[FreeVector.com](https://www.freevector.com/cardboard-boxes-vectors) and
licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The
source page states the requested credit verbatim as "Delivery Boxes by
Creativealys.com"; that string is recorded in the `cc:attributionName` field of
the SVG's metadata.
Modified: one box was isolated from the original six-box set and recomposed as
an icon layer over a generated gradient. CC BY 4.0 has no ShareAlike term,
so this does not affect the Apache 2.0 license on the rest of the project.
