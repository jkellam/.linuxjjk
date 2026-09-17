#!/usr/bin/env bash
# Health check for the Brief/SlickEdit VS Code setup.
#
# Usage:  bash check-install.sh          # report only, changes nothing
#         bash check-install.sh --fix    # also repair what it can
#
# Exists because of a real failure on 2026-08-19: everything on disk was
# correct, but the extension's commands were missing at runtime and VS Code
# reported "command 'briefHelpers.rubout' not found" with NOTHING in any log.
# See "Stale extension copies" in setting-up-vscode.md for the full trace. The
# short version: installing the helper extension while VS Code is running
# leaves the OLD version's directory on disk marked for deletion, because a
# running VS Code still holds it. VS Code reclaims it at a later startup -- and
# that startup both deletes the stale directories AND builds the extension
# registry, ~450ms apart. Scanning a directory that holds several copies of the
# same extension id while two of them are being deleted underneath dropped the
# id from the registry entirely, silently.
#
# So the thing to watch for is: more than one
# local.brief-slickedit-helpers-* directory, or an entry for it in .obsolete.
# Either means the next VS Code start has a stale copy to reclaim and can lose
# the extension again.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

EXT_DIR="$HOME/.vscode/extensions"
USER_DIR="$HOME/.config/Code/User"
EXT_ID="local.brief-slickedit-helpers"
FONT_FAMILY="Cascadia Code"

fail=0
warn=0
ok()   { echo "  [ ok ] $*"; }
bad()  { echo "  [FAIL] $*"; fail=$((fail+1)); }
note() { echo "  [warn] $*"; warn=$((warn+1)); }

echo "Brief/SlickEdit VS Code setup -- health check"
echo

