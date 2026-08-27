# PackageBuilder Agent CLI

`pkgbuilder` is a command-line front end to PackageBuilder.app, for AI agents and
scripts. It performs the same operations a human does in the window - construct a
project document, check it, verify the payload, and run the pipeline - by calling
the **same** shared library code the GUI uses
(`Contents/Resources/Scripts/lib.packagebuilder*.sh`), so a package built here and
a package built by pressing Build Package are the same package.

The tool lives inside the app bundle and finds everything it needs relative to
itself; just run it by path:

```
<PackageBuilder.app>/Contents/Resources/Agents/pkgbuilder <command> [args]
```

## Output and exit codes

- **stderr** - progress, the build log, and every diagnostic. In the GUI these go
  to the log view and the status line; for an agent they go to stderr so nothing
  needs a window.
- **stdout** - only results worth capturing: a document path, a value read out of
  a document, a built package's path, a payload entry index.
- **exit code** - `0` ok, `2` warnings (and usage mistakes), `1` errors.

## The document

A PackageBuilder project is a JSON file with the extension `.pkgbld`. The full
format lives in `packagebuilder-schema.jsonc` beside this README - commented
pseudo-JSON giving every key with its type, default and constraint, which
`pkgbuilder schema` prints. Read that file; the short version is:

- `PROJECT` - name, version, minimum macOS, the artifacts folder, the output
  folder, the package file name pattern.
- `COMPONENTS[n]` - identifier, choice title, install location, the two safety
  flags, and the `PAYLOAD` array. Every component is built: one `pkgbuild` run
  and one Distribution choice each. Most projects need one, because a single
  component with `INSTALL_LOCATION` `/` and absolute destinations already spans
  `/usr/local/bin`, `/Applications` and `/Library/Frameworks`.
- Each payload entry - `SOURCE`, `DESTINATION`, `MODE`, and a `VERIFY` block
  saying what must be true of that artifact.
- `DISTRIBUTION` - installer presentation and host architectures.
- `SIGNING` - whether to sign, and with which Developer ID Installer identity.

Paths may use `${ARTIFACTS_DIR}`, `${PROJECT_DIR}`, `${NAME}`, `${VERSION}` and
`${DATE}`. A path under the artifacts folder is stored as `${ARTIFACTS_DIR}/...`
automatically, which is what makes a document portable to the machine that builds
the artifacts.

## Commands

### new - start a document

```
pkgbuilder new <doc.pkgbld> --name <N> --identifier <ID>
               [--version <V>] [--min-os <V>] [--artifacts-dir <D>]
               [--output-dir <D>] [--install-location <L>] [--title <T>]
               [--identity <I>] [--no-signing] [--force]
```

`--name` and `--identifier` are required; everything else has the same default the
app's New Document has. The artifacts and output folders are stored relative to the
document when they sit below it, exactly as the window stores them.

A destination with no extension gets `.pkgbld`; one you spelled yourself is kept
as it is, whatever it is. A path that names a directory - ending in `/`, or `.`,
or `..` - is refused rather than turned into a hidden `.pkgbld` inside it.

Prints the path actually written on stdout. Capture that rather than reassembling
the name, because it is what every later command needs:

```sh
DOC=$(pkgbuilder new ~/widget --name widget --identifier com.example.pkg.widget)
# DOC is now ~/widget.pkgbld
```

### add-payload - add an artifact

```
pkgbuilder add-payload <doc> <artifact> [--destination <P>] [--mode <M>]
                       [--owner <O>] [--group <G>] [--component <N>] [--no-verify]
```

`--component` takes a component number counting from 1 and defaults to 1.

Runs the same logic as dropping a file on the payload table: it guesses the
destination from the artifact's kind (`.app` to `/Applications`, a bare executable
to `/usr/local/bin`, and so on), guesses the mode, and turns on the verify
assertions that make sense for it - a Mach-O starts out asserting universal,
Developer ID signed, hardened and timestamped. `--no-verify` clears all of them,
which is what a plain resource file wants.

The artifact does not have to exist yet. If it is not on this disk the entry is
still added, asserts nothing, and a note says so - that is the normal case when a
document is written before the build machine has run.

Prints the new entry's 0-based index on stdout, for use in `set` key paths.

### add-component / remove-component - more than one part

