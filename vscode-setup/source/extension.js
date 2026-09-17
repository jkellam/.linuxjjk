const vscode = require('vscode');
const path = require('path');

const PREFERRED_WIDTH = 78;

// Consecutive-press state for briefHome/briefEnd/briefUp/briefDown (see
// each command below for how it's used). Bug found in testing: a command
// that repositions the cursor by some OTHER means (an edit, a Home/End
// jump) left these stale, and if the new cursor position happened to
// coincide with an old remembered goal -- easy to hit by chance in a
// column-aligned file -- the next Up/Down or Home/End press would wrongly
// treat it as "consecutive" and reuse a goal column from a completely
// unrelated earlier navigation. Every command that moves the cursor calls
// invalidateNavGoals() for whichever of these it doesn't itself own, so a
// fresh cursor position from any other source always starts a fresh chain.
let verticalGoal = null; // { uri, line, character, desiredChar } -- owned by moveVertical
let homeState = null;    // { uri, line, character, tier } -- owned by briefHome
let endState = null;     // { uri, line, character, tier } -- owned by briefEnd

function invalidateNavGoals({ vertical = true, home = true, end = true } = {}) {
    if (vertical) {
        verticalGoal = null;
    }
    if (home) {
        homeState = null;
    }
    if (end) {
        endState = null;
    }
}

// SlickEdit "Backspace key" = rubout (export.xml: "Cursor stops at column 1"):
// pressing Backspace at the start of a line does nothing -- it never merges
// the line with the one above, unlike VS Code's default deleteLeft.
async function rubout() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    invalidateNavGoals();

    const finalPositions = [];
    await editor.edit(editBuilder => {
        for (const selection of editor.selections) {
            if (!selection.isEmpty) {
                editBuilder.delete(selection);
                finalPositions.push(selection.start);
                continue;
            }
            const position = selection.active;
            if (position.character === 0) {
                finalPositions.push(position);
                continue;
            }
            const previous = position.translate(0, -1);
            editBuilder.delete(new vscode.Range(previous, position));
            finalPositions.push(previous);
        }
    });
    // Explicitly re-set the cursor(s) rather than trusting VS Code's implicit
    // post-edit adjustment -- see zapWhitespace() below for why that matters.
    editor.selections = finalPositions.map(p => new vscode.Selection(p, p));
}

// Port of the user's ZapWhitespace macro (source: OneDrive/SlickEdit/jjk.e.1):
// "Removes all whitespace from the cursor to the next non-whitespace
// character or end of line." The original scans forward with
//   while (substr(line, nonws, 1) == ' ' || substr(line, nonws, 1) == '\n')
// with no bound against the line's actual length, so on a blank line (or
// any time the cursor is already at/past end-of-line) it reads forever and
// hangs. Per instruction: replicate the intended behavior, not the hang --
// if the cursor is at or past the end of the line, do nothing.
//
// Two issues turned up while testing this against a real column-aligned
// data file, both worth knowing about if similar symptoms recur:
//
// 1. A later Up/Down arrow could land a character off after a zap. Root
//    cause: the file's font was falling back to a substitute glyph for
//    U+FFFD that rendered wider than one monospace cell, and VS Code's
//    native Up/Down arrow navigates by pixel x-coordinate, not character
//    count -- so a wide glyph on one line threw off the pixel-to-character
//    conversion on adjacent lines. Fixed at the settings level (an explicit
//    single "editor.fontFamily" instead of VS Code's default font-fallback
//    list -- see setting-up-vscode.md), not in code.
// 2. Independent of that: briefHelpers.up/down (below) track a "goal
//    column" across consecutive vertical moves, and this command
//    repositions the cursor by its own means -- so without explicitly
//    invalidating that tracked state, a stale goal from an earlier,
//    unrelated navigation could coincidentally match this edit's landing
//    position and get reused. Fixed by invalidateNavGoals() below.
async function zapWhitespace() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    invalidateNavGoals();

    const finalPositions = [];
    await editor.edit(editBuilder => {
        for (const selection of editor.selections) {
            const pos = selection.active;
            const lineText = editor.document.lineAt(pos.line).text;

            if (pos.character >= lineText.length) {
                // This is exactly the case that hangs in SlickEdit -- no-op instead.
                finalPositions.push(pos);
                continue;
            }

            let end = pos.character;
            while (end < lineText.length && lineText.charAt(end) === ' ') {
                end++;
            }
            if (end > pos.character) {
                editBuilder.delete(new vscode.Range(pos.line, pos.character, pos.line, end));
            }
            // Cursor belongs at pos.character either way: nothing to its
            // left was touched, only the whitespace at/after it.
            finalPositions.push(pos);
        }
    });
    editor.selections = finalPositions.map(p => new vscode.Selection(p, p));
}

