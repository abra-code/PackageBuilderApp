---
name: packagebuilder
description: >
  Build, sign and verify macOS installer packages (.pkg) with PackageBuilder.app and its pkgbuilder CLI. Use when the user asks to create or edit a .pkgbld project, package a binary or app into a .pkg, verify payload artifacts before packaging, convert a Packages.app .pkgproj, export a standalone packaging script, or debug pkgbuild/productbuild/productsign/PackageInfo problems.
version: "1.0"
---

# PackageBuilder Skill

## What PackageBuilder is

PackageBuilder.app builds macOS installer packages from a declarative project
document. It replaces a hand-written `makepkg.sh` and the unmaintained
Packages.app, using Apple's own tools: `pkgbuild`, `productbuild`, `productsign`,
`pkgutil`, `codesign`, `lipo`.

It **does not build your product**. Artifacts arrive already built and already
signed, from whatever machine produced them; PackageBuilder verifies them, stages
them, and wraps them. It **ends at a signed package** - notarization belongs to
Notarize.app or `xcrun notarytool`.

## Drive it from the CLI

Everything below is done with the agent CLI inside the bundle, which calls the
same shared library code the GUI does:

```
<PackageBuilder.app>/Contents/Resources/Agents/pkgbuilder <command> [args]
```

stderr carries progress and diagnostics, stdout carries capturable results, and
the exit code is `0` ok / `2` warnings / `1` errors. The full reference is
`Contents/Resources/Agents/README.md` in the bundle - read it when you need a flag
you do not see here.

**Read the schema before writing a document by hand.** It is a file you can open
directly, beside the tool:

```
<PackageBuilder.app>/Contents/Resources/Agents/packagebuilder-schema.jsonc
```

`pkgbuilder schema` prints that same file. It is commented pseudo-JSON - every key
with its type, its default, the constraint on it, and what goes wrong when it is
set incorrectly - so it is documentation to read, not a document to parse.

## The workflow that works

```sh
PB="/Applications/PackageBuilder.app/Contents/Resources/Agents/pkgbuilder"

# 1. Start a document. --name and --identifier are required.
DOC=$("$PB" new ~/widget.pkgbld \
        --name widget --identifier com.example.pkg.widget \
        --version 2.0 --min-os 12.0 \
        --artifacts-dir ~/build --output-dir ~/dist \
        --identity "Developer ID Installer: Example Inc (TEAMID)")

# 2. Add artifacts. The destination, mode and verify assertions are guessed
#    from the artifact's kind; the printed index is used in key paths below.
IDX=$("$PB" add-payload "$DOC" ~/build/widget)

# 3. Say what must be true of it.
"$PB" set "$DOC" "/COMPONENTS/0/PAYLOAD/$IDX/VERIFY/ARCHITECTURES" arm64,x86_64
"$PB" set "$DOC" "/COMPONENTS/0/PAYLOAD/$IDX/VERIFY/VERSION_FLAG" --version

# 4. Check the document, then check what a build would do.
"$PB" validate "$DOC"
"$PB" build "$DOC" --dry-run

# 5. Build.
PKG=$("$PB" build "$DOC")
"$PB" inspect "$PKG"
```

**Always run `--dry-run` before a real build.** It runs every judgement the build
makes - all preconditions, the real payload verify against the artifacts on disk,
and the real Distribution XML generation - and writes nothing. A dry run that
passes has exercised everything except the four Apple tools that produce bytes.

## Rules that will bite you

1. **`MODE` is a string of octal digits, not a number.** `"0755"`, never `755`.
   The verifier catches this; a hand-written document that gets it wrong builds a
   package with the wrong permissions.
2. **Two payload destinations may not be equal, and one may not be a prefix of
   another.** Staging is a sequence of `ditto` calls, so a nested pair silently
   races. The preconditions refuse it.
3. **Every destination must be under `INSTALL_LOCATION`.**
4. **`OVERWRITE_PERMISSIONS` must stay `false`** unless you know exactly why not.
   `pkgbuild` always writes `true`, which tells Installer to apply the payload's
   owner and mode to directories that *already exist* - with a payload under
   `/usr/local` that resets a Homebrew user's directories. PackageBuilder patches
   `PackageInfo` to force this back to `false`; do not undo it.
5. **`RELOCATABLE` must stay `false`** for bundles. `pkgbuild` marks bundles
   relocatable, which makes Installer follow Spotlight to any existing copy of that
   bundle identifier - a stale copy in `~/Downloads` silently becomes the install
   target.