```
pkgbuilder add-component <doc> --identifier <ID> [--install-location <L>]
                         [--title <T>] [--description <D>]
pkgbuilder remove-component <doc> <N>
```

`add-component` prints the new component's number on stdout, counting from 1,
which is what `add-payload --component` takes. It fills in the rest of the keys,
so the document that lands is one `validate` accepts.

A component takes the project's version unless it is given one of its own with
`set <doc> /COMPONENTS/<N>/VERSION <v>`. Most projects never need that; set it
when a part ships on its own schedule, since macOS records a version per
component in its receipt database.

It refuses an identifier another component already has, and one differing from
another only in punctuation: `com.example.a-b` and `com.example.a_b` both reduce
to a single choice id and a single package file name, so one component would
quietly overwrite the other in the directory `productbuild` scans.

`remove-component` refuses to remove the last one - a project needs a component.

Reach for a second component when a part has to be separately selectable in the
installer, or needs its own install scripts, `AUTH` or `RELOCATABLE`. Splitting a
payload that needs none of those buys nothing and adds a way to get it wrong:
two components installing to the same path, or one inside another, are refused
before anything is built, and that is the mistake this makes possible.

```sh
DOC=$(pkgbuilder new ~/suite --name suite --identifier com.example.pkg.app)
pkgbuilder add-payload "$DOC" ~/build/Suite.app
N=$(pkgbuilder add-component "$DOC" --identifier com.example.pkg.cli --title "Command line tools")
pkgbuilder add-payload "$DOC" ~/build/suitectl --component "$N"
```

### set / get - edit and read

```
pkgbuilder set <doc> <keypath> <value>
pkgbuilder get <doc> [<keypath>]
```

`set` knows the type of every key the app reads and refuses anything else, which is
the point of it: writing a string where the app reads a boolean produces a document
that loads, displays correctly, and behaves as though the flag were off. It also
rejects out-of-range enumerations (`AUTH`, `CUSTOMIZE`) and architecture names.

The two architecture arrays take a comma-separated value:

```
pkgbuilder set doc.pkgbld /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES arm64,x86_64
pkgbuilder set doc.pkgbld /COMPONENTS/1/INSTALL_LOCATION /Library/Frameworks
pkgbuilder set doc.pkgbld /DISTRIBUTION/HOST_ARCHITECTURES arm64,x86_64
```

`get` with no key path prints the whole document; with one it prints that value, or
the keys of a container.

### validate - is this document well-formed?

```
pkgbuilder validate <doc> [--strict]
```

Two checks, reported separately because they answer different questions:

1. **Format** - are the keys ones the app knows, are the types right, are the
   enumerations in range. Unknown keys are warnings (a typo means the value you
   meant to set is silently absent); wrong types and missing required keys are
   errors. This reads the file as written, before the app's normalization can fill
   anything in.
2. **Build preconditions** - do the sources exist on this disk, do any two
   destinations collide, is the signing identity in this keychain.

A document can be perfectly well-formed and not yet buildable - the artifacts are
on another machine - and that is a normal state for a project under construction.
So unmet preconditions exit `2`, not `1`, unless you pass `--strict`.

### verify - do the artifacts match what the document claims?

```
pkgbuilder verify <doc>
```

Runs pipeline stage 1 on its own and writes nothing. Each payload entry is checked
against its `VERIFY` block: the architectures it must be built for, that its
signature validates, who signed it, whether it carries a secure timestamp and the
hardened runtime, and whether the version it reports is the version being built.

The messages name the mistake rather than the symptom. A binary from `xcodebuild
build` rather than `xcodebuild archive` is signed with `--timestamp=none` and no
hardened runtime - real signature, real certificate, and the notary service is the
first thing in the chain to object. A stale artifacts folder has no symptom at all
except the version cross-check.

### build - run the pipeline

```
pkgbuilder build <doc> [--dry-run] [--version <V>] [--artifacts-dir <D>]
                 [--output-dir <D>] [--identity <I>] [--unsigned]
```

Verify, stage, `pkgbuild`, patch `PackageInfo`, `productbuild`, `productsign`, and
land the signed package in the output folder. Prints the package path on stdout.

`--dry-run` is the one to reach for while writing a document. It runs every
judgement the build makes - all the preconditions, the real payload verify against
the artifacts on disk, and the real Distribution XML generation - then prints what
*would* be staged, the XML it generated, and where the package would land. Nothing
is written outside a scratch directory that is removed when the command exits. A
dry run that passes has exercised everything except the four Apple tools that
produce bytes.