// Up/Down arrow, replaced entirely: tracks the "desired column" as a plain
// character index across a run of consecutive vertical moves (same pattern
// as briefHome/briefEnd -- a move is "consecutive" if the cursor is exactly
// where our own previous vertical move left it), clamping to each line's
// actual length. This never touches Monaco's native pixel-based goal-column
// tracking, so it's immune to the width-rendering quirks that caused the
// zapWhitespace bug above -- verified the file's alignment is character-
// index-correct throughout, so character-index math is the right model.
async function moveVertical(direction) {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    const doc = editor.document;
    const uri = doc.uri.toString();
    const pos = editor.selection.active;

    let desiredChar = pos.character;
    if (verticalGoal && verticalGoal.uri === uri &&
        verticalGoal.line === pos.line && verticalGoal.character === pos.character) {
        desiredChar = verticalGoal.desiredChar;
    }

    const targetLine = pos.line + direction;
    if (targetLine < 0 || targetLine >= doc.lineCount) {
        return;
    }
    const targetChar = Math.min(desiredChar, doc.lineAt(targetLine).text.length);
    const target = new vscode.Position(targetLine, targetChar);

    editor.selection = new vscode.Selection(target, target);
    editor.revealRange(new vscode.Range(target, target));
    verticalGoal = { uri, line: target.line, character: target.character, desiredChar };
    invalidateNavGoals({ vertical: false }); // this move owns verticalGoal; Home/End's tracking is now stale
}

async function briefUp() {
    await moveVertical(-1);
}

async function briefDown() {
    await moveVertical(1);
}

// Genuine Brief-style Home/End: 1st press -> start/end of line, 2nd press
// (consecutive) -> start/end of the visible window, 3rd press (consecutive)
// -> start/end of the file. Deterministic on CONSECUTIVE PRESSES, not on
// inferring a tier from where the cursor currently sits -- that's what
// brief4vscode's own home()/end() do, and it's exactly why they misbehave:
// they re-read editor.visibleRanges live on every keystroke, and moving the
// cursor via the default reveal type nudges the scroll position each time,
// so the "window start" computed on press 2 differs from the one on press 3,
// producing the cascading scroll-then-recheck behavior instead of a clean
// three-tier jump. Here, "was this a consecutive press" is decided by
// whether the cursor is still exactly where OUR previous press left it --
// immune to viewport drift by construction, since it doesn't consult the
// viewport to make that decision. The window tier skips revealRange
// entirely -- its target is read directly from the current visible range,
// so it's on-screen by construction, and calling revealRange anyway risks
// its default padding nudging the scroll position, matching SlickEdit's
// "does not scroll the buffer" exactly.
function consecutiveTier(state, editor, pos) {
    const uri = editor.document.uri.toString();
    if (state && state.uri === uri && state.line === pos.line && state.character === pos.character) {
        return Math.min(state.tier + 1, 3);
    }
    return 1;
}

async function briefHome() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    const pos = editor.selection.active;
    const tier = consecutiveTier(homeState, editor, pos);

    let target;
    let reveal = true;
    if (tier === 1) {
        target = new vscode.Position(pos.line, 0);
    } else if (tier === 2) {
        // Computed directly from the CURRENT visible range, so it's already
        // on-screen by construction -- skip revealRange entirely rather
        // than risk its default padding nudging the scroll position.
        target = new vscode.Position(editor.visibleRanges[0].start.line, 0);
        reveal = false;
    } else {
        target = new vscode.Position(0, 0);
    }

    editor.selection = new vscode.Selection(target, target);
    if (reveal) {
        editor.revealRange(new vscode.Range(target, target));
    }
    homeState = { uri: editor.document.uri.toString(), line: target.line, character: target.character, tier };
    invalidateNavGoals({ home: false }); // this move owns homeState; Up/Down/End's tracking is now stale
}

