# Setting up VS Code to match SlickEdit's Brief emulation

Continuation doc. If you're a fresh Claude session reading this: the user's
goal is to make VS Code behave like their SlickEdit setup, which runs in
Brief emulation mode. This has been an iterative, test-and-fix process —
read the "Debugging history" section before assuming anything is still
broken, and don't declare something "fixed" until the user confirms it.

## Where this lives

**`~/.linuxjjk/vscode-setup/` is the source of truth.** It travels as part of
the portable `~/.linuxjjk` directory — copy that one directory to a new machine
and this comes with it. `~/.linuxjjk/init` installs it (see "Recipe for a new
machine"), so on a fresh box there is nothing to do by hand.

Nothing here depends on that directory being named `.linuxjjk`: `install.sh`
and `check-install.sh` both derive their own location from `BASH_SOURCE`, so
the folder can be moved or renamed and the scripts keep working.

Older copies exist on a USB stick and at `~/vscode-setup/`. Those are stale
transport copies, **not** the source of truth — edit the one under
`~/.linuxjjk` and let it propagate with the rest of the directory.

## Current status

Working, as of the last confirmation from the user:
- Brief-style key bindings (bookmarks, marking modes, save/copy/cut, etc.)
- Deterministic Home/End (line -> window -> file, 3-tier, no scroll drift)
- Deterministic Up/Down (character-index goal column)
- Backspace "rubout" (stops at column 1, never joins previous line)
- ZapWhitespace (Ctrl+Z) — ported from the user's real SlickEdit macro,
  with the blank-line hang bug fixed (no-ops instead)
- WriteCommentBlock / WriteSectionSeparator / WriteFileHeader /
  WriteFunctionBlock (Alt+A, Alt+S, Ctrl+H, Alt+F) — ported from the user's
  real SlickEdit macros
- Font set to match SlickEdit's C/C++ source-window font (Cascadia Code,
  see "Font size units" below for why the point size doesn't transfer as-is)
- Alt+L line marking, both halves — confirmed by the user 2026-08-18,
  helpers 0.0.3:
  - Alt+L twice is a true no-op, caret back on its original line *and*
    column.
  - While the marked block is one line, the caret shows on the marked line
    (column 0) rather than at the start of the next line. Behind
    `"briefHelpers.reverseSingleLineMarkSelection"` (default true) since it's
    a taste call; set false for brief4vscode's original forward selection.
  See "Line marking caret (Alt+L)" for the mechanics of both, and for what
  is still approximate while marking is active.

Implemented but NOT yet confirmed by the user:
- Column marking (Alt+C) replaced wholesale, helpers 0.0.4, 2026-08-19. Fixes
  cut/copy acting on a different range than the one marked. See "Column
  marking" below. 21 headless tests pass (`bash source/test/run-tests.sh`),
  including the exact case from the screen recording.

  **Installed on the Mint box 2026-08-20**, with the matching
  `keybindings.json`; `check-install.sh` reports all six sections clean.
  Still awaiting a verdict from actually using it.

## The two pieces

1. **`rkdawenterprises.brief4vscode`** ("Brief Editor Keymap Emulation") —
   a Marketplace extension that already implements most of stock Brief
   emulation: numbered bookmarks, marking modes (stream/line/column/
   non-inclusive), overtype, clipboard history, etc. Installed from the
   Marketplace, not something we built.
2. **`local.brief-slickedit-helpers`** — a small extension we wrote from
   scratch to (a) fix specific bugs/gaps in brief4vscode's own
   implementation, and (b) port the user's own custom SlickEdit macros
   (which aren't things brief4vscode could ever have known about). Source
   lives in `vscode-setup/source/` (`package.json`, `extension.js`).
   Packaged as `brief-slickedit-helpers-<version>.vsix` in the same
   `vscode-setup` folder (0.0.4 as of the column-marking work below; both
   install scripts glob for it, so a version bump needs no script edit).
   Its `package.json` declares
   `extensionDependencies: ["rkdawenterprises.brief4vscode"]`, so VS Code
   itself enforces the dependency rather than it being purely implicit in
   keybindings.json's `when` clauses.

`keybindings.json` (also in `vscode-setup`) wires both extensions together
with careful `when` clauses — see comments inline in that file for the
reasoning behind every single binding, including why several SlickEdit
customizations were deliberately left unbound (real conflicts with more
important VS Code/brief4vscode defaults — F10, Alt+A vs marking mode, etc.
— explained inline).

## Recipe for a new machine

`~/.linuxjjk/init` does all of this automatically; it runs `check-install.sh`
and only invokes `install.sh` when the check reports a problem. What follows is
what that amounts to, and how to do it by hand.

Everything needed is in the `vscode-setup` folder (`~/.linuxjjk/vscode-setup/`
on Linux, `Documents\vscode-setup\` on the Windows box):
- `brief-slickedit-helpers-<version>.vsix` — the local extension, portable,
  installs via `code --install-extension`, no Node.js/npm needed on the
  target machine (it was hand-built as a zip with a vsixmanifest, not via
  `vsce`, since Node wasn't available where it was built either — see
  `source/` if it ever needs rebuilding).
- `keybindings.json` — copy to the target's VS Code user folder. **This file
  and the `.vsix` are a matched pair: ship and install them together.**
  `keybindings.json` names `briefHelpers.*` commands, and that list grows —
  0.0.4 added thirteen `briefHelpers.column*` ones. A newer
  `keybindings.json` against an older `.vsix` gives "command
  'briefHelpers.x' not found" on exactly those keys. Both install scripts
  check this as step 7.
- `settings-fragment.json` — just the font lines, to merge into settings.json.
- `fonts/` — `CascadiaCode.ttf`, `CascadiaCodeItalic.ttf`, plus the SIL OFL
  `LICENSE` (required to accompany redistribution) and a `README.txt`.
  `install.sh` installs from here, so the font needs neither network nor
  sudo. Kept bundled because upstream publishes exactly **one** release
  asset — 150 MB of otf + ttf + woff2 + every static instance — so the
  download fallback costs 150 MB to obtain these two ~740 KB files.
- `source/test/` — headless tests for the helper extension, run with
  `bash source/test/run-tests.sh`; no VS Code needed. `node_modules/vscode`
  there is a hand-written stub, deliberately outside `source/` so it never
  lands in the packaged `.vsix`.
- `check-install.sh` — health check, safe to run any time and changes nothing
  without `--fix`. **Run it first if a keybinding ever stops working.** Six
  sections: (1) exactly one extension copy on disk and nothing queued in
  `.obsolete`, (2) `extensions.json` agrees with disk, (3) installed version
  matches the `.vsix` here, (4) `keybindings.json` matches the copy here,
  (5) every `briefHelpers.*` command the **active** keybindings.json uses is
  provided by the **installed** extension, (6) the font resolves exactly.
  Sections 1 and 5 are the two known ways to get "command not found" — see
  "Stale extension copies" and the `keybindings.json` bullet above.

  `--fix` quits out if VS Code is running (repairing then recreates the
  hazard), otherwise force-reinstalls the `.vsix` and clears the extension
  scan cache — and, **only if section 5 failed**, installs the matching
  `keybindings.json` too, since reinstalling the `.vsix` cannot fix a stale
  active keybindings file. It deliberately leaves a merely-*different*
  keybindings.json alone (section 4's warning), because overwriting an edit
  you made on purpose would be worse than the problem.
- `install.ps1` (Windows) / `install.sh` (Linux, and Mac with one line
  edited — see comment in the script) — automate all of the above, backing up
  any existing keybindings.json/settings.json to `.bak` first. **The two are
  now at feature parity**, same seven numbered steps:

  0. **Preflight** — refuse to run while VS Code is open, because installing
     then is what causes the silent-extension-loss failure (see "Stale
     extension copies"). Asks for confirmation on an interactive terminal;
     aborts outright when non-interactive.
  1. `rkdawenterprises.brief4vscode` from the Marketplace, installed
     *before* the local extension, which depends on it.
  2. The local `.vsix`, globbed rather than hardcoded so a version bump needs
     no script edit; refuses to guess if more than one is present. Both steps
     verify via `--list-extensions` rather than trusting the exit code, and
     abort loudly rather than continue into a half-configured state.
  3. `keybindings.json` into the VS Code user folder.
  4. Font settings merged into `settings.json`.
  5. **Cascadia Code font**, detected by exact family match and installed if
     missing — per-user, needing no `sudo` / no administrator rights.
     Linux: `fc-match` to detect, install from `fonts/` else download the
     GitHub release, then `fc-cache` and re-verify; sudo is only reached for
     if fontconfig/curl/wget/unzip is missing, and it says so before
     prompting. Windows: registry + font-file check to detect, install from
     `fonts\` into `%LOCALAPPDATA%\Microsoft\Windows\Fonts` with an HKCU
     registration, else fall back to `winget` (which is system-wide and may
     prompt for elevation). Either way, an unresolvable font ends in a loud
     warning and a **non-zero exit** — a silent font substitution is the one
     failure this whole setup exists to prevent.
  6. **Stale-copy check** — exactly one `local.brief-slickedit-helpers-*`
     directory, nothing queued in `.obsolete`.
  7. **Command-parity check** — every `briefHelpers.*` command named in
     `keybindings.json` is provided by the installed extension's manifest.

  Testing status, honestly: `install.sh` has been run end-to-end on Linux
  Mint, and its font step exercised on all four paths (already-present,
  bundled install, download fallback, no-network failure). `install.ps1` was
  run on Windows 11 **before** the step 0/5/6/7 additions; those additions
  are only checked structurally (balanced braces/parens, no unbalanced
  quotes, no use-before-assignment) because there is no Windows machine and
  no PowerShell on the Mint box to parse it. Treat the PowerShell script's
  new steps as unverified until someone runs them.

  `check-install.sh` and `source/test/run-tests.sh` are bash-only; on Windows
  use Git Bash or WSL, or do the step 6 check by hand.

Run the script from inside `vscode-setup`. What it does, if you'd rather do
it by hand — **quit VS Code first**, every window, or step 6 below will bite:
1. `code --install-extension rkdawenterprises.brief4vscode`
2. `code --install-extension brief-slickedit-helpers-<version>.vsix`
3. Copy `keybindings.json` to:
   - Windows: `%APPDATA%\Code\User\keybindings.json`
   - Linux: `~/.config/Code/User/keybindings.json`
   - Mac: `~/Library/Application Support/Code/User/keybindings.json`
4. Merge `settings-fragment.json`'s two keys into `settings.json` in the
   same folder (`editor.fontFamily`, `editor.fontSize`).
5. Make sure **Cascadia Code** is installed as a system font. Both install
   scripts do this for you; by hand it's `cp fonts/CascadiaCode*.ttf
   ~/.local/share/fonts/ && fc-cache -f` on Linux, or on Windows either
   `winget install --id Microsoft.CascadiaCode` or right-click →  Install on
   `fonts\CascadiaCode.ttf`.

   Two traps, both hit for real on Mint:
   - `apt install fonts-cascadia-code` is **not** sufficient. It provides
     families named *Cascadia Mono* and *Cascadia Mono PL*. Neither is
     "Cascadia Code", so `editor.fontFamily` stays unmatched while looking
     installed.
   - `fc-list | grep -i "cascadia code"` is **not** a valid test. *Cascadia
     Code PL* and *Cascadia Code NF* are separate families containing that
     substring, so it reports success when the family VS Code wants is
     absent. Match exactly:

         fc-match -f '%{family[0]}' "Cascadia Code"

     `fc-match` always resolves to *something* (an unknown family returns the
     system default), so the test is whether that prints back literally
     `Cascadia Code`.

   If it's missing, VS Code silently substitutes something else — the exact
   font-fallback problem this whole setup exists to avoid (see below).
   The Windows equivalent of that exact-match test, since the same
   family-name trap applies there (*Cascadia Code PL* / *NF* / the *Cascadia
   Mono* family are all different families):

       Get-ChildItem "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts",
                     "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

   and look for a value named exactly `Cascadia Code (TrueType)` — not merely
   one starting with "Cascadia".
6. Check exactly one `local.brief-slickedit-helpers-*` directory exists in
   `~/.vscode/extensions` (`%USERPROFILE%\.vscode\extensions` on Windows),
   and that `.obsolete` there names none. More than one, or an `.obsolete`
   entry, means the next VS Code start can silently lose the extension — see
   "Stale extension copies".
7. Check every `briefHelpers.*` command in `keybindings.json` is listed in
   the installed extension's `package.json`. A mismatch means the `.vsix` and
   `keybindings.json` are from different versions; reinstall both from the
   same folder.
8. Fully restart VS Code (not just Reload Window) so the freshly-installed
   extension registers.

## Source materials

These two live on the **Windows** machine, not in this directory and not on
this Linux box — they are the raw material this setup was derived from, kept
here only so the derivation can be re-checked if needed.

- `T:\SlickEditOptions24b.zip` — the user's exported SlickEdit options
  (Tools > Options > Import/Export). Extracted analysis was done in a
  scratch temp directory during the session that produced this setup;
  re-extract the zip if you need to re-derive anything from it. Key files
  inside: `export.xml` (full options dump, ~27k lines — the "Key Bindings"
  dialog's own delta is at `eventtab_profiles.cfg.xml`, which is the *only*
  source of the user's actual key customizations — `export.xml` has
  everything else, including font/behavior settings referenced by line
  number in `keybindings.json`'s comments).
- `C:\Users\banshee\OneDrive\SlickEdit\jjk.e.1` — the user's real SlickEdit
  macro source. This is where `WriteFileHeader`, `WriteCommentBlock`,
  `WriteSectionSeparator`, `WriteFunctionBlock`, and `ZapWhitespace` are
  actually defined (found because they're custom, CamelCase-named
  commands — SlickEdit's own built-ins are lowercase-hyphenated like
  `cua-select`). The exported zip does NOT contain macro source at all,
  only key→command bindings — this file was the only way to see what
  these commands actually do.
- `lastmac.e` (inside the zip) has one unbound, unnamed recorded macro
  (wraps a word in quotes + trailing comma, advances to next word — looks
  like converting bare words into a quoted Python-style list). **Still
  open**: never bound to a key in the user's SlickEdit config, so it was
  never ported. Ask if they want it built as a VS Code command.

## Known approximations / open items

- **Box-comment glyphs**: `buildBox()` in `extension.js` always uses
  generic `/* */` C-style delimiters, regardless of the file's language.
  SlickEdit's actual per-language `BlockCommentSettings` (border chars,
  corner chars) weren't in the export. Content/structure of the four
  Write* commands is faithful to the real macro source; exact border glyph
  choice per language is not.
- **WriteFunctionBlock parameter/return-type extraction** is heuristic —
  parsed from VS Code's `DocumentSymbol.detail`, which isn't standardized
  across language servers. Works reasonably for languages with a good
  detail string; degrades gracefully (empty params list) otherwise.
- **pop_bookmark (Ctrl+,)** maps to `workbench.action.navigateBack`, VS
  Code's own jump-history stack — not identical semantics to SlickEdit's
  pop_bookmark, just the closest available analog.
- **alt-gtbookmark (Ctrl+Shift+0-9)** maps to `brief4vscode.jump_bookmark`,
  which opens a picker rather than jumping directly to bookmark N (the
  extension has no per-number jump command).
- Left deliberately unbound (real conflicts, explained inline in
  `keybindings.json`): F10 (cmdline-toggle — no VS Code equivalent exists;
  F10 is Debug: Step Over), `quote-key`, `resync`, `activate-threads`,
  Ctrl+Wheel page-scroll (can't bind mouse wheel via keybindings.json),
  `reverse-i-search` (no VS Code equivalent, and the key is Find in Files).

## Line marking caret (Alt+L)

Reported symptom: in SlickEdit, Alt+L then Alt+L again is a true no-op — no
selection, caret exactly where it started. In VS Code the caret ended up at
the start of the *next* line.

Root cause, read straight out of brief4vscode 1.4.0's
`out/Line_marking.js` + `out/utility.js`:

- `enable_marking_mode()` saves `editor.selection.active`, then immediately
  calls `select_with_position()`, which overwrites its own
  `m_selection_start` with `new Position(line, 0)` — **the column is
  discarded right there**.
- To make VS Code paint a full line *including its newline*, it has to build
  `Selection(anchor=(25,0), active=(26,0))`. So while marking, the caret is
  parked at the start of the following line. That's forced by how VS Code
  renders selections, not a bug.
- Toggling off runs `set_line_marking_mode(false)` ->
  `stop_all_marking_modes(true)` -> `utility.remove_selection()`, which
  collapses to `selection.**end**` — i.e. `(26,0)`. Hence the reported
  symptom.
- A *backward* selection is worse and was found while tracing this: Alt+L
  then Up gives `anchor=(26,0), active=(24,0)`, and `.end` is normalized, so
  it's *still* `(26,0)` — two lines below where the caret visually was, in
  the opposite direction from the movement.

Fix: `briefHelpers.lineMarkingModeToggle` in our extension wraps
`brief4vscode.line_marking_mode_toggle` (user keybindings.json overrides the
extension-contributed Alt+L, and `-brief4vscode.line_marking_mode_toggle`
removes the original). It delegates all real marking-mode work and only
corrects the caret: stash the column on entry, and on exit put the caret on
the line the user is visually on (`active.line - 1` for a forward selection,
`active.line` otherwise) at the stashed column.

### Where the caret sits *during* marking (reversed selection)

The round-trip fix above left the caret jumping to the next line on the
*first* Alt+L, which the user then queried. An earlier claim in this doc that
VS Code simply can't do better was **wrong** — corrected 2026-08-18. Two
mechanisms exist:

1. **Reversed selection** (implemented, helpers 0.0.3). A selection paints
   anchor..active and renders the caret at `active`, so covering all of line
   25 including its newline forces the endpoints to be (25,0) and (26,0) —
   the caret must be on one of them, and mid-line genuinely is unreachable
   with a real selection. But *either* end can be `active`: brief4vscode
   picks the forward form, and the reversed form `anchor=(26,0),
   active=(25,0)` paints the identical range with the caret on line 25,
   column 0. Still a real selection, so copy/cut/paste and everything else
   reading `editor.selection` keep working. Note brief4vscode *already*
   produces a reversed selection when the block is extended upward
   (`Line_marking.js:47-51`) — this just applies the same form to a one-line
   mark.

   Only single-line blocks. At 25-26 the endpoints are (25,0)/(27,0), neither
   of which is line 26, so the caret is a line off whichever end is active;
   brief4vscode's forward choice at least errs in the direction of travel.
   Implemented on `onDidChangeTextEditorSelection`, not by wrapping commands,
   because brief4vscode reaches `Line_marking.select()` from up/down,
   pageup/pagedown, home/end, top_of_window/end_of_window *and* left/right
   (aliased to up/down during line marking, `Commands.js:214,232`) — one hook
   covers all of them and any path added later. Guarded to the exact forward
   one-line shape, which also makes flipping self-terminating (a reversed
   selection no longer matches) rather than an event loop.

2. **Whole-line decoration** (NOT implemented, the only route to true
   parity). `createTextEditorDecorationType({ isWholeLine: true,
   backgroundColor: new ThemeColor("editor.selectionBackground") })` with the
   selection left empty at the real column. Proven to work — it's exactly how
   brief4vscode fakes column marking (`Column_marking.js:8`), which VS Code
   also can't represent as a selection. Cost is that the marked block stops
   being a selection: brief4vscode's line-mode `copy_to_history` reads
   `editor.document.getText(selection)` and `cut_selection` does
   `editBuilder.delete(selection)` (`Commands.js:471-510`), so copy/cut/
   delete/tab/outdent/paste would all need reimplementing against our own
   range state — replacing line marking rather than wrapping it — and VS
   Code's own selection consumers (format selection, comment toggle,
   find-in-selection, LSP range actions) would go blind too. In SlickEdit
   those all act on the marked block, so it trades one infidelity for
   another.

Also considered and rejected: a decoration pseudo-element drawn as a fake
caret at the real column, and a multi-selection with an empty primary. Both
show two carets — there's no API to hide the real one.

Two things worth knowing if this is ever revisited:

- **Entry vs exit is inferred from the selection transition** (non-empty ->
  empty means "just turned off"), not from the `brief4vscode_marking_mode`
  context key. There is no API for an extension to read a `when`-clause
  context key. That key also wouldn't be sufficient: it's shared by all
  three marking modes, so Alt+L during stream or column marking *switches
  into* line marking, which must be handled as an entry.
- **Still an approximation while marking is active**: SlickEdit keeps the
  caret on the real line *and column*, treating line selection as pure
  highlight. With the reversed selection the line is now right for a
  one-line block, but the column is 0, and a multi-line block is still a
  line off. Exact parity needs mechanism 2 above.

## Column marking (Alt+C) — replaced wholesale

Reported 2026-08-19 with a screen recording
(`~/Videos/screengrab-20260819-120850.mp4`): mark the word "Calypso", press
cut, and the text to its **left** is cut instead.

**What the recording shows.** Measuring the highlight's pixel extent per frame
(char width 8.78px, column 0 at x=80): block grows to cols 37–44 over
"Calypso" by 4.2s; at 4.58s it jumps to cols **0–37** with the caret now on
**line 32, which is blank**; flips back and forth as Up/Down are pressed; cut
at 6.90s removes cols 0–37. So cut took exactly what was highlighted — the
block had already moved.

**Root cause.** brief4vscode defines the block purely as (anchor, caret) and
recomputes it from `editor.selection.active` on every caret move
(`Column_marking.js:37`). VS Code has **no virtual whitespace**, so a caret
cannot sit at column 44 on a blank line — it clamps to column 0. brief4vscode
then reads that clamped column as intent (`Column_marking.js:68`) and rebuilds
the block from it:

    anchor (33,37), caret clamps to (32,0)
      -> caret.line < anchor.line and caret.character < anchor.character
      -> block = rectangle cols 0..37 across lines 32..33

Cut (`Commands.js:496` -> `Column_marking.js:121`) then deletes those ranges.
Copy corrupts identically but invisibly. Any line shorter than the caret column
does this; blank lines are the worst case. Note this is the **same class of bug**
as the pixel-vs-character goal-column problem fixed earlier for Up/Down.

**Why it could not be patched.** With the block defined by (anchor, caret) and
the caret restricted to real positions, the model literally cannot represent a
block whose right edge exceeds the length of some line it spans. The desired
column has to live outside the caret.

**The replacement.** `briefHelpers.column*` in our extension owns the block:

- `columnMark = { uri, anchorLine, anchorCol, caretLine, desiredCol }` is the
  single source of truth. The caret is *derived output*, clamped for display;
  it is never an input. Vertical movement does not touch `desiredCol` at all,
  so passing over short or blank lines cannot change which columns are marked.
- Short lines clamp **that row only**, in `columnRanges()`, which never writes
  back into `columnMark`.
- The status bar shows `<COLUMN-MARKING-MODE RxC>` — rows by columns — so what
  cut will take is stated numerically, not just implied by a highlight.
- Cut/copy write brief4vscode's own `Column_mode_block_data` JSON to the
  clipboard, field for field, so its Insert-key paste still recognises the
  block. Paste is therefore **not** overridden.
- `Alt+C` toggle, `Escape` cancels. A mouse click, an edit from anywhere else,
  or switching editors drops the block rather than letting a stale range be
  cut later.
- Alt+C on toggle sets `desiredCol = anchorCol + 1`, matching brief4vscode
  (`Column_marking.js:15`), so existing muscle memory holds: Alt+C then Right
  six times still marks seven columns.
- Horizontal travel is capped at the widest line the block spans, so Right
  gives visible feedback instead of silently banking desired-column past every
  line's end.

Keybindings are gated on the `briefHelpers.columnMarking` context key that the
extension sets; the older Home/End/Up/Down/Backspace overrides carry
`&& !briefHelpers.columnMarking` so the two sets are mutually exclusive by
when-clause rather than by file order.

**Not implemented:** typing over a block does not replace it (the block is just
dropped — brief4vscode intercepts the `type` command and fighting it over that
is not worth the risk). Column paste still goes through brief4vscode.

## Stale extension copies — how the setup breaks, and how to keep it working

Happened for real on 2026-08-19, and it is the failure mode most likely to
recur, so it gets its own section.

**Symptom.** Keybindings that worked the day before fail with
`command 'briefHelpers.rubout' not found`. Everything on disk is correct:
extension present and enabled, right version, `keybindings.json` in place,
nothing in the disabled list, no profiles, Workspace Trust unrestricted,
Settings Sync off. VS Code's own extension scan cache lists the extension with
all its commands. **Nothing is written to any log** — no activation attempt, no
error, in `exthost.log` or `renderer.log`. That silence is the signature.

**Cause.** Installing the helper extension while VS Code is *running*. A
running VS Code holds the previous version's directory open, so the install can
only mark it for deletion (`~/.vscode/extensions/.obsolete`). VS Code reclaims
it at a *later* startup — and that startup both deletes the stale directories
and builds the extension registry, about 450 ms apart:

    11:33:25.191  extension scan cache written
    11:33:25.508  extension host started      <- registry built here
    11:33:25.625  marked 0.0.1, 0.0.2 as removed
    11:33:25.966  deleted 0.0.1, 0.0.2 from disk

Three copies of `local.brief-slickedit-helpers` were on disk when the registry
was built; two vanished 458 ms later. Scanning duplicate ids mid-deletion drops
the id entirely, silently. `rkdawenterprises.brief4vscode` was unaffected
because it only ever had one directory — which is the tell: brief4vscode's
bindings keep working while ours all fail at once.

The version bumps 0.0.1 → 0.0.2 → 0.0.3 on 2026-08-18, each installed with the
editor open, are what stacked up the copies.

**Keeping it working:**

1. **Install with VS Code fully closed** — every window, not just the active
   one. Both install scripts detect a running VS Code and refuse (asking first
   on an interactive terminal, aborting outright when not).

   **But closing it is not sufficient, and an earlier version of this doc
   wrongly said it was.** Corrected 2026-08-20 from direct evidence: a CLI
   install with no VS Code running still only *marked* the old version for
   removal and left the directory on disk. It was the **next VS Code startup**
   that deleted it, at `11:24:44.987` — the same delete-while-scanning window
   as the original outage. That run happened to survive (the scan cache came
   out with 0.0.4 and all 24 commands), but the race was real. Closing VS Code
   shortens the window; it does not remove it. Which is why rule 2, not this
   one, is what actually protects the setup.
2. **After any install, check — this is the rule that actually protects you.**
   Both install scripts verify it themselves as steps 6 and 7, or run
   `bash check-install.sh`. Three things matter: exactly one
   `local.brief-slickedit-helpers-*` directory, no entry for it in
   `.obsolete`, and every `briefHelpers.*` command the active
   `keybindings.json` uses being provided by the installed extension. The
   first two failing means the next start can lose the extension; the third
   failing means specific keys fail with "command not found" while everything
   else looks perfect.
3. **If it breaks:** quit VS Code entirely, then
   `bash check-install.sh --fix` — force-reinstalls the `.vsix` and clears
   `~/.config/Code/CachedProfilesData/__default__profile__/extensions.user.cache`
   (regenerable) so the next start scans a clean single-copy directory, and, if
   the command-parity section failed, also installs the matching
   `keybindings.json` (reinstalling the `.vsix` cannot fix a stale active
   keybindings file). It refuses to run while VS Code is open, since repairing
   then would recreate the same precondition. **Then start VS Code and re-run
   `check-install.sh`** — per rule 1, the reclaim happens on that startup, so
   the clean bill of health is only meaningful afterwards.

**Diagnosing, if it ever looks different from the above.** The two observations
that separate the possibilities fastest: whether the Command Palette can find
"Brief Helpers: Backspace" (if not, the extension is missing from the registry;
if yes but the key does nothing, it's a `when` clause), and what the Extensions
view says about "Brief/SlickEdit Parity Helpers". Also note that `code
--list-extensions` reads `extensions.json` — it reports what is *installed*,
not what the running editor actually loaded, so it says "fine" during this
failure. The scan cache at
`CachedProfilesData/__default__profile__/extensions.user.cache` is closer to
the truth, and `code --status` shows which windows and extension hosts are
actually alive.

## Debugging history (context, not action items)

Three real, separate bugs turned up while testing `zapWhitespace` +
Up/Down arrow against the user's actual column-aligned data file
(`C:\git\tvtag2\x`, tab-title `x`, opened as `x.cpp` in SlickEdit to force
the C++ font for comparison):

1. **The actual root cause, found last**: VS Code was using its *default*
   font fallback list (`Consolas, 'Courier New', monospace`), not a single
   explicit font. The U+FFFD replacement-character glyph (present ~67
   times in that data file, confirmed via hex dump to be well-formed valid
   UTF-8, single BMP codepoint — not a surrogate pair, not malformed bytes)
   was rendering wider than one monospace cell under that fallback stack.
   VS Code's native Up/Down arrow navigates by pixel x-coordinate, not
   character count, so a wide glyph on one line threw off the
   pixel-to-character conversion on adjacent lines. **Fixed by setting an
   explicit single font** (`editor.fontFamily: "Cascadia Code"`), which the
   user confirmed resolved the visible misalignment.
2. **A real, independent bug in our own code**, found before #1: the
   `verticalGoal` state (briefHelpers.up/down's tracked "goal column" for
   consecutive presses) could go stale when `zapWhitespace` repositioned
   the cursor by other means, and if the new position coincidentally
   matched an old remembered goal, the next arrow press would wrongly
   reuse it. Fixed with `invalidateNavGoals()`, called by every command
   that moves the cursor outside the tracked Home/End/Up/Down commands.
   This fix is real and still in the shipped code, independent of #1.
3. A dead end worth knowing about so it isn't retried: an early attempt
   forced a `cursorRight`/`cursorLeft` round trip after edits to try to
   refresh VS Code's *native* Up/Down goal-column tracking. It didn't work
   and was replaced entirely — briefHelpers.up/down now bypass VS Code's
   native vertical-navigation goal-column mechanism completely, tracking
   their own character-index-based goal instead.

Lesson from this session, per explicit user feedback: don't declare a fix
"found" or "real" until the user has actually confirmed it — this happened
correctly on the third finding above but was said prematurely (repeatedly)
on the first two before they were actually confirmed. Verify before
declaring.

## Font size units

SlickEdit's "Cascadia Code size 11" (a native Win32 app) is in
**points**. VS Code's `editor.fontSize` is in **CSS pixels**. At standard
96 DPI, 1pt ≈ 1.33px, so matching SlickEdit's 11pt needs
`editor.fontSize` ≈ 15, not 11. This was empirically confirmed by the user
comparing both editors side by side on the same file. If display scaling
is non-standard, this ratio may need slight adjustment — nudge up/down by
1 and compare.
