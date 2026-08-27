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
that the file changed on disk; the component list with add, remove and reorder;
the payload tab with drop, folder scan, reorder and the per-item inspector; the verify stage with its diagnostics and a Stop
that asks the build to stop rather than killing it; `pkgbuild` with the
`overwrite-permissions` and `--component-plist` corrections; `Distribution.xml`
generation; `productbuild` and `productsign`; export as a standalone packaging
script; import of a Packages.app `.pkgproj`; import of a built `.pkg`; and the
handoff to Notarize.app.
Beyond the original plan there is an agent CLI at
`Contents/Resources/Agents/pkgbuilder`, a document format verifier, and a skill.

Phase 5 is now complete: Actions > Inspect Built Package takes the package apart
and reports what is actually in it, and the two app-wide defaults are
remembered.

A document holds an array of components and builds every one of them: one
`pkgbuild` run and one Distribution choice each. Most projects need one - with
`INSTALL_LOCATION` `/` and absolute destinations, a single component already
spans `/usr/local/bin`, `/Applications` and `/Library/Frameworks`. A second earns
its keep when a part has to be separately selectable in the installer, or needs
its own install scripts, `auth` or relocatability.

The window has four tabs - Project, Components, Distribution, Build - and one
rule: a tab either belongs to the document or belongs to one component. The
Components tab holds the list, and everything that list governs: the component's
settings and its payload. Click a component to edit it, and add, remove or
reorder with the buttons under the list. The CLI's `add-component`,
`remove-component` and `--component` reach the same components from a script.

A component may carry a version of its own; leave it empty and it takes the
project's, which is what most projects want. Set it when a part ships on its own
schedule - macOS records a version per component, so a 1.0 helper tool beside a
2.4 app is an ordinary installer and nothing complains about it.

See `Private/Design.md` for the full specification and the phasing plan.

## Inspecting what was built

Actions > Inspect Built Package expands the package into a scratch directory,
reports, and throws the expansion away. It reads the most finished package there
is - the signed installer, or the unsigned distribution package when signing is
off, or the component package after Build Component Only - and says which one it
is looking at.

What it reports is the artifact, not the document: the signature, the
Distribution settings, and for each component the identifier, version, install
location, `overwrite-permissions`, the relocate list, and the BOM with owners and
modes. Two of those are the reason the feature is worth having.

**`auth` is read from the Distribution, and labeled.** `pkgbuild` writes
`auth="root"` into `PackageInfo` whatever the project says, so a user who goes
looking for it finds the wrong answer in the obvious place. The document's real
value lands on the Distribution `pkg-ref`, and that is what the report shows.

**The BOM lists the parent directories, not just your files.** A payload into
`/usr/local/bin` gives a BOM carrying `./usr/local` as `root:wheel`. Seeing that
next to `overwrite-permissions: false` is the whole of why that correction
exists.

## Starting from a package you already have

Actions > Import Built Package... is the other direction: it reads a flat `.pkg`
and writes the document that would produce it. Identifier, install location,
`overwrite-permissions`, whether the bundles are relocatable, `auth` from the
Distribution `pkg-ref`, the payload with every mode and owner from the BOM, the
Distribution options, and the installer identity read out of the package's own
certificate rather than out of this machine's keychain - so it works on somebody
else's package, and on one whose certificate has expired.

The payload comes back as artifacts, not as files. A bundle is one entry rather
than the thousands inside it, and a component whose install location is itself a
bundle - a framework - becomes a single entry with the install location set to
the bundle's parent, which is the document you would have written by dropping
that framework on the payload table.

The one thing a package cannot carry is where its artifacts came from. Every
`SOURCE` arrives as `${ARTIFACTS_DIR}/<name>` and the artifacts folder is left
empty, so the document is well-formed but refuses to build until you point that
one field at a build folder. That refusal is deliberate: an empty
`${ARTIFACTS_DIR}` would otherwise collapse to `/usr/local/bin/tool`, which very
likely exists and is the previously installed copy.

Everything that could not come across is named in the log rather than dropped
quietly - the further components of a multi-component package, install scripts
and presentation resources, which are in the package but are not extracted to
disk, and any payload over 500 items, which is a file tree rather than a list of
artifacts. In that last case the rest of the document still lands.

## What it remembers

Two app-wide defaults live in
`~/Library/Application Support/PackageBuilder/prefs.plist`: the installer
identity you last chose from the picker, and the last output folder you picked
through Browse. A new project starts with both filled in.

They seed **new** projects only. An opened project carries its own choices and is
never touched, and seeding does not mark a document dirty - a fresh window does
not ask to be saved before you have typed anything. A remembered identity that is
not in this machine's keychain, or a folder that has been deleted, is skipped
rather than filled in: starting empty beats starting with a value that fails a
build precondition for a choice you made weeks ago on another machine.

The agent CLI deliberately does not read them. `pkgbuilder new` in a CI job has
to produce the same document on every machine, whoever last used the window.

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

Eight files, around 930 checks. They drive the handler scripts under a
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