async function briefEnd() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    const doc = editor.document;
    const pos = editor.selection.active;
    const tier = consecutiveTier(endState, editor, pos);

    let target;
    let reveal = true;
    if (tier === 1) {
        target = doc.lineAt(pos.line).range.end;
    } else if (tier === 2) {
        const bottomLine = editor.visibleRanges[0].end.line;
        target = doc.lineAt(bottomLine).range.end;
        reveal = false;
    } else {
        target = doc.lineAt(doc.lineCount - 1).range.end;
    }

    editor.selection = new vscode.Selection(target, target);
    if (reveal) {
        editor.revealRange(new vscode.Range(target, target));
    }
    endState = { uri: doc.uri.toString(), line: target.line, character: target.character, tier };
    invalidateNavGoals({ end: false }); // this move owns endState; Up/Down/Home's tracking is now stale
}

// Approximation of the user's CommentBox() helper: builds a boxed /* */
// comment PREFERRED_WIDTH columns wide, indented, with fillChar used for
// the top/bottom border. SlickEdit derives the actual comment delimiters
// and border glyphs per-language (BlockCommentSettings); that per-language
// config was not part of the exported options, so this always uses C-style
// block-comment delimiters regardless of the file's language.
function buildBox(lines, fillChar, indent) {
    const pad = ' '.repeat(indent);
    const innerWidth = Math.max(PREFERRED_WIDTH - indent - 4, 4);
    const border = pad + '/*' + fillChar.repeat(innerWidth) + '*/';
    const body = lines.map(l => {
        const inner = (' ' + l).padEnd(innerWidth, ' ');
        return pad + '/*' + inner + '*/';
    });
    return [border, ...body, border].join('\n');
}

function findEnclosingFunction(symbols, pos) {
    for (const s of symbols || []) {
        if (s.range.contains(pos)) {
            const child = findEnclosingFunction(s.children, pos);
            if (child) {
                return child;
            }
            if (s.kind === vscode.SymbolKind.Function ||
                s.kind === vscode.SymbolKind.Method ||
                s.kind === vscode.SymbolKind.Constructor) {
                return s;
            }
        }
    }
    return null;
}

async function placeCursorAfter(editor, marker, colOffset) {
    const text = editor.document.getText();
    const idx = text.indexOf(marker);
    if (idx < 0) {
        return;
    }
    const pos = editor.document.positionAt(idx + marker.length + (colOffset || 0));
    editor.selection = new vscode.Selection(pos, pos);
    editor.revealRange(new vscode.Range(pos, pos));
}

// Port of WriteCommentBlock(): inline single-line comment box at the
// cursor's current column, cursor left inside ready to type.
async function writeCommentBlock() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    invalidateNavGoals();
    const pos = editor.selection.active;
    const indent = pos.character;
    const box = buildBox([''], '-', indent) + '\n';
    await editor.edit(editBuilder => {
        editBuilder.insert(new vscode.Position(pos.line, 0), box);
    });
    const col = indent + 3; // indent + "/* ".length
    const sel = new vscode.Selection(pos.line + 1, col, pos.line + 1, col);
    editor.selection = sel;
    editor.revealRange(new vscode.Range(sel.start, sel.end));
}

// Port of WriteSectionSeparator(): bold ('=' fill) single-line comment box.
async function writeSectionSeparator() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    invalidateNavGoals();
    const pos = editor.selection.active;
    const box = buildBox([''], '=', 0) + '\n';
    await editor.edit(editBuilder => {
        editBuilder.insert(new vscode.Position(pos.line, 0), box);
    });
    const col = 3; // "/* ".length
    const sel = new vscode.Selection(pos.line + 1, col, pos.line + 1, col);
    editor.selection = sel;
    editor.revealRange(new vscode.Range(sel.start, sel.end));
}

// Port of WriteFileHeader(): standard header block at top of file, with
// #pragma once for header files.
async function writeFileHeader() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    invalidateNavGoals();
    const doc = editor.document;
    const fileName = path.basename(doc.fileName || 'untitled');
    const now = new Date();
    const username = process.env.USERNAME || process.env.USER || '';
    const lines = [
        '',
        '  Title      : ' + fileName,
        '  Created    : ' + now.toLocaleDateString() + ' @ ' + now.toLocaleTimeString(),
        '  Author     : ' + username,
        '  Description:',
        ''
    ];
    let box = buildBox(lines, '/', 0) + '\n';
    if (/\.(h|hpp)$/i.test(doc.fileName || '')) {
        box += '#pragma once\n';
    }
    await editor.edit(editBuilder => {
        editBuilder.insert(new vscode.Position(0, 0), box);
    });
    await placeCursorAfter(editor, 'Description:', 0);
}