6. **`HOST_ARCHITECTURES` must not be empty.** `productbuild` refuses a document
   with an empty `hostArchitectures`, so the installer would run nowhere.
7. **`PACKAGE_NAME` must not contain a path separator.** It is a file name, not a
   path.
8. **`arm64e` is not `arm64`.** They are separate architectures, and asserting one
   does not accept the other.
9. **An unsigned package never reaches the output folder** (design 8.3). Only a
   signed, signature-checked package lands there.

## The verify block is the point

Each payload entry carries a `VERIFY` block saying what must be true of that
artifact. This is where packaging catches mistakes that are otherwise invisible
until the notary service rejects the upload an hour later:

| Key | Catches |
|---|---|
| `ARCHITECTURES` | half the build used the wrong settings; a slice is missing |
| `SIGNED_BY` | an ad-hoc signature, or the wrong team's certificate |
| `HARDENED_RUNTIME` | `xcodebuild build` instead of `xcodebuild archive` |
| `SECURE_TIMESTAMP` | the same mistake; notarization rejects both |
| `VERSION_FLAG` | **a stale artifacts folder** - the one with no other symptom |

`SIGNED_BY` matches as a **prefix of the leaf certificate**, so
`"Developer ID Application"` accepts any Developer ID and a full identity string
accepts only that one.

`VERSION_FLAG` is opt-in per entry because a payload may legitimately carry a 1.0
helper beside a 2.2 app. When set, the artifact's reported version must equal
`PROJECT.VERSION`. A bundle answers from its `Info.plist`; a bare executable is run
with the flag.

Set these with `pkgbuilder set`, which validates the value:

```sh
"$PB" set "$DOC" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY "Developer ID Application"
"$PB" set "$DOC" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME true
"$PB" set "$DOC" /COMPONENTS/0/PAYLOAD/0/VERIFY/SECURE_TIMESTAMP true
```

For a plain resource file that asserts nothing, add it with `--no-verify`.

## Paths and tokens

Paths in a document may use `${ARTIFACTS_DIR}`, `${PROJECT_DIR}`, `${NAME}`,
`${VERSION}` and `${DATE}`. A path under the artifacts folder is stored as
`${ARTIFACTS_DIR}/...` automatically, and that is what makes a document portable:
the same project builds on the machine where the artifacts actually land, with
`--artifacts-dir` pointing at them.

`${ARTIFACTS_DIR}` used in a document that has no artifacts folder set is a hard
error rather than an empty string - `${ARTIFACTS_DIR}/usr/local/bin/tool` would
otherwise collapse to `/usr/local/bin/tool`, which very likely exists and is the
*previously installed copy*.

## Reading a failure

- **"not built for arm64 - lipo reports [x86_64 arm64e]"** - the artifact is
  missing a slice, or the entry asserts the wrong name.
- **"signed without a secure timestamp"** / **"not signed with the hardened
  runtime"** - built with `xcodebuild build`; rebuild with `xcodebuild archive`.
- **"expected a signature from X, found nothing - the signature is ad-hoc"** - the
  machine that built it was missing its distribution signing settings.
- **"reports version 1.9, but this is being built as 2.0"** - the artifacts folder
  is stale. This is the failure with no other symptom; do not work around it by
  clearing `VERSION_FLAG`.
- **"destination is not under the install location"** - fix the destination, not
  the install location.
- **"the code signature does not verify"** on a fat binary - data was appended past
  the signed region, which a per-slice check does not see.

## Other things it does

```sh
# Convert an old Packages.app project.
"$PB" import-pkgproj old.pkgproj new.pkgbld

# Write a self-contained /bin/sh script that reproduces this package with no
# dependency on PackageBuilder - for a CI machine with no GUI session.
"$PB" export-script "$DOC" makepkg.sh
sh makepkg.sh --version 2.1 --artifacts-dir ./build --output-dir ./dist

# Look inside a built package.
"$PB" inspect dist/widget_2.0.pkg
```

## Notarization

PackageBuilder stops at a signed package. Then either:

```sh
xcrun notarytool submit "$PKG" --keychain-profile <profile> --wait
xcrun stapler staple "$PKG"
```

or hand it to Notarize.app with **Sign before submitting turned off**, so it
verifies the existing signature rather than replacing it.

## Editing a document without the CLI

Prefer `pkgbuilder set` - it knows every key's type and rejects the rest. If you
must edit the JSON directly, run `pkgbuilder validate` afterward: the failure mode
of a hand-edited document is usually a wrong type or a misspelled key, which the
app silently ignores rather than reporting.
