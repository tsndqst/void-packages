#!/bin/sh
# validate-overlay.sh — check device-tree overlays apply cleanly to a base DTB,
# offline, using the same libfdt overlay path U-Boot uses at boot.
#
# For each overlay it:
#   1. compiles .dtso -> .dtbo with `dtc -@` (surfaces syntax errors + warnings)
#   2. pre-flight: every label the overlay needs (its __fixups__) must exist in
#      the base's __symbols__  -> pinpoints a typo'd/absent label before apply
#   3. applies the overlay(s) in order with `fdtoverlay -v`, then checks every
#      /aliases entry in the merged tree names a node that exists
#   4. (-d) prints a decompiled base-vs-merged diff so you can eyeball the effect
#
# Requires: dtc, fdtoverlay, fdtget  (Void: dtc; Debian: device-tree-compiler).
#
# Usage:
#   validate-overlay.sh [-d] BASE.dtb  OVERLAY[.dtso|.dtbo] ...
#     -d   show what the overlay(s) changed (decompiled diff)
#
# Examples:
#   validate-overlay.sh base.dtb nanopc-t6-uart-pinmux.dtso
#   validate-overlay.sh -d base.dtb nanopc-t6-uart-pinmux.dtbo nanopc-t6-uart4.dtbo
#   for o in *.dtso; do validate-overlay.sh base.dtb "$o" || exit 1; done
#
# Exit status: 0 = all good, 1 = a validation failure, 2 = usage/tooling error.

set -eu

SHOW_DIFF=0
if [ "${1:-}" = "-d" ]; then SHOW_DIFF=1; shift; fi

if [ $# -lt 2 ]; then
	echo "usage: $0 [-d] BASE.dtb OVERLAY[.dtso|.dtbo]..." >&2
	exit 2
fi

for t in dtc fdtoverlay fdtget; do
	command -v "$t" >/dev/null 2>&1 || { echo "error: '$t' not found (install dtc / device-tree-compiler)" >&2; exit 2; }
done

BASE="$1"; shift
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 0. base sanity + it must carry __symbols__ (label overlays need it) ---
fdtget -l "$BASE" / >/dev/null 2>&1 || fail "$BASE is not a readable DTB"
if ! fdtget -l "$BASE" /__symbols__ >/dev/null 2>&1; then
	fail "$BASE has no /__symbols__ node.
      Rebuild the base DTB with 'dtc -@'.
      fdtoverlay AND U-Boot both refuse label overlays without it."
fi
BASE_SYMS=" $(fdtget -p "$BASE" /__symbols__ 2>/dev/null | tr '\n\t' '  ') "

# --- 1+2. compile each overlay and pre-flight its required labels ---
BLOBS=""
for ov in "$@"; do
	case "$ov" in
	*.dtso|*.dts)
		out="$TMP/$(basename "${ov%.*}").dtbo"
		if ! dtc -@ -I dts -O dtb -o "$out" "$ov" 2>"$TMP/warn"; then
			sed 's/^/    /' "$TMP/warn" >&2
			fail "compile error in $ov"
		fi
		[ -s "$TMP/warn" ] && { echo "note: dtc warnings for $(basename "$ov"):"; sed 's/^/    /' "$TMP/warn"; }
		ov="$out"
		;;
	*.dtbo|*.dtb) : ;;
	*) fail "unrecognized file type: $ov (expected .dtso/.dts/.dtbo)" ;;
	esac

	# every label in the overlay's __fixups__ must be defined in the base
	if fdtget -l "$ov" /__fixups__ >/dev/null 2>&1; then
		for need in $(fdtget -p "$ov" /__fixups__ 2>/dev/null); do
			case "$BASE_SYMS" in
			*" $need "*) : ;;
			*) fail "$(basename "$ov"): references &$need, but the base DTB defines no such label" ;;
			esac
		done
	fi
	BLOBS="$BLOBS $ov"
done

# --- 3. apply (same libfdt path U-Boot takes) ---
# shellcheck disable=SC2086
if ! fdtoverlay -v -i "$BASE" -o "$TMP/merged.dtb" $BLOBS >"$TMP/log" 2>&1; then
	sed 's/^/    /' "$TMP/log" >&2
	fail "fdtoverlay could not apply the overlay(s)"
fi

# --- 3b. every alias must resolve in the merged tree ---
# fdtoverlay never checks alias strings, so an alias hardcoded to a node path
# that a newer base relocated would still "apply cleanly" and only fail at boot
# (e.g. U-Boot's MAC fixup: FDT_ERR_NOTFOUND).
for alias in $(fdtget -p "$TMP/merged.dtb" /aliases 2>/dev/null); do
	path="$(fdtget -t s "$TMP/merged.dtb" /aliases "$alias")"
	fdtget -p "$TMP/merged.dtb" "$path" >/dev/null 2>&1 ||
		fail "alias '$alias' points to '$path', which does not exist in the merged tree"
done

echo "PASS: $# overlay(s) apply cleanly to $(basename "$BASE")"

# --- 4. optional: show what changed (phandle-definition churn stripped) ---
if [ "$SHOW_DIFF" = 1 ]; then
	strip='/[[:space:]]\(linux,\)\?phandle = <0x/d'
	dtc -I dtb -O dts "$BASE"          2>/dev/null | sed "$strip" > "$TMP/a.dts"
	dtc -I dtb -O dts "$TMP/merged.dtb" 2>/dev/null | sed "$strip" > "$TMP/b.dts"
	echo "--- changes introduced (base -> merged) ---"
	diff -u "$TMP/a.dts" "$TMP/b.dts" | tail -n +3 || true
fi