// Port of WriteFunctionBlock(): needs the enclosing function's name,
// parameters, and return type. SlickEdit gets these from its own tagging
// engine (tag_get_context_info); here that's approximated with VS Code's
// document symbol provider, which is only as good as the language's
// installed extension. Parameter/return-type text is parsed heuristically
// out of DocumentSymbol.detail, which isn't standardized across languages
// -- treat it as best-effort, not exact.
async function writeFunctionBlock() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    invalidateNavGoals();
    const doc = editor.document;
    const pos = editor.selection.active;

    let symbols;
    try {
        symbols = await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', doc.uri);
    } catch (e) {
        symbols = null;
    }
    const fn = findEnclosingFunction(symbols, pos);
    if (!fn) {
        vscode.window.showInformationMessage('Not in a function');
        return;
    }

    let params = [];
    let returnType = '';
    const detailMatch = fn.detail && fn.detail.match(/\(([^)]*)\)\s*(?::\s*(.+))?/);
    if (detailMatch) {
        params = detailMatch[1]
            .split(',')
            .map(s => s.trim())
            .filter(Boolean)
            .map(s => s.split(/[:=]/)[0].trim());
        returnType = (detailMatch[2] || '').trim();
    }

    const startLine = fn.range.start.line;
    const indent = doc.lineAt(startLine).firstNonWhitespaceCharacterIndex;

    const lines = ['', ' ' + fn.name, '', ' Description:', '', '', ' Parameters:'];
    if (params.length === 0) {
        lines.push('   <none>');
    } else {
        for (const p of params) {
            lines.push('   ' + p + ' - ');
        }
    }
    if (returnType && returnType !== 'void') {
        lines.push('', ' Return Value:', '');
    }
    lines.push('');

    const box = buildBox(lines, '/', indent) + '\n';
    await editor.edit(editBuilder => {
        editBuilder.insert(new vscode.Position(startLine, 0), box);
    });
    await placeCursorAfter(editor, 'Description:', 0);
}

// ---- Reversed single-line mark selection (Alt+L) -------------------------
// Keeps the caret on the marked line instead of on the line after it.
//
// A VS Code selection paints anchor..active and renders the caret at
// `active`, so covering all of line 25 including its newline means the two
// endpoints are (25,0) and (26,0) and the caret HAS to sit on one of them --
// a mid-line caret is not reachable with a real selection, whatever the
// direction. brief4vscode picks the forward form (anchor=(25,0),
// active=(26,0)), which is why the caret appears on line 26. The reversed
// form (anchor=(26,0), active=(25,0)) paints the identical range with the
// caret on line 25, column 0.
//
// This stays a genuine selection, so copy/cut/paste and every other consumer
// of editor.selection keep working. The alternative -- an isWholeLine
// decoration with the selection left empty at the real column, which is how
// brief4vscode fakes COLUMN marking -- would give an exact mid-line caret but
// stop being a selection at all, taking brief4vscode's own line-mode
// copy/cut (they read editor.selection directly) down with it.
//
// Applied only while the marked block is a SINGLE line. Once it spans 25-26
// the endpoints are (25,0)/(27,0), neither of which is line 26, so the caret
// is a line off whichever end is active; brief4vscode's forward choice at
// least errs in the direction of travel. Collapsing back to one line
// re-applies the reversal -- which is why this hangs off
// onDidChangeTextEditorSelection instead of wrapping commands.
// brief4vscode reaches Line_marking.select() from up/down, pageup/pagedown,
// home/end, top_of_window/end_of_window AND left/right (which it aliases to
// up/down during line marking, Commands.js:214,232). One hook covers all of
// them; wrapping would have meant nine keybindings and would still miss any
// path added later.
//
// Taste call, so it has an off switch:
//     "briefHelpers.reverseSingleLineMarkSelection": false
// restores brief4vscode's original forward selection.
let inLineMarkingMode = false;

function reverseSingleLineMarkEnabled() {
    return vscode.workspace.getConfiguration('briefHelpers')
        .get('reverseSingleLineMarkSelection', true);
}

// The exact shape brief4vscode's Line_marking.select_with_position() produces
// for a one-line forward mark, and nothing else. Deliberately narrow: an
// already-reversed selection fails the isReversed test, so flipping can't
// feed itself an endless event loop, and a multi-line block fails the
// adjacent-line test. Note the last line of a file with no trailing newline
// never matches -- validatePosition clamps its (L+1,0) to (L,len), leaving
// the caret on the marked line already, so there's nothing to fix there.
function isForwardSingleLineMark(sel) {
    return !sel.isEmpty &&
        !sel.isReversed &&
        sel.anchor.character === 0 &&
        sel.active.character === 0 &&
        sel.active.line === sel.anchor.line + 1;
}