The overrides are applied to a working copy, never to the document on disk: a CI
run that passes `--version` does not silently rewrite the project it was handed.

### inspect - what is in a built package?

```
pkgbuilder inspect <package.pkg>
```

Expands the package and prints its `Distribution`, each component's `PackageInfo`,
the payload file list, and the signature check. Useful for confirming that
`overwrite-permissions` and `relocatable` really came out `false`.

### export-script - the standalone packaging script

```
pkgbuilder export-script <doc> <out.sh>
```

Writes a self-contained `/bin/sh` script that reproduces this document's package
with no dependency on PackageBuilder or OMC, on any Mac with Apple's command line
tools. It takes `--version`, `--artifacts-dir`, `--output-dir`, `--identity` and
`--unsigned`, and ends at a signed package, printing the `notarytool` command to
run next. This is what puts the packaging step on a CI machine with no GUI session.

### import-pkgproj - convert a Packages.app project

```
pkgbuilder import-pkgproj <in.pkgproj> <out.pkgbld> [--force]
```

The destination follows the same rule as `new`: `.pkgbld` when you spelled no
extension, otherwise left alone, and the path written is printed.

Maps a Packages.app `.pkgproj` into a PackageBuilder document: settings, install
location, the payload hierarchy, the readme, and the build path. What Packages
stores and this model does not carry - the presentation model beyond the readme,
the excluded-file patterns, the requirement list, and the filesystem template tree -
is dropped, and the log names each dropped thing.

### import-pkg - recover a document from a built package

```
pkgbuilder import-pkg <in.pkg> <out.pkgbld> [--force]
```

The reverse of the build, as far as a package can be reversed. Reads a flat
`.pkg` - one this app built, or anybody's - and writes the document that would
produce it: identifier, install location, `overwrite-permissions`, the relocate
list, `auth` from the Distribution's `pkg-ref`, the payload with its modes and
owners, the Distribution options, and the installer identity read out of the
package's own certificate.

The payload is collapsed back to artifacts rather than files: a bundle arrives as
one entry, not as the thousands inside it, and a component whose install location
is itself a bundle - a framework - arrives as a single entry with the install
location set to the bundle's parent.

What a package cannot carry is where its artifacts came from. Every `SOURCE` is
written as `${ARTIFACTS_DIR}/<name>` and the artifacts folder is left empty, so
the document is well-formed but will not build until you set it - which is the
point, since design 4.3 makes an unset `${ARTIFACTS_DIR}` a hard precondition
failure rather than a path that silently resolves to an installed copy.

Also not imported, each named in the log: the further components of a
multi-component package (this model holds one), the install scripts and
presentation resources, which are in the package but are not extracted, and any
payload over 500 items, which is a file tree rather than a list of artifacts -
there the rest of the document still lands.

### schema - the document format

```
pkgbuilder schema
```

Prints `packagebuilder-schema.jsonc`, the file beside this one: commented
pseudo-JSON giving every key with its type, default and constraint, and what goes
wrong when it is set incorrectly. An agent can read that file directly instead of
running the command. Read it before writing a document by hand.

## A worked example

```sh
PB="/Applications/PackageBuilder.app/Contents/Resources/Agents/pkgbuilder"

DOC=$("$PB" new ~/widget.pkgbld \
        --name widget --identifier com.example.pkg.widget \
        --version 2.0 --min-os 12.0 \
        --artifacts-dir ~/build --output-dir ~/dist \
        --identity "Developer ID Installer: Example Inc (T9NM2ZLDTY)")

"$PB" add-payload "$DOC" ~/build/widget
"$PB" set "$DOC" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES arm64,x86_64
"$PB" set "$DOC" /COMPONENTS/0/PAYLOAD/0/VERIFY/VERSION_FLAG --version

"$PB" validate "$DOC"          # well-formed? buildable here?
"$PB" build "$DOC" --dry-run   # what would happen, writing nothing
PKG=$("$PB" build "$DOC")      # do it
"$PB" inspect "$PKG"
```

## What this tool will not do

It ends at a signed package, exactly as the app does. Notarization belongs to
Notarize.app or to `xcrun notarytool`; the build prints the command to run next
rather than embedding a credential profile name that only exists on one machine.