# --- 1. the failure mode that actually bit -------------------------------
echo "1. Extension copies on disk (the thing that broke on 2026-08-19)"
shopt -s nullglob
copies=("$EXT_DIR/$EXT_ID"-*)
shopt -u nullglob
if [ ${#copies[@]} -eq 0 ]; then
    bad "no $EXT_ID-* directory at all -- the extension isn't installed"
elif [ ${#copies[@]} -eq 1 ]; then
    ok "exactly one copy: $(basename "${copies[0]}")"
else
    bad "${#copies[@]} copies present -- the next VS Code start has stale ones to reclaim,"
    printf '         %s\n' "${copies[@]##*/}"
    echo "         and that reclaim can race the extension scan and lose the id."
fi

obsolete="$EXT_DIR/.obsolete"
if [ -s "$obsolete" ] && grep -q "$EXT_ID" "$obsolete" 2>/dev/null; then
    bad "$EXT_ID is queued for deletion in .obsolete:"
    sed 's/^/         /' "$obsolete"; echo
    echo "         Quit VS Code completely, then re-run this script."
else
    ok ".obsolete has nothing queued for this extension"
fi

# --- 2. registry agrees with disk ----------------------------------------
echo
echo "2. VS Code's installed-extensions record"
if command -v python3 >/dev/null 2>&1 && [ -f "$EXT_DIR/extensions.json" ]; then
    python3 - "$EXT_DIR/extensions.json" "$EXT_ID" << 'PYEOF'
import json, sys, os
path, ext_id = sys.argv[1], sys.argv[2]
entries = [e for e in json.load(open(path))
           if e.get('identifier', {}).get('id') == ext_id]
if not entries:
    print(f"  [FAIL] {ext_id} is not in extensions.json")
    sys.exit(3)
if len(entries) > 1:
    print(f"  [FAIL] {ext_id} appears {len(entries)} times in extensions.json")
    sys.exit(3)
e = entries[0]
loc = (e.get('location') or {}).get('path')
print(f"  [ ok ] registered once, version {e.get('version')}")
if not loc or not os.path.isdir(loc):
    print(f"  [FAIL] its recorded location does not exist: {loc}")
    sys.exit(3)
print(f"  [ ok ] recorded location exists: {loc}")
PYEOF
    [ $? -ne 0 ] && fail=$((fail+1))
else
    note "python3 or extensions.json missing -- skipped"
fi

# --- 3. installed version matches the .vsix here -------------------------
echo
echo "3. Installed version vs the .vsix in this folder"
shopt -s nullglob
vsix=("$HERE"/brief-slickedit-helpers-*.vsix)
shopt -u nullglob
if [ ${#vsix[@]} -ne 1 ]; then
    note "expected exactly one brief-slickedit-helpers-*.vsix here, found ${#vsix[@]}"
else
    want="$(basename "${vsix[0]}")"; want="${want#brief-slickedit-helpers-}"; want="${want%.vsix}"
    have="$(code --list-extensions --show-versions 2>/dev/null | sed -n "s/^$EXT_ID@//p")"
    if [ -z "$have" ]; then
        bad "code --list-extensions doesn't show $EXT_ID"
    elif [ "$have" = "$want" ]; then
        ok "installed $have matches $want"
    else
        bad "installed $have but this folder ships $want -- re-run install.sh"
    fi
fi

# --- 4. keybindings in place ---------------------------------------------
echo
echo "4. keybindings.json"
if [ ! -f "$USER_DIR/keybindings.json" ]; then
    bad "$USER_DIR/keybindings.json is missing"
elif diff -q "$HERE/keybindings.json" "$USER_DIR/keybindings.json" >/dev/null 2>&1; then
    ok "matches the copy in this folder"
else
    note "differs from the copy in this folder (fine if you edited it deliberately)"
fi

# --- 5. keybindings.json only names commands the extension provides -------
# keybindings.json and the .vsix are a matched pair. keybindings.json names
# briefHelpers.* commands and that list grows -- 0.0.4 added thirteen
# briefHelpers.column* ones -- so an ACTIVE keybindings.json newer than the
# INSTALLED extension makes exactly those keys fail with "command
# 'briefHelpers.x' not found". That is the same symptom as the stale-copy
# failure in section 1 from an entirely different cause, which is why both are
# worth checking before anything gets diagnosed from scratch again.
#
# This deliberately checks the ACTIVE file in the VS Code user folder, not the
# copy in this folder: the active one is what the editor actually loads, and
# therefore what breaks.
echo
echo "5. Commands used by the active keybindings.json"
PARITY_FAIL=0
if ! command -v python3 >/dev/null 2>&1; then
    note "python3 missing -- skipped"
elif [ ! -f "$USER_DIR/keybindings.json" ]; then
    note "no active keybindings.json -- skipped"
elif [ ${#copies[@]} -ne 1 ]; then
    note "needs exactly one installed copy -- skipped"
else
    if python3 - "$USER_DIR/keybindings.json" "${copies[0]}/package.json" << 'PARITYEOF'
import json, re, sys

keybindings_path, manifest_path = sys.argv[1], sys.argv[2]

# keybindings.json is JSONC; the command ids are all that's needed here, so
# pull them with a regex rather than parsing around comments and trailing
# commas. The optional leading "-" is VS Code's "remove this binding" form.
raw = open(keybindings_path, encoding="utf-8").read()
used = set(re.findall(r'"-?(briefHelpers\.[A-Za-z]+)"', raw))

manifest = json.load(open(manifest_path, encoding="utf-8"))
provided = {c["command"] for c in manifest.get("contributes", {}).get("commands", [])}

missing = sorted(used - provided)
if missing:
    print("  [FAIL] the active keybindings.json uses %d command(s) that installed"
          % len(missing))
    print("         version %s does not provide:" % manifest.get("version"))
    for command in missing:
        print("           " + command)
    print("         Those keys fail with \"command not found\".")
    sys.exit(3)
print("  [ ok ] all %d briefHelpers commands used are provided by %s"
      % (len(used), manifest.get("version")))
PARITYEOF
    then
        :
    else
        fail=$((fail+1))
        PARITY_FAIL=1
    fi
fi

# --- 6. font -------------------------------------------------------------
echo
echo "6. Font"
if ! command -v fc-match >/dev/null 2>&1; then
    note "fontconfig not installed -- can't check"
elif [ "$(fc-match -f '%{family[0]}' "$FONT_FAMILY" 2>/dev/null)" = "$FONT_FAMILY" ]; then
    ok "\"$FONT_FAMILY\" resolves exactly"
else
    bad "\"$FONT_FAMILY\" does not resolve -- VS Code is silently substituting a font."
    echo "         Run install.sh, or: cp fonts/CascadiaCode*.ttf ~/.local/share/fonts/ && fc-cache -f"
fi

# --- repair --------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    if [ "$warn" -gt 0 ]; then
        echo "All good ($warn warning(s) above)."
    else
        echo "All good."
    fi
    exit 0
fi

echo "$fail problem(s) found."
if [ "$FIX" -eq 0 ]; then
    echo "Re-run with --fix to repair, or do it by hand:"
    echo "  1. Quit VS Code completely (every window)."
    echo "  2. cd $HERE && bash install.sh"
    echo "     (installs the .vsix AND its matching keybindings.json -- they are a pair)"
    echo "  3. Start VS Code."
    echo ""
    echo "Or, for the extension alone:"
    echo "  code --install-extension $HERE/brief-slickedit-helpers-*.vsix --force"
    echo "  rm -f \"\$HOME/.config/Code/CachedProfilesData/__default__profile__/extensions.user.cache\""
    exit 1
fi

echo
echo "--fix: repairing."
if pgrep -f "code.*--type=renderer" >/dev/null 2>&1; then
    echo "  VS Code is RUNNING. Repairing now would recreate the exact situation that"
    echo "  caused the original failure -- a stale copy left on disk for a later"
    echo "  startup to reclaim while it scans. Quit VS Code completely, then re-run"
    echo "  'bash check-install.sh --fix'." >&2
    exit 1
fi
shopt -s nullglob
vsix=("$HERE"/brief-slickedit-helpers-*.vsix)
shopt -u nullglob
if [ ${#vsix[@]} -ne 1 ]; then
    echo "  Need exactly one brief-slickedit-helpers-*.vsix here to reinstall from." >&2
    exit 1
fi
code --install-extension "${vsix[0]}" --force || { echo "  reinstall failed" >&2; exit 1; }
# Regenerable cache. Clearing it forces a clean scan of a now-single-copy dir.
rm -f "$HOME/.config/Code/CachedProfilesData/__default__profile__/extensions.user.cache"
echo "  Reinstalled and cleared the extension scan cache."

# Reinstalling the .vsix cannot fix a stale ACTIVE keybindings.json, so section
# 5 gets its own repair. Only done when section 5 actually failed: section 4
# reports a mere difference as a warning, and overwriting a file you edited on
# purpose would be worse than the problem.
if [ "$PARITY_FAIL" -eq 1 ]; then
    if [ -f "$USER_DIR/keybindings.json" ]; then
        cp "$USER_DIR/keybindings.json" "$USER_DIR/keybindings.json.bak"
        echo "  Backed up the active keybindings.json to keybindings.json.bak"
    fi
    cp "$HERE/keybindings.json" "$USER_DIR/keybindings.json"
    echo "  Installed the matching keybindings.json (it pairs with the .vsix)."
fi

echo "  Start VS Code and re-run 'bash check-install.sh' to confirm."
