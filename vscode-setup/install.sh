#!/usr/bin/env bash
# SlickEdit Brief-emulation parity setup for VS Code -- Linux (and Mac, with
# the USER_DIR line below adjusted -- see comment).
#
# Usage: cd into this folder (vscode-setup) and run:  bash install.sh
#
# Assumes: VS Code is installed and `code` is on PATH (if not, open VS Code
# once, Ctrl+Shift+P -> "Shell Command: Install 'code' command in PATH").

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Linux: ~/.config/Code/User
# Mac:   ~/Library/Application Support/Code/User  (uncomment the line below, comment out the Linux one)
USER_DIR="$HOME/.config/Code/User"
# USER_DIR="$HOME/Library/Application Support/Code/User"

# Installing the helper extension while VS Code is RUNNING is what caused the
# 2026-08-19 outage: a running VS Code holds the old version's directory open,
# so the install can only mark it for deletion. VS Code reclaims it at a later
# startup -- and that startup deletes the stale directories AND builds the
# extension registry ~450ms apart. Scanning a directory holding several copies
# of one extension id while two are deleted underneath dropped the id from the
# registry, silently: the commands simply didn't exist, with nothing in any log.
# See "Stale extension copies" in setting-up-vscode.md.
#
# Closing VS Code first shortens that window but does NOT remove it: measured
# 2026-08-20, a CLI install with nothing running still only MARKED the old
# version for removal, and the next VS Code startup was what deleted it -- the
# same delete-while-scanning window. So the real protection is steps 6 and 7
# below, run after every install. Refusing while VS Code is open is worth doing
# anyway, since a running instance guarantees the stale directory sticks around.
if pgrep -f "code.*--type=renderer" >/dev/null 2>&1; then
    echo "VS Code is currently RUNNING." >&2
    echo "" >&2
    echo "Installing now leaves the previous version's directory on disk for a later" >&2
    echo "startup to reclaim, which can silently drop the extension from VS Code's" >&2
    echo "registry -- its keybindings then fail with \"command not found\" and nothing" >&2
    echo "is written to any log. Quit VS Code completely (every window) and re-run." >&2
    echo "" >&2
    if [ -t 0 ]; then
        printf "Continue anyway? [y/N] " >&2
        read -r reply
        case "$reply" in
            [yY]*) echo "Continuing -- run 'bash check-install.sh' afterwards." >&2 ;;
            *)     echo "Stopped." >&2; exit 1 ;;
        esac
    else
        echo "Not a terminal, so not asking -- stopping. Re-run with VS Code closed." >&2
        exit 1
    fi
fi

# `set -e` stops the script if `code --install-extension` itself returns
# non-zero, but it can still report success without the extension actually
# showing up (seen this with flaky Marketplace connections) -- so verify
# with --list-extensions too rather than trusting the exit code alone.
install_checked_extension() {
    local id_or_path="$1" expected_id="$2" label="$3"
    echo "Installing $label..."
    if ! code --install-extension "$id_or_path"; then
        echo ""
        echo "FAILED to install $label." >&2
        echo "Stopping here -- keybindings.json depends on this extension being present." >&2
        echo "If this was the Marketplace install, common causes: no internet, or you're" >&2
        echo "running 'Code - OSS' (many Linux-packaged builds) rather than the Microsoft" >&2
        echo "build, which has no Marketplace access by default." >&2
        exit 1
    fi
    if ! code --list-extensions | grep -qix "$expected_id"; then
        echo ""
        echo "$label reported success but doesn't show up in 'code --list-extensions'." >&2
        echo "Stopping here -- verify manually before re-running." >&2
        exit 1
    fi
}

# curl or wget, whichever this machine has. Progress is left visible: the font
# archive further down is 150 MB and a silent multi-minute stall looks hung.
fetch_stdout() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"; else wget -qO- "$1"; fi
}
fetch_file() {
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar "$1" -o "$2"
    else
        wget -q --show-progress -O "$2" "$1"
    fi
}