function reverseIfSingleLineMark(editor) {
    if (!reverseSingleLineMarkEnabled() || !isForwardSingleLineMark(editor.selection)) {
        return;
    }
    const sel = editor.selection;
    editor.selection = new vscode.Selection(sel.active, sel.anchor); // anchor/active swapped, same range
    invalidateNavGoals();
}

function onDidChangeSelection(e) {
    if (columnMark && !columnApplying && e.kind === vscode.TextEditorSelectionChangeKind.Mouse) {
        columnClear(); // clicking somewhere else means that block is no longer what you meant
    }
    if (!inLineMarkingMode) {
        return;
    }
    if (e.selections.length === 1 && e.selections[0].isEmpty) {
        // Line marking ended without going through our Alt+L wrapper --
        // Escape, typing, copy/cut/paste, Alt+M/Alt+C/Alt+A, Alt+X. Every one
        // of those paths finishes in brief4vscode's remove_selection(), so an
        // empty selection is a reliable "mode is over". Without this the flag
        // could stay stuck on and start flipping unrelated whole-line
        // selections much later.
        inLineMarkingMode = false;
        return;
    }
    if (e.kind === vscode.TextEditorSelectionChangeKind.Mouse) {
        // Clicking a line number in the gutter produces exactly the same
        // forward whole-line shape. Leave the user's own mouse selections be.
        return;
    }
    reverseIfSingleLineMark(e.textEditor);
}

// SlickEdit parity for Alt+L (line marking mode toggle). In SlickEdit, line
// selection is purely a highlight -- the caret never moves -- so Alt+L twice
// is a true no-op. brief4vscode can't do that, because the only way to make
// VS Code paint a full line INCLUDING its newline is to park the caret at the
// start of the following line, so its toggle leaves the caret somewhere the
// user never put it:
//
//   Alt+L on line 25 -> Line_marking.enable_marking_mode() saves the caret,
//   then immediately calls select_with_position(), which overwrites its own
//   m_selection_start with (25,0) -- throwing the COLUMN away -- and builds
//   Selection(anchor=(25,0), active=(26,0)).
//
//   Alt+L again -> set_line_marking_mode(false) -> stop_all_marking_modes(true)
//   -> utility.remove_selection(), which collapses to selection.END, i.e.
//   (26,0). Reported symptom: the caret is now at the start of line 26.
//   Worse for a BACKWARD selection (Alt+L then Up gives anchor=(26,0),
//   active=(24,0)): .end is normalized, so it's still (26,0) -- two lines
//   below where the caret visually was, in the opposite direction.
//
// So two things are lost on the way in (the column) and one on the way out
// (the line). This wrapper stashes the column on entry and, on exit, puts the
// caret back on the line the user is visually on, at that column.
//
// Which way the toggle went has to be inferred, because there is no API to
// read a `when`-clause context key from an extension. The selection
// transition is the reliable signal: leaving line marking mode always ends in
// remove_selection(), so non-empty -> empty means "it just turned off".
// brief4vscode_marking_mode wouldn't have been enough anyway -- it's shared by
// all three marking modes, so Alt+L pressed during stream or column marking
// SWITCHES to line marking, which is an entry, not an exit.
let lineMarkOrigin = null; // { uri, character } -- caret column before marking started

async function lineMarkingModeToggle() {
    let editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    const uri = editor.document.uri.toString();
    const before = editor.selection;

    await vscode.commands.executeCommand('brief4vscode.line_marking_mode_toggle');

    editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.uri.toString() !== uri) {
        return; // active editor changed under us; nothing sensible to restore
    }
    if (before.isEmpty || !editor.selection.isEmpty) {
        // Entering, or switching into, line marking mode: remember the column
        // brief4vscode is about to discard.
        lineMarkOrigin = { uri, character: before.active.character };
        inLineMarkingMode = true;
        reverseIfSingleLineMark(editor);
        return;
    }

    // Leaving. `before` is still the line selection, so the line the caret was
    // visually on is its active end -- minus one for a forward selection,
    // whose active end is parked on the line after the last marked one.
    const doc = editor.document;
    const logicalLine = before.active.line > before.anchor.line
        ? before.active.line - 1
        : before.active.line;
    const line = doc.lineAt(Math.max(0, Math.min(logicalLine, doc.lineCount - 1)));
    const character = (lineMarkOrigin && lineMarkOrigin.uri === uri)
        ? Math.min(lineMarkOrigin.character, line.text.length)
        : 0;
    const target = new vscode.Position(line.lineNumber, character);
    lineMarkOrigin = null;
    inLineMarkingMode = false;

    editor.selection = new vscode.Selection(target, target);
    // Only reveal if the restored line actually fell outside the viewport --
    // same reasoning as briefHome's window tier: revealRange's default padding
    // nudges the scroll position, and after a plain Alt+L Alt+L the line is
    // on-screen by construction, so scrolling would be a visible side effect
    // of a round trip that is supposed to change nothing.
    const onScreen = editor.visibleRanges.some(
        r => target.line >= r.start.line && target.line <= r.end.line);
    if (!onScreen) {
        editor.revealRange(new vscode.Range(target, target));
    }
    invalidateNavGoals();
}

