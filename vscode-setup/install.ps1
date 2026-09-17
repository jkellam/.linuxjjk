# SlickEdit Brief-emulation parity setup for VS Code -- Windows
# Run from PowerShell in this same folder (vscode-setup), or with a full path:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Assumes: VS Code is installed and `code` is on PATH (if not, open VS Code
# once, Ctrl+Shift+P -> "Shell Command: Install 'code' command in PATH").

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Installing the helper extension while VS Code is RUNNING is what caused the
# 2026-08-19 outage on the Linux box: a running VS Code holds the old
# version's directory open, so the install can only mark it for deletion. VS
# Code reclaims it at a later startup -- and that startup deletes the stale
# directories AND builds the extension registry ~450ms apart. Scanning a
# directory holding several copies of one extension id while two are deleted
# underneath dropped the id from the registry, silently: the commands simply
# did not exist, with nothing in any log. See "Stale extension copies" in
# setting-up-vscode.md.
#
# Closing VS Code first shortens that window but does NOT remove it: measured
# 2026-08-20 on Linux, a CLI install with nothing running still only MARKED the
# old version for removal, and the next VS Code startup was what deleted it --
# the same delete-while-scanning window. So the real protection is steps 6 and
# 7 below, run after every install. Refusing while VS Code is open is worth
# doing anyway, since a running instance guarantees the stale directory sticks
# around.
$running = @(Get-Process -Name "Code", "Code - Insiders" -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host "VS Code is currently RUNNING." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Installing now leaves the previous version's directory on disk for a later" -ForegroundColor Yellow
    Write-Host "startup to reclaim, which can silently drop the extension from VS Code's" -ForegroundColor Yellow
    Write-Host "registry -- its keybindings then fail with `"command not found`" and nothing" -ForegroundColor Yellow
    Write-Host "is written to any log. Quit VS Code completely (every window) and re-run." -ForegroundColor Yellow
    Write-Host ""
    if ([Environment]::UserInteractive) {
        $reply = Read-Host "Continue anyway? [y/N]"
        if ($reply -notmatch '^[yY]') {
            Write-Host "Stopped." -ForegroundColor Red
            exit 1
        }
        Write-Host "Continuing -- check the step 6/7 output below carefully." -ForegroundColor Yellow
    } else {
        Write-Host "Not an interactive session, so not asking -- stopping." -ForegroundColor Red
        Write-Host "Re-run with VS Code closed." -ForegroundColor Red
        exit 1
    }
}

# code --install-extension is a native command -- $ErrorActionPreference
# does NOT stop the script on a non-zero exit code from it, so a failed
# install here would otherwise go unnoticed and the script would carry on
# to overwrite keybindings.json against an environment missing the
# extension it depends on. Check explicitly and abort loudly instead.
function Install-CheckedExtension($idOrPath, $expectedId, $label) {
    Write-Host "Installing $label..."
    code --install-extension $idOrPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "FAILED to install $label (exit code $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "Stopping here -- keybindings.json depends on this extension being present." -ForegroundColor Red
        Write-Host "If this was the Marketplace install, common causes: no internet, or you're" -ForegroundColor Red
        Write-Host "running 'Code - OSS' (many Linux-packaged builds) rather than the Microsoft" -ForegroundColor Red
        Write-Host "build, which has no Marketplace access by default." -ForegroundColor Red
        exit 1
    }
    $installed = code --list-extensions
    if ($installed -notcontains $expectedId) {
        Write-Host ""
        Write-Host "$label reported success but doesn't show up in 'code --list-extensions'." -ForegroundColor Red
        Write-Host "Stopping here -- verify manually before re-running." -ForegroundColor Red
        exit 1
    }
}

Install-CheckedExtension "rkdawenterprises.brief4vscode" "rkdawenterprises.brief4vscode" "1. brief4vscode (Brief Editor Keymap Emulation) from the Marketplace"
# Globbed rather than hardcoded so bumping the helper extension's version
# doesn't require editing this script. Refuses to guess if there's more than
# one -- an old .vsix left lying around next to a new one would otherwise be
# a coin flip.
$helperVsix = @(Get-ChildItem -Path (Join-Path $here "brief-slickedit-helpers-*.vsix") -ErrorAction SilentlyContinue)
if ($helperVsix.Count -eq 0) {
    Write-Host "No brief-slickedit-helpers-*.vsix found in $here." -ForegroundColor Red
    exit 1
}
if ($helperVsix.Count -gt 1) {
    Write-Host "More than one brief-slickedit-helpers-*.vsix in ${here}:" -ForegroundColor Red
    $helperVsix | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Red }
    Write-Host "Remove the stale one(s) and re-run." -ForegroundColor Red
    exit 1
}
Install-CheckedExtension $helperVsix[0].FullName "local.brief-slickedit-helpers" "2. the local Brief/SlickEdit Parity Helpers extension"

$userDir = "$env:APPDATA\Code\User"
New-Item -ItemType Directory -Force -Path $userDir | Out-Null

Write-Host "3. Installing keybindings.json (backing up any existing one to .bak)..."
$kb = "$userDir\keybindings.json"
if (Test-Path $kb) {
    Copy-Item $kb "$kb.bak" -Force
    Write-Host "   existing keybindings.json backed up to keybindings.json.bak"
}
Copy-Item "$here\keybindings.json" $kb -Force

Write-Host "4. Merging font settings into settings.json..."
$settingsPath = "$userDir\settings.json"
$fragment = Get-Content "$here\settings-fragment.json" -Raw | ConvertFrom-Json
$mergedOk = $false
try {
    if (Test-Path $settingsPath) {
        Copy-Item $settingsPath "$settingsPath.bak" -Force
        $existingRaw = Get-Content $settingsPath -Raw
        if ([string]::IsNullOrWhiteSpace($existingRaw)) {
            $existing = New-Object PSObject
        } else {
            # Strict JSON parse -- fails if the file has // comments (VS Code
            # settings.json is JSONC and can legally contain them).
            $existing = $existingRaw | ConvertFrom-Json
        }
    } else {
        $existing = New-Object PSObject
    }
    foreach ($prop in $fragment.PSObject.Properties) {
        $existing | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
    $mergedOk = $true
} catch {
    Write-Host "   Automatic merge failed (likely // comments in settings.json, which"
    Write-Host "   ConvertFrom-Json can't parse). Add these two lines by hand instead:"
    Write-Host "     `"editor.fontFamily`": `"Cascadia Code`","
    Write-Host "     `"editor.fontSize`": 15"
    Write-Host "   into $settingsPath"
}

# ---------------------------------------------------------------------------
# 5. Cascadia Code font.
#
# Not cosmetic. editor.fontFamily is deliberately the single family "Cascadia
# Code" rather than a fallback stack, because a glyph that renders wider than
# one cell throws off VS Code's pixel-based cursor math -- see the debugging
# history in setting-up-vscode.md. If the family is missing, VS Code silently
# substitutes something else and that whole bug comes straight back.
$fontFamily = "Cascadia Code"
$fontWarning = ""

function Test-CascadiaCode {
    # The same trap as on Linux, in Windows clothing: "Cascadia Code PL",
    # "Cascadia Code NF" and the entire "Cascadia Mono" family are DIFFERENT
    # families that all contain the string "Cascadia Code" or "Cascadia", so a
    # wildcard match reports success while the family editor.fontFamily
    # actually names is absent. Match the family name exactly, allowing only a
    # trailing weight/style word that Windows appends per face.
    $exact = '^Cascadia Code( (Regular|Italic|Light|SemiLight|SemiBold|Bold|ExtraLight))?$'
    foreach ($hive in @("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts",
                        "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts")) {
        if (-not (Test-Path $hive)) { continue }
        foreach ($prop in (Get-ItemProperty $hive).PSObject.Properties) {
            $name = $prop.Name -replace ' \((TrueType|OpenType)\)$', ''
            if ($name -match $exact) { return $true }
        }
    }
    # Second signal: the actual file, under either the system or per-user dir.
    foreach ($dir in @("$env:WINDIR\Fonts", "$env:LOCALAPPDATA\Microsoft\Windows\Fonts")) {
        if (Test-Path (Join-Path $dir "CascadiaCode.ttf")) { return $true }
    }
    return $false
}

function Install-CascadiaCode {
    # Per-user install: NO administrator rights needed. Copy into the per-user
    # font directory and register under HKCU. System-wide would be
    # C:\Windows\Fonts plus HKLM, which does require elevation.
    $staged = @(Get-ChildItem -Path (Join-Path $here "fonts\CascadiaCode*.ttf") -ErrorAction SilentlyContinue)
    if ($staged.Count -gt 0) {
        $dest = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $key = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        foreach ($file in $staged) {
            $target = Join-Path $dest $file.Name
            Copy-Item $file.FullName $target -Force
            $regName = if ($file.Name -like "*Italic*") { "Cascadia Code Italic (TrueType)" }
                       else { "Cascadia Code (TrueType)" }
            New-ItemProperty -Path $key -Name $regName -Value $target -PropertyType String -Force | Out-Null
        }
        Write-Host "   Installed $($staged.Count) file(s) from fonts\ into $dest (per-user, no admin)."
        Write-Host "   Newly registered fonts are picked up by applications started afterwards,"
        Write-Host "   so the VS Code restart below is what makes it take effect."
        return $true
    }
    # No bundled copies. winget is the documented Windows route; note it
    # installs system-wide and so may prompt for elevation.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "   No fonts\ folder here, so falling back to winget."
        Write-Host "   (winget installs system-wide and may prompt for elevation.)"
        winget install --id Microsoft.CascadiaCode --accept-source-agreements --accept-package-agreements
        return ($LASTEXITCODE -eq 0)
    }
    Write-Host "   No fonts\ folder here and winget is unavailable." -ForegroundColor Yellow
    return $false
}

Write-Host "5. Checking the Cascadia Code font..."
if (Test-CascadiaCode) {
    Write-Host "   Already installed -- `"$fontFamily`" is registered. Nothing to do."
} else {
    Write-Host "   `"$fontFamily`" is NOT installed. (Careful: the Cascadia Mono and"
    Write-Host "   Cascadia Code PL/NF families do not satisfy it -- see the comment above.)"
    if (Install-CascadiaCode) {
        Write-Host "   Done."
    } else {
        $fontWarning = "Cascadia Code could not be installed automatically."
    }
}

# Verify the install didn't leave a stale copy behind -- the precondition for
# the failure described in the preflight comment at the top. Cheap to check,
# and the symptom is invisible until a keybinding mysteriously stops working.
Write-Host "6. Verifying no stale copies of the helper extension were left behind..."
$extRoot = "$env:USERPROFILE\.vscode\extensions"
$copies = @(Get-ChildItem -Path (Join-Path $extRoot "local.brief-slickedit-helpers-*") -Directory -ErrorAction SilentlyContinue)
$stale = $false
if ($copies.Count -gt 1) {
    Write-Host "   $($copies.Count) copies are on disk:" -ForegroundColor Red
    $copies | ForEach-Object { Write-Host "     $($_.Name)" -ForegroundColor Red }
    $stale = $true
}
$obsolete = Join-Path $extRoot ".obsolete"
if ((Test-Path $obsolete) -and ((Get-Content $obsolete -Raw) -match 'local\.brief-slickedit-helpers')) {
    Write-Host "   A copy is queued for deletion in .obsolete." -ForegroundColor Red
    $stale = $true
}
if ($stale) {
    Write-Host "   Quit VS Code completely and re-run this script." -ForegroundColor Red
    Write-Host "   Otherwise the next start may lose the extension (see comment at top)." -ForegroundColor Red
} else {
    Write-Host "   Clean -- exactly one copy, nothing queued for deletion."
}

# keybindings.json references briefHelpers.* commands, and that list grows:
# 0.0.4 added thirteen briefHelpers.column* commands. Pairing a newer
# keybindings.json with an older .vsix therefore produces exactly the
# "command 'briefHelpers.x' not found" symptom that cost a morning on
# 2026-08-19 -- from a completely different cause, which is what makes it
# worth ruling out here rather than diagnosing again from scratch later.
Write-Host "7. Verifying keybindings.json only uses commands this extension provides..."
if ($copies.Count -eq 1) {
    # keybindings.json is JSONC; the command ids are all that's needed here, so
    # pull them with a regex rather than parsing around comments and trailing
    # commas. The optional leading "-" is VS Code's "remove this binding" form.
    $raw = Get-Content (Join-Path $here "keybindings.json") -Raw
    $used = [regex]::Matches($raw, '"-?(briefHelpers\.[A-Za-z]+)"') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $manifest = Get-Content (Join-Path $copies[0].FullName "package.json") -Raw | ConvertFrom-Json
    $provided = @($manifest.contributes.commands | ForEach-Object { $_.command })
    $missing = @($used | Where-Object { $provided -notcontains $_ })
    if ($missing.Count -gt 0) {
        Write-Host "   keybindings.json references commands the installed extension" -ForegroundColor Red
        Write-Host "   (version $($manifest.version)) does not provide:" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
        Write-Host "   Those keys would fail with `"command not found`". The .vsix and" -ForegroundColor Red
        Write-Host "   keybindings.json in this folder are out of step; they ship together." -ForegroundColor Red
        $stale = $true
    } else {
        Write-Host "   OK -- all $($used.Count) briefHelpers commands used are provided by $($manifest.version)."
    }
} else {
    Write-Host "   Skipped (needs exactly one installed copy)."
}

