#!/bin/bash
# Build a document .icns from one square 1024x1024 source (SVG or PNG).
#
#   ./make_doc_icns.sh PackageBuilderDoc.svg PackageBuilderDoc.icns
#
# IMPORTANT: sips rasterizes SVG but SILENTLY DROPS filter effects, so any
# blur/drop-shadow renders as nothing. SVG input therefore goes through
# Inkscape. PNG input uses sips, which is fine since it is already raster.
# Note Inkscape 1.4 does not implement feDropShadow either - use the classic
# feGaussianBlur/feOffset/feFlood/feComposite/feMerge chain instead.
set -euo pipefail

SRC="${1:?usage: make_doc_icns.sh <square-source.svg|png> <out.icns>}"
OUT="${2:?usage: make_doc_icns.sh <square-source.svg|png> <out.icns>}"
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }

INKSCAPE="${INKSCAPE:-/Applications/Inkscape.app/Contents/MacOS/inkscape}"
case "${SRC##*.}" in
    svg|SVG)
        [ -x "$INKSCAPE" ] || {
            echo "SVG input needs Inkscape (sips drops filters)." >&2
            echo "Set INKSCAPE=/path/to/inkscape, or pre-render to PNG." >&2
            exit 1; }
        RENDER=inkscape ;;
    *)  RENDER=sips ;;
esac

WORK="$(mktemp -d)"; SET="$WORK/icon.iconset"; mkdir -p "$SET"
trap 'rm -rf "$WORK"' EXIT

for spec in \
    icon_16x16:16      icon_16x16@2x:32 \
    icon_32x32:32      icon_32x32@2x:64 \
    icon_128x128:128   icon_128x128@2x:256 \
    icon_256x256:256   icon_256x256@2x:512 \
    icon_512x512:512   icon_512x512@2x:1024
do
    name="${spec%:*}"; px="${spec#*:}"
    if [ "$RENDER" = inkscape ]; then
        "$INKSCAPE" --export-type=png --export-filename="$SET/$name.png" \
                    --export-width="$px" --export-height="$px" "$SRC" >/dev/null 2>&1
    else
        sips -s format png --resampleHeightWidth "$px" "$px" "$SRC" \
             --out "$SET/$name.png" >/dev/null
    fi
    [ -s "$SET/$name.png" ] || { echo "failed to render $name" >&2; exit 1; }
done

iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT  (rendered with $RENDER)"