// ===== Column marking mode ================================================
// Replaces brief4vscode's column marking wholesale. Its version cannot be
// patched into correctness, for a structural reason:
//
// brief4vscode defines the block purely as (anchor, caret) and recomputes it
// from `editor.selection.active` on every caret move (Column_marking.js:37).
// VS Code has no virtual whitespace, so a caret CANNOT sit at column 44 on a
// blank line -- it clamps to column 0. brief4vscode then reads that clamped
// column as the user's intent (Column_marking.js:68) and rebuilds the block
// from it. Confirmed on video 2026-08-19: mark "Calypso" at cols 37-44 on
// line 33, press Up over blank line 32, and the block silently becomes the
// rectangle cols 0-37 across lines 32-33 -- i.e. the text to the LEFT. Cut
// then faithfully deletes that. Copy corrupts identically, just invisibly.
// Any line shorter than the caret column does it, blank lines are just the
// worst case.
//
// The fix is the same one that fixed briefHelpers.up/down: keep the DESIRED
// column in our own state and let only the physical caret clamp. `columnMark`
// below is the single source of truth for what the block is; the caret is a
// rendering detail derived from it, never an input to it. Moving vertically
// does not touch desiredCol at all, so passing over short or blank lines
// cannot change which columns are marked.
//
// What gets cut is exactly what the status bar reports (`<COLUMN-MARKING-MODE
// RxC>`) and exactly what is highlighted -- that is the whole point.
const COLUMN_DECORATION = vscode.window.createTextEditorDecorationType({
    backgroundColor: new vscode.ThemeColor('editor.selectionBackground')
});

// brief4vscode's own clipboard block format, reproduced field-for-field
// (Column_marking.js, Column_mode_block_data) so its Insert-key paste still
// recognises a block we cut -- it sniffs the clipboard text for this mime
// string (Commands.js:512). Keeping the format means paste needs no override.
const COLUMN_BLOCK_MIME =
    'text/brief-column-mode-block; class=net.ddns.rkdawenterprises.brief4vscode.Column_mode_block_data';

let columnMark = null;      // { uri, anchorLine, anchorCol, caretLine, desiredCol }
let columnStatus = null;    // StatusBarItem
let columnApplying = false; // guards our own edits/selection writes from the cancel watchers

function columnBounds(m) {
    return {
        topLine:  Math.min(m.anchorLine, m.caretLine),
        botLine:  Math.max(m.anchorLine, m.caretLine),
        leftCol:  Math.min(m.anchorCol,  m.desiredCol),
        rightCol: Math.max(m.anchorCol,  m.desiredCol)
    };
}

// The block's columns come from columnMark; a line too short to reach them
// narrows THAT ROW ONLY. Nothing here writes back into columnMark -- that
// separation is the bug fix.
function columnRanges(doc, m) {
    const b = columnBounds(m);
    const ranges = [];
    for (let line = b.topLine; line <= b.botLine && line < doc.lineCount; line++) {
        const len = doc.lineAt(line).text.length;
        ranges.push(new vscode.Range(line, Math.min(b.leftCol, len), line, Math.min(b.rightCol, len)));
    }
    return ranges;
}

function columnWidestLine(doc, m) {
    const b = columnBounds(m);
    let max = 0;
    for (let line = b.topLine; line <= b.botLine && line < doc.lineCount; line++) {
        max = Math.max(max, doc.lineAt(line).text.length);
    }
    return max;
}

function columnEditorFor(uri) {
    return vscode.window.visibleTextEditors.filter(e => e.document.uri.toString() === uri);
}