install_checked_extension "rkdawenterprises.brief4vscode" "rkdawenterprises.brief4vscode" "1. brief4vscode (Brief Editor Keymap Emulation) from the Marketplace"
# Globbed rather than hardcoded so bumping the helper extension's version
# doesn't require editing this script. Refuses to guess if there's more than
# one -- an old .vsix left lying around next to a new one would otherwise be
# a coin flip.
shopt -s nullglob
HELPER_VSIX=("$HERE"/brief-slickedit-helpers-*.vsix)
shopt -u nullglob
if [ ${#HELPER_VSIX[@]} -eq 0 ]; then
    echo "No brief-slickedit-helpers-*.vsix found in $HERE." >&2
    exit 1
fi
if [ ${#HELPER_VSIX[@]} -gt 1 ]; then
    echo "More than one brief-slickedit-helpers-*.vsix in $HERE:" >&2
    printf '  %s\n' "${HELPER_VSIX[@]}" >&2
    echo "Remove the stale one(s) and re-run." >&2
    exit 1
fi
install_checked_extension "${HELPER_VSIX[0]}" "local.brief-slickedit-helpers" "2. the local Brief/SlickEdit Parity Helpers extension"

mkdir -p "$USER_DIR"

echo "3. Installing keybindings.json (backing up any existing one to .bak)..."
if [ -f "$USER_DIR/keybindings.json" ]; then
    cp "$USER_DIR/keybindings.json" "$USER_DIR/keybindings.json.bak"
    echo "   existing keybindings.json backed up to keybindings.json.bak"
fi
cp "$HERE/keybindings.json" "$USER_DIR/keybindings.json"

echo "4. Merging font settings into settings.json..."
if [ -f "$USER_DIR/settings.json" ]; then
    cp "$USER_DIR/settings.json" "$USER_DIR/settings.json.bak"
fi
if command -v python3 >/dev/null 2>&1; then
    python3 - "$USER_DIR/settings.json" "$HERE/settings-fragment.json" << 'PYEOF'
import json, sys, os

settings_path, fragment_path = sys.argv[1], sys.argv[2]
fragment = json.load(open(fragment_path, encoding="utf-8"))

existing = {}
if os.path.exists(settings_path):
    raw = open(settings_path, encoding="utf-8").read().strip()
    if raw:
        try:
            # Strict JSON parse -- fails if the file has // comments (VS Code
            # settings.json is JSONC and can legally contain them).
            existing = json.loads(raw)
        except json.JSONDecodeError:
            print("   Automatic merge failed (likely // comments in settings.json,")
            print("   which strict JSON can't parse). Add these two lines by hand instead:")
            print('     "editor.fontFamily": "Cascadia Code",')
            print('     "editor.fontSize": 15')
            print(f"   into {settings_path}")
            sys.exit(0)

existing.update(fragment)
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(existing, f, indent=4)
    f.write("\n")
PYEOF
elif command -v jq >/dev/null 2>&1; then
    if [ -f "$USER_DIR/settings.json" ] && [ -s "$USER_DIR/settings.json" ]; then
        jq -s '.[0] * .[1]' "$USER_DIR/settings.json" "$HERE/settings-fragment.json" > "$USER_DIR/settings.json.tmp"
    else
        cp "$HERE/settings-fragment.json" "$USER_DIR/settings.json.tmp"
    fi
    mv "$USER_DIR/settings.json.tmp" "$USER_DIR/settings.json"
else
    echo "   Neither python3 nor jq found -- merge settings-fragment.json into"
    echo "   $USER_DIR/settings.json by hand:"
    cat "$HERE/settings-fragment.json"
fi

# ---------------------------------------------------------------------------
# 5. Cascadia Code font.
#
# Not cosmetic. editor.fontFamily is deliberately the single family "Cascadia
# Code" rather than a fallback stack, because a glyph that renders wider than
# one cell throws off VS Code's pixel-based cursor math -- see the debugging
# history in setting-up-vscode.md. If the family is missing, VS Code silently
# substitutes something else and that whole bug comes straight back, which is
# exactly the failure this setup exists to prevent.
#
# Two traps worth spelling out, both hit for real on Mint:
#
#   - `apt install fonts-cascadia-code` is NOT sufficient. That package ships
#     families named "Cascadia Mono" and "Cascadia Mono PL". Neither one is
#     "Cascadia Code", so editor.fontFamily stays unmatched while it looks like
#     the font is installed.
#
#   - `fc-list | grep -i "cascadia code"` is NOT a valid test. "Cascadia Code
#     PL" and "Cascadia Code NF" are separate families that both contain that
#     string, so a substring match reports success while the family VS Code
#     actually wants is absent. The name has to match exactly.
#
# fc-match always resolves to *something* -- hand it an unknown family and it
# returns the system default -- so asking what "Cascadia Code" resolves to and
# checking the answer is literally "Cascadia Code" is an exact test with no
# substring problem.
#
# No sudo for the font itself: it goes in the per-user font directory. sudo is
# only reached for if a helper tool (fontconfig, curl/wget, unzip) is missing,
# and you're told before it prompts.
FONT_FAMILY="Cascadia Code"
FONT_DIR="$HOME/.local/share/fonts"
FONT_WARNING=""

have_cascadia_code() {
    command -v fc-match >/dev/null 2>&1 || return 1
    [ "$(fc-match -f '%{family[0]}' "$FONT_FAMILY" 2>/dev/null)" = "$FONT_FAMILY" ]
}

# Only ever called for genuinely missing tooling, never for the font.
apt_install_with_sudo() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "   Missing: $*. No apt-get on this machine -- install with your own" >&2
        echo "   package manager and re-run." >&2
        return 1
    fi
    echo "   Missing: $*. Installing these needs sudo, so you'll be prompted for"
    echo "   your password now (nothing else in this script uses sudo)."
    sudo apt-get install -y "$@"
}

register_fonts() {
    command -v fc-cache >/dev/null 2>&1 || apt_install_with_sudo fontconfig || return 1
    fc-cache -f "$FONT_DIR" >/dev/null 2>&1 || true
    have_cascadia_code
}

install_cascadia_code() {
    local tmp url found=0 name src dl=()

    # Preferred path: the two .ttf files bundled in fonts/ next to this script.
    # Worth keeping them there -- see the download path below for why.
    shopt -s nullglob
    local staged=("$HERE"/fonts/CascadiaCode*.ttf)
    shopt -u nullglob
    if [ ${#staged[@]} -gt 0 ]; then
        echo "   Installing the bundled copies from $HERE/fonts/"
        mkdir -p "$FONT_DIR"
        cp "${staged[@]}" "$FONT_DIR/"
        register_fonts
        return
    fi

    # Fallback: fetch from the official release. Note this is a 150 MB
    # download for two ~740 KB files -- upstream publishes exactly one release
    # asset containing otf + ttf + woff2 + every static instance, and there's
    # no lighter one. Which is precisely why fonts/ exists; if this machine is
    # offline or on a slow link, copy the two .ttf files there instead.
    command -v unzip >/dev/null 2>&1 || dl+=(unzip)
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        dl+=(curl)
    fi
    if [ ${#dl[@]} -gt 0 ]; then
        apt_install_with_sudo "${dl[@]}" || return 1
    fi

    # GitHub has no stable "latest asset" URL -- the filename carries the
    # version -- so the release API has to be asked. Parsed with grep rather
    # than python3/jq so this still works where neither is installed.
    echo "   Looking up the latest release on github.com/microsoft/cascadia-code..."
    url="$(fetch_stdout https://api.github.com/repos/microsoft/cascadia-code/releases/latest \
           | grep -oE 'https://[^"]*/CascadiaCode-[0-9.]+\.zip' | head -1)"
    if [ -z "$url" ]; then
        echo "   No CascadiaCode-*.zip in the latest release -- no network, GitHub API" >&2
        echo "   rate limit, or the release layout changed." >&2
        return 1
    fi

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    echo "   Downloading $(basename "$url") -- 150 MB, this will take a while."
    fetch_file "$url" "$tmp/cascadia.zip" || { echo "   Download failed." >&2; return 1; }

    # Selective extraction: pulling only these two out of the archive avoids
    # writing ~500 MB of otf/woff2/static instances to disk for no reason.
    # `|| true` because unzip exits 11 when a pattern matches nothing, which
    # the found check below reports far more clearly.
    unzip -qo "$tmp/cascadia.zip" '*CascadiaCode.ttf' '*CascadiaCodeItalic.ttf' -d "$tmp/x" || true
    mkdir -p "$FONT_DIR"
    for name in CascadiaCode.ttf CascadiaCodeItalic.ttf; do
        src="$(find "$tmp/x" -name "$name" -print -quit 2>/dev/null || true)"
        if [ -n "$src" ]; then
            cp "$src" "$FONT_DIR/"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "   Downloaded the archive but found no CascadiaCode.ttf inside it." >&2
        return 1
    fi
    echo "   Installed into $FONT_DIR"
    register_fonts
}

echo "5. Checking the Cascadia Code font..."
if [ "$(uname)" = "Darwin" ]; then
    # macOS has no fontconfig, so there's no way to verify the result the way
    # fc-match does on Linux -- left manual rather than done blind.
    echo "   macOS: if Cascadia Code isn't installed already, get it from"
    echo "   https://github.com/microsoft/cascadia-code/releases and open the .ttf"
    echo "   files in Font Book (or copy them into ~/Library/Fonts)."
elif ! command -v fc-match >/dev/null 2>&1 && ! apt_install_with_sudo fontconfig; then
    FONT_WARNING="fontconfig is missing, so the Cascadia Code font could not be checked."
elif have_cascadia_code; then
    echo "   Already installed -- \"$FONT_FAMILY\" resolves exactly. Nothing to do."
else
    echo "   \"$FONT_FAMILY\" is NOT installed. (Careful: fonts-cascadia-code from"
    echo "   apt does not satisfy this -- it provides Cascadia Mono, a different"
    echo "   family. See the comment above.)"
    if install_cascadia_code; then
        echo "   Done -- \"$FONT_FAMILY\" now resolves exactly."
    else
        FONT_WARNING="Cascadia Code could not be installed automatically."
    fi
fi

# Verify the install didn't leave a stale copy behind -- the precondition for
# the failure described at the top of this script. Cheap to check, and the
# symptom is invisible until a keybinding mysteriously stops working.
echo "6. Verifying no stale copies of the helper extension were left behind..."
shopt -s nullglob
HELPER_COPIES=("$HOME/.vscode/extensions/local.brief-slickedit-helpers"-*)
shopt -u nullglob
STALE=0
if [ ${#HELPER_COPIES[@]} -gt 1 ]; then
    echo "   ${#HELPER_COPIES[@]} copies are on disk:" >&2
    printf '     %s\n' "${HELPER_COPIES[@]##*/}" >&2
    STALE=1
fi
if [ -s "$HOME/.vscode/extensions/.obsolete" ] \
   && grep -q "local.brief-slickedit-helpers" "$HOME/.vscode/extensions/.obsolete" 2>/dev/null; then
    echo "   A copy is queued for deletion in .obsolete." >&2
    STALE=1
fi
if [ "$STALE" -eq 1 ]; then
    echo "   Quit VS Code completely, then run:  bash check-install.sh --fix" >&2
    echo "   Otherwise the next start may lose the extension (see comment at top)." >&2
else
    echo "   Clean -- exactly one copy, nothing queued for deletion."
fi

# keybindings.json references briefHelpers.* commands, and that list grows:
# 0.0.4 added thirteen briefHelpers.column* commands. Pairing a newer
# keybindings.json with an older .vsix therefore produces exactly the
# "command 'briefHelpers.x' not found" symptom that cost a morning on
# 2026-08-19 -- from a completely different cause, which is what makes it
# worth ruling out here rather than diagnosing again from scratch later.
echo "7. Verifying keybindings.json only uses commands this extension provides..."
if command -v python3 >/dev/null 2>&1 && [ ${#HELPER_COPIES[@]} -eq 1 ]; then
    if ! python3 - "$HERE/keybindings.json" "${HELPER_COPIES[0]}/package.json" << 'PARITYEOF'
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
    print("   keybindings.json references commands the installed extension")
    print("   (version %s) does not provide:" % manifest.get("version"))
    for command in missing:
        print("     " + command)
    print("   Those keys would fail with \"command not found\". The .vsix and")
    print("   keybindings.json in this folder are out of step; they ship together.")
    sys.exit(3)
print("   OK -- all %d briefHelpers commands used are provided by %s."
      % (len(used), manifest.get("version")))
PARITYEOF
    then
        STALE=1
    fi
else
    echo "   Skipped (needs python3 and exactly one installed copy)."
fi

echo ""
echo "Done. Still to do by hand:"
echo " - Restart VS Code fully (not just Reload Window) so the new extension registers cleanly."
echo " - Read setting-up-vscode.md for the full context and open items."
echo " - If a keybinding ever stops working, run:  bash check-install.sh"
echo " - To test the extension without VS Code: bash source/test/run-tests.sh"

if [ -n "$FONT_WARNING" ]; then
    echo ""
    echo "WARNING: $FONT_WARNING" >&2
    echo "Everything else IS installed -- extensions, keybindings.json and the font" >&2
    echo "settings are all in place. But editor.fontFamily now names a font this" >&2
    echo "machine doesn't have, so VS Code will silently substitute another one." >&2
    echo "Fix it by installing Cascadia Code from" >&2
    echo "  https://github.com/microsoft/cascadia-code/releases" >&2
    echo "unzipping it, copying ttf/CascadiaCode.ttf into $FONT_DIR," >&2
    echo "and running: fc-cache -f \"$FONT_DIR\"" >&2
    echo "Verify with: fc-match -f '%{family[0]}' \"$FONT_FAMILY\"" >&2
    echo "(exiting non-zero so this isn't mistaken for a clean run)" >&2
    exit 1
fi
