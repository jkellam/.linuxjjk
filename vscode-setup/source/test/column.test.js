// Headless tests for briefHelpers column marking.
//
// Run:  bash source/test/run-tests.sh     (or: cd source/test && node column.test.js)
//
// There is no way to drive VS Code's UI from a script here, so node_modules/vscode
// is a hand-written stub providing just what extension.js touches. That is enough
// to test the part that actually broke: which columns the block covers.
//
// TEST 1/2 are the regression for the 2026-08-19 screen recording -- mark
// "Calypso", arrow Up over a blank line, cut. brief4vscode cut the text to the
// LEFT of the word instead. See "Column marking" in setting-up-vscode.md.

(async () => {
const vscode = require('vscode');
const ext = require('./extension.js');

// ---- fake document / editor ---------------------------------------------
let editorSeq = 0;
function makeEditor(lines) {
    const uriStr = `file:///fake/x${++editorSeq}.txt`;
    const doc = {
        uri: { toString: () => uriStr },
        get lineCount() { return lines.length; },
        lineAt(n) {
            const i = typeof n === 'number' ? n : n.line;
            const text = lines[i];
            return { lineNumber: i, text,
                     range: new vscode.Range(i, 0, i, text.length),
                     rangeIncludingLineBreak: new vscode.Range(i, 0, i + 1, 0),
                     firstNonWhitespaceCharacterIndex: text.length - text.trimStart().length };
        },
        getText(range) {
            if (!range) return lines.join('\n');
            if (range.start.line === range.end.line) {
                return lines[range.start.line].slice(range.start.character, range.end.character);
            }
            const out = [lines[range.start.line].slice(range.start.character)];
            for (let l = range.start.line + 1; l < range.end.line; l++) out.push(lines[l]);
            out.push(lines[range.end.line].slice(0, range.end.character));
            return out.join('\n');
        },
        validatePosition(p) {
            const line = Math.max(0, Math.min(p.line, lines.length - 1));
            return new vscode.Position(line, Math.max(0, Math.min(p.character, lines[line].length)));
        },
    };
    const editor = {
        document: doc,
        selection: new vscode.Selection(new vscode.Position(0, 0), new vscode.Position(0, 0)),
        get selections() { return [this.selection]; },
        visibleRanges: [new vscode.Range(20, 0, 60, 0)],
        decorations: [],
        setDecorations(_type, ranges) { this.decorations = ranges; },
        revealRange() {},
        edit(cb) {
            const edits = [];
            cb({ delete: (r) => edits.push(r), insert: () => {}, replace: () => {} });
            // apply deletions bottom-up so earlier ranges keep their offsets
            edits.sort((a, b) => b.start.line - a.start.line || b.start.character - a.start.character);
            for (const r of edits) {
                if (r.start.line !== r.end.line) throw new Error('multi-line delete not modelled');
                const t = lines[r.start.line];
                lines[r.start.line] = t.slice(0, r.start.character) + t.slice(r.end.character);
            }
            return Promise.resolve(true);
        },
    };
    vscode.window.activeTextEditor = editor;
    vscode.window.visibleTextEditors = [editor];
    // real VS Code raises this on editor switch; the block must not survive it
    vscode._listeners.activeEditor.forEach(fn => fn(editor));
    return { editor, doc, lines };
}

const run = (id, ...a) => vscode.commands.executeCommand(id, ...a);
let pass = 0, fail = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}`);
    if (!ok) { console.log(`        got:  ${JSON.stringify(got)}`); console.log(`        want: ${JSON.stringify(want)}`); fail++; }
    else pass++;
}
const marked = (h) => h.editor.decorations.map(r => h.doc.getText(r));

ext.activate({ subscriptions: [] });

// ======================================================================
// The exact case from the 2026-08-19 screen recording.
// Line 32 is blank; line 33 holds the prefix then "Calypso".
// ======================================================================
const PREFIX = "1. There's no console on the device. ";
const L33 = PREFIX + 'Calypso (STM32 running Zephyr) exposes a real UART shell';
const C0 = PREFIX.length;          // column where "Calypso" starts
console.log(`\n"Calypso" occupies columns ${C0}..${C0 + 7}\n`);

console.log('TEST 1: mark "Calypso", press Up over the blank line, cut');
let h = makeEditor(['', L33, 'short']);
h.editor.selection = new vscode.Selection(new vscode.Position(1, C0), new vscode.Position(1, C0));
await run('briefHelpers.columnMarkingModeToggle');
for (let i = 0; i < 6; i++) await run('briefHelpers.columnRight');   // +1 from toggle = 7 columns
check('block is exactly "Calypso"', marked(h), ['Calypso']);

await run('briefHelpers.columnUp');                                   // over the BLANK line 0
check('after Up the marked columns are unchanged', marked(h), ['', 'Calypso']);
check('physical caret clamped to the blank line', [h.editor.selection.active.line, h.editor.selection.active.character], [0, 0]);

await run('briefHelpers.columnDown');
check('back down: still "Calypso"', marked(h), ['Calypso']);

await run('briefHelpers.columnUp');
await run('briefHelpers.columnCut');
check('cut removed "Calypso", prefix intact', h.lines[1], PREFIX + ' (STM32 running Zephyr) exposes a real UART shell');
check('blank line untouched', h.lines[0], '');
const clip = JSON.parse(await vscode.env.clipboard.readText());
check('clipboard rows (padded rectangle)', clip.rows, ['       ', 'Calypso']);
check('clipboard mime is brief4vscode-compatible', clip.mime.includes('Column_mode_block_data'), true);

console.log('\nTEST 2: the old brief4vscode failure must NOT reproduce');
h = makeEditor(['', L33, 'short']);
h.editor.selection = new vscode.Selection(new vscode.Position(1, C0), new vscode.Position(1, C0));
await run('briefHelpers.columnMarkingModeToggle');
for (let i = 0; i < 6; i++) await run('briefHelpers.columnRight');
await run('briefHelpers.columnUp');
check('block is NOT the text left of Calypso', marked(h).includes(PREFIX), false);

console.log('\nTEST 3: multi-line block across a short line');
h = makeEditor(['abcdefghij', 'abc', 'abcdefghij']);
h.editor.selection = new vscode.Selection(new vscode.Position(0, 4), new vscode.Position(0, 4));
await run('briefHelpers.columnMarkingModeToggle');    // desired 5, anchor 4
for (let i = 0; i < 3; i++) await run('briefHelpers.columnRight');  // desired 8 -> cols 4..8
await run('briefHelpers.columnDown');
await run('briefHelpers.columnDown');
check('short middle row contributes nothing, others full width', marked(h), ['efgh', '', 'efgh']);
await run('briefHelpers.columnCut');
check('row 0 cut', h.lines[0], 'abcdij');
check('row 1 (too short) untouched', h.lines[1], 'abc');
check('row 2 cut', h.lines[2], 'abcdij');

console.log('\nTEST 4: Home/End set columns without destroying the block');
h = makeEditor(['abcdefghij', 'abcdefghij']);
h.editor.selection = new vscode.Selection(new vscode.Position(0, 4), new vscode.Position(0, 4));
await run('briefHelpers.columnMarkingModeToggle');
await run('briefHelpers.columnDown');
await run('briefHelpers.columnHome');
check('Home marks cols 0..4 on both rows', marked(h), ['abcd', 'abcd']);
await run('briefHelpers.columnEnd');
check('End marks cols 4..10 on both rows', marked(h), ['efghij', 'efghij']);

console.log('\nTEST 5: cancel paths');
h = makeEditor(['abcdefghij']);
h.editor.selection = new vscode.Selection(new vscode.Position(0, 2), new vscode.Position(0, 2));
await run('briefHelpers.columnMarkingModeToggle');
check('context key set while marking', vscode._context['briefHelpers.columnMarking'], true);
await run('briefHelpers.columnCancel');
check('context key cleared on cancel', vscode._context['briefHelpers.columnMarking'], false);
check('decorations cleared on cancel', h.editor.decorations.length, 0);

await run('briefHelpers.columnMarkingModeToggle');
await run('briefHelpers.columnMarkingModeToggle');
check('toggle twice leaves no block', vscode._context['briefHelpers.columnMarking'], false);

await run('briefHelpers.columnMarkingModeToggle');
vscode._listeners.docChange.forEach(fn => fn({ document: h.doc, contentChanges: [{}] }));
check('an outside edit drops the block', vscode._context['briefHelpers.columnMarking'], false);

await run('briefHelpers.columnMarkingModeToggle');
vscode._listeners.selection.forEach(fn => fn({ textEditor: h.editor, selections: [h.editor.selection],
                                               kind: vscode.TextEditorSelectionChangeKind.Mouse }));
check('a mouse click drops the block', vscode._context['briefHelpers.columnMarking'], false);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);

})();