function columnClear() {
    if (columnMark) {
        for (const editor of columnEditorFor(columnMark.uri)) {
            editor.setDecorations(COLUMN_DECORATION, []);
        }
    }
    columnMark = null;
    if (columnStatus) {
        columnStatus.hide();
    }
    vscode.commands.executeCommand('setContext', 'briefHelpers.columnMarking', false);
}

function columnRender(editor) {
    if (!columnMark) {
        return;
    }
    const doc = editor.document;
    editor.setDecorations(COLUMN_DECORATION, columnRanges(doc, columnMark));

    // The caret is derived output, not state. It clamps; desiredCol does not.
    const line = Math.max(0, Math.min(columnMark.caretLine, doc.lineCount - 1));
    const pos = new vscode.Position(line, Math.min(columnMark.desiredCol, doc.lineAt(line).text.length));
    columnApplying = true;
    try {
        editor.selection = new vscode.Selection(pos, pos);
    } finally {
        columnApplying = false;
    }
    editor.revealRange(new vscode.Range(pos, pos));

    const b = columnBounds(columnMark);
    columnStatus.text = `<COLUMN-MARKING-MODE ${b.botLine - b.topLine + 1}x${b.rightCol - b.leftCol}>`;
    columnStatus.tooltip = 'Brief/SlickEdit column block: rows x columns that cut/copy will act on';
    columnStatus.show();
}

function columnEditor() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || !columnMark || editor.document.uri.toString() !== columnMark.uri) {
        return null;
    }
    return editor;
}

async function columnMarkingModeToggle() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    if (columnMark) {
        columnClear();
        invalidateNavGoals();
        return;
    }
    if (inLineMarkingMode) {
        await lineMarkingModeToggle(); // don't leave line marking running underneath
    }
    const pos = editor.selection.active;
    columnMark = {
        uri: editor.document.uri.toString(),
        anchorLine: pos.line,
        anchorCol: pos.character,
        caretLine: pos.line,
        // +1 so the character under the cursor is marked immediately, matching
        // brief4vscode (Column_marking.js:15) and therefore existing muscle
        // memory: Alt+C then Right six times still marks seven columns.
        desiredCol: pos.character + 1
    };
    await vscode.commands.executeCommand('setContext', 'briefHelpers.columnMarking', true);
    columnRender(editor);
}

function columnCancel() {
    columnClear();
    invalidateNavGoals();
}

// dLine moves the block's far edge vertically. It deliberately does NOT touch
// desiredCol -- that is precisely the bug being fixed.
function columnStep(dLine, dCol) {
    const editor = columnEditor();
    if (!editor) {
        return;
    }
    const doc = editor.document;
    if (dLine !== 0) {
        columnMark.caretLine = Math.max(0, Math.min(columnMark.caretLine + dLine, doc.lineCount - 1));
    }
    if (dCol !== 0) {
        // Capped at the widest line the block spans so Right gives visible
        // feedback instead of silently banking desired-column past every
        // line's end. The cap never drops below the anchor, or the block could
        // not be reopened rightwards after shrinking onto a short line.
        const cap = Math.max(columnWidestLine(doc, columnMark), columnMark.anchorCol);
        columnMark.desiredCol = Math.max(0, Math.min(columnMark.desiredCol + dCol, cap));
    }
    columnRender(editor);
}

function columnSetCol(col) {
    const editor = columnEditor();
    if (!editor) {
        return;
    }
    columnMark.desiredCol = Math.max(0, col);
    columnRender(editor);
}

function columnPageLines(editor) {
    const visible = editor.visibleRanges[0];
    return visible ? Math.max(1, visible.end.line - visible.start.line) : 1;
}

// rows are clamped per line, then padded to a rectangle by the block format --
// same as brief4vscode, so a short row pastes back as spaces rather than
// shifting the rows below it left.
function columnBlockJSON(doc, m) {
    const rows = columnRanges(doc, m).map(r => doc.getText(r).replace(/\r?\n/g, ''));
    const width = rows.reduce((w, r) => Math.max(w, r.length), 0);
    return JSON.stringify({
        mime: COLUMN_BLOCK_MIME,
        rows: rows.map(r => r.padEnd(width, ' ')),
        width
    }, null, 4);
}