Write-Host ""
Write-Host "Done. Still to do by hand:"
Write-Host " - Restart VS Code fully (not just Reload Window) so the new extension registers cleanly."
Write-Host " - Read setting-up-vscode.md for the full context and open items."
Write-Host " - The health checker (check-install.sh) and the extension's tests"
Write-Host "   (source/test/run-tests.sh) are bash; on Windows use Git Bash / WSL, or"
Write-Host "   check by hand that $extRoot has exactly one"
Write-Host "   local.brief-slickedit-helpers-* folder and that .obsolete names none."

if ($fontWarning -ne "") {
    Write-Host ""
    Write-Host "WARNING: $fontWarning" -ForegroundColor Red
    Write-Host "Everything else IS installed -- extensions, keybindings.json and the font" -ForegroundColor Red
    Write-Host "settings are all in place. But editor.fontFamily now names a font this" -ForegroundColor Red
    Write-Host "machine doesn't have, so VS Code will silently substitute another one." -ForegroundColor Red
    Write-Host "Fix it with:  winget install --id Microsoft.CascadiaCode" -ForegroundColor Red
    Write-Host "or download from https://github.com/microsoft/cascadia-code/releases and" -ForegroundColor Red
    Write-Host "install ttf\CascadiaCode.ttf (right-click -> Install)." -ForegroundColor Red
    exit 1
}
if ($stale) {
    exit 1
}