async function columnOperate({ copy, remove }) {
    const editor = columnEditor();
    if (!editor) {
        return;
    }
    const doc = editor.document;
    // Snapshot the block BEFORE editing -- ranges shift once text is removed.
    const mark = columnMark;
    const ranges = columnRanges(doc, mark).filter(r => !r.isEmpty);
    const b = columnBounds(mark);

    if (copy) {
        await vscode.env.clipboard.writeText(columnBlockJSON(doc, mark));
    }
    if (remove && ranges.length > 0) {
        columnApplying = true;
        try {
            await editor.edit(editBuilder => {
                for (const range of ranges) {
                    editBuilder.delete(range);
                }
            });
        } finally {
            columnApplying = false;
        }
    }

    columnClear();
    const line = Math.max(0, Math.min(b.topLine, editor.document.lineCount - 1));
    const target = new vscode.Position(line, Math.min(b.leftCol, editor.document.lineAt(line).text.length));
    editor.selection = new vscode.Selection(target, target);
    editor.revealRange(new vscode.Range(target, target));
    invalidateNavGoals();
}

// Any edit we did not make, a mouse click, or switching editors invalidates the
// block. Cutting a block whose text has moved underneath is exactly the class
// of silent wrong-range damage this whole rewrite exists to stop, so the block
// is dropped rather than guessed at.
function columnOnDocumentChange(e) {
    if (columnMark && !columnApplying && e.contentChanges.length > 0 &&
        e.document.uri.toString() === columnMark.uri) {
        columnClear();
    }
}

function columnOnActiveEditorChange(editor) {
    if (columnMark && (!editor || editor.document.uri.toString() !== columnMark.uri)) {
        columnClear();
    }
}

function activate(context) {
    context.subscriptions.push(
        vscode.commands.registerCommand('briefHelpers.rubout', rubout),
        vscode.commands.registerCommand('briefHelpers.zapWhitespace', zapWhitespace),
        vscode.commands.registerCommand('briefHelpers.home', briefHome),
        vscode.commands.registerCommand('briefHelpers.end', briefEnd),
        vscode.commands.registerCommand('briefHelpers.up', briefUp),
        vscode.commands.registerCommand('briefHelpers.down', briefDown),
        vscode.commands.registerCommand('briefHelpers.writeCommentBlock', writeCommentBlock),
        vscode.commands.registerCommand('briefHelpers.writeSectionSeparator', writeSectionSeparator),
        vscode.commands.registerCommand('briefHelpers.writeFileHeader', writeFileHeader),
        vscode.commands.registerCommand('briefHelpers.writeFunctionBlock', writeFunctionBlock),
        vscode.commands.registerCommand('briefHelpers.lineMarkingModeToggle', lineMarkingModeToggle),
        vscode.commands.registerCommand('briefHelpers.columnMarkingModeToggle', columnMarkingModeToggle),
        vscode.commands.registerCommand('briefHelpers.columnCancel', columnCancel),
        vscode.commands.registerCommand('briefHelpers.columnUp', () => columnStep(-1, 0)),
        vscode.commands.registerCommand('briefHelpers.columnDown', () => columnStep(1, 0)),
        vscode.commands.registerCommand('briefHelpers.columnLeft', () => columnStep(0, -1)),
        vscode.commands.registerCommand('briefHelpers.columnRight', () => columnStep(0, 1)),
        vscode.commands.registerCommand('briefHelpers.columnHome', () => columnSetCol(0)),
        vscode.commands.registerCommand('briefHelpers.columnEnd', () => {
            const editor = columnEditor();
            if (editor) {
                columnSetCol(editor.document.lineAt(
                    Math.min(columnMark.caretLine, editor.document.lineCount - 1)).text.length);
            }
        }),
        vscode.commands.registerCommand('briefHelpers.columnPageUp', () => {
            const editor = columnEditor();
            if (editor) {
                columnStep(-columnPageLines(editor), 0);
            }
        }),
        vscode.commands.registerCommand('briefHelpers.columnPageDown', () => {
            const editor = columnEditor();
            if (editor) {
                columnStep(columnPageLines(editor), 0);
            }
        }),
        vscode.commands.registerCommand('briefHelpers.columnCut', () => columnOperate({ copy: true, remove: true })),
        vscode.commands.registerCommand('briefHelpers.columnCopy', () => columnOperate({ copy: true, remove: false })),
        vscode.commands.registerCommand('briefHelpers.columnDelete', () => columnOperate({ copy: false, remove: true })),
        vscode.window.onDidChangeTextEditorSelection(onDidChangeSelection),
        vscode.workspace.onDidChangeTextDocument(columnOnDocumentChange),
        vscode.window.onDidChangeActiveTextEditor(columnOnActiveEditorChange),
        COLUMN_DECORATION
    );

    columnStatus = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    context.subscriptions.push(columnStatus);
}

function deactivate() {}

module.exports = { activate, deactivate };
