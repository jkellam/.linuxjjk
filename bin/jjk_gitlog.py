r"""One-screen git log rendering: the shared engine behind git-trunk and friends.

Not a script -- import it.  Each view is its own small executable that calls
screen_log() with what makes it different, which is only ever three things: a
blurb for the usage text, extra `git log` arguments, and an optional callable
that picks the revisions.

    from jjk_gitlog import screen_log
    sys.exit(screen_log(name="tree",
                        blurb="every local branch, against origin/main",
                        revs=my_revs))

WHY THIS EXISTS

The shell aliases these replace ended in `| head -n $((LINES - 3))`, which counts
*logical* lines.  A terminal scrolls on *physical rows*.  Any commit whose
rendered line was wider than the window wrapped to two or more rows, so the
output overran the screen and the top scrolled away -- exactly what the `- 3` was
there to prevent.  Measured in fw-cypress2 at 80x24: every one of the alias's 21
lines came out 119 to 154 columns wide, so 21 lines of log occupied roughly 42
rows of a 24-row window.

So the layout happens here instead: measure every line in display columns, wrap
it at the window width with a hanging indent, and spend a budget of physical
rows.  Subject and author are never truncated -- a wrapped commit simply costs
more of the budget, so fewer commits fit.  Same repo, same window: 21 rows, 10
commits, nothing wider than 80 columns.

A wrapped line hangs at the subject column of its own line -- past the graph
rails, the hash, the date, and the decoration -- with the graph rails carried
down the left.  A parenthesized author is atomic: it moves to the next row whole
rather than breaking after "(Jonny".

    * a1b2c3d 08-25 09:14 (main) Fix the retry backoff so that the client does not
                          hammer the server (Jeff Kellam)
    * 9f8e7d6 08-24 16:02 Bump the sdk pin (Jeff Kellam)
    | * 4c5d6e7 08-23 11:47 Teach the parser about the new frame header so that
    |                       malformed input is rejected (Jeff Kellam)

HOW THE PARSE WORKS

The format string starts with %x1f (an ASCII unit separator).  That is the whole
trick: it terminates git's graph prefix, so `line.split("\x1f")` separates the
graph from the fields no matter how deep the graph is or how much color git has
injected into the rails.  Lines with no %x1f at all are graph-only rows (`|\`,
`|/`) and are passed through untouched.

Hash, date and decoration keep git's own colors inline, `%C(auto)` decoration
semantics included.  Subject and author are fetched plain and colored here,
because those two are the fields that get split by wrapping.

KNOWN LIMITS

  - --max-count is capped at the row budget: a view can never display more
    commits than it has rows.  A user-supplied -N / --max-count wins.

    That cap does NOT make a huge repo fast, and it is worth knowing why.
    `--graph` implies `--topo-order`, and with no commit-graph file git has to
    walk the whole reachable history before it can emit the first line -- the cap
    does not bound the walk.  Measured on a synthetic 150k-commit repo:

        --max-count=21, no --graph                  0.002 s
        --max-count=21, with --graph                0.42  s
        --max-count=21, with --graph + commit-graph 0.003 s

    So the fix for a slow repo is `git commit-graph write --reachable` (or
    `git maintenance start`), not a smaller count.  None of the fw-cypress clones
    have a commit-graph, but at ~1000 commits they walk in about 3 ms, so it has
    never mattered there.
  - When stdout is not a tty the row budget and wrapping are both off, and color
    is off unless forced: `git trunk | grep` behaves like a plain log.  Use
    --lines / --width to exercise the layout through a pipe.
  - Tabs in a subject become single spaces.  Wrapping and tab stops do not mix.
  - Decorations do not wrap.  A ref name long enough to fill the window has its
    tail clipped on the head row; the subject then starts on the row below, at
    the column it would have used with no decoration at all.
  - Two things are clipped rather than wrapped, both as a last resort: a
    graph-only row on an absurdly wide graph, and any row in a window too narrow
    to hold the fixed `hash + date` head (roughly 30 columns).  See fit().
  - An author name wider than the text column is still split, since the only
    alternative is running off the screen.  Needs a ~30-column window.
  - Naming a revision on the command line replaces the view's own selection.  A
    separated option value reads as a revision here (`-S foo` looks like `foo`),
    which costs the default selection for that one command; use `-Sfoo`.
  - Character widths come from unicodedata: 0 for combining marks and format
    characters, 2 for East Asian Wide/Fullwidth, 1 otherwise.  That is the same
    model a terminal uses, but an emoji ZWJ sequence a font draws as one glyph
    still measures as its parts.  Nothing to be done from here.
"""

import os
import re
import subprocess
import sys
import unicodedata

SEP = "\x1f"
NBSP = "\u00a0"   # a space the wrapper will not break on; same width as " "
SGR = re.compile(r"\x1b\[[0-9;]*m")

DATE = "format:%m-%d %H:%M"
PRETTY = (
    "%x1f%C(bold yellow)%h%C(reset)"
    "%x1f%C(green)%ad%C(reset)"
    "%x1f%C(auto)%D%C(reset)"
    "%x1f%s"
    "%x1f%an"
)

DECO = "\033[33m"        # plain yellow, matching the ", " git puts between refs.
                         # The hash gets bold yellow from %C(bold yellow) above,
                         # which is exactly his $COLOR_YELLOW = \e[1;33m.
WHITE = "\033[37m"       # %C(white)
GREEN = "\033[32m"       # %C(green)
RESET = "\033[m"

RESERVE_DEFAULT = 3      # rows left for the prompt
MIN_TEXT = 24            # keep at least this many columns of text on a hang
FALLBACK_SIZE = (80, 24)

##  ---- shared git helpers --------------------------------------------------

def git(*args):
    """Run a read-only git command.  Returns its stdout stripped, or None if it
    failed -- a missing ref and an empty answer are both 'no', and every caller
    wants to treat them the same way."""
    proc = subprocess.run(("git",) + args, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def branch_names(*patterns):
    """Short names of the refs matching `patterns`.

    for-each-ref rather than `git branch`, because on a detached HEAD `git
    branch` prints a literal "(HEAD detached at abc1234)" line.  Split on
    whitespace -- which is what the shell aliases did -- that became four bogus
    revision arguments and `git sl` died with "fatal: Not a valid object name
    abc1234)".  for-each-ref only ever lists real refs."""
    out = git("for-each-ref", "--format=%(refname:short)", *patterns)
    return out.split() if out else []


##  A process only ever looks at one repo, so the answer is worth keeping.
_trunk = None


def trunk_name():
    """The name of this repo's trunk branch: "main", "master", or whatever else
    it actually uses.

    Some repos are main/origin/main and others are master/origin/master, and
    hardcoding either one makes a view fail outright in the other kind.  Asked
    in order of how much the answer can be trusted:

      1. What origin says.  `refs/remotes/origin/HEAD` is a symref set at clone
         time and is the only authoritative answer -- it also copes with a trunk
         called neither main nor master.
      2. Which of origin/main, origin/master resolves.  origin/HEAD goes missing
         in older clones and in repos fetched into by hand.
      3. Which of main, master resolves locally, for a repo with no remote.
      4. "main", so callers always get a usable string.  Views guard on whether
         the ref resolves anyway.
    """
    global _trunk
    if _trunk is not None:
        return _trunk

    head = git("symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if head and head.startswith("origin/"):
        _trunk = head[len("origin/"):]
        return _trunk

    for prefix in ("origin/", ""):
        for candidate in ("main", "master"):
            if git("rev-parse", "--verify", "-q", prefix + candidate) is not None:
                _trunk = candidate
                return _trunk

    _trunk = "main"
    return _trunk


def _decorate_refs():
    """Which refs get drawn next to a commit.  Every view wants local branches
    and the trunk on any remote, so screen_log() adds these itself; a view that
    wants more passes them in extra_log_args."""
    return [
        "--decorate-refs=refs/heads/*",
        "--decorate-refs=refs/remotes/*/" + trunk_name(),
    ]

##  Set once per process by screen_log(), so error messages name the view the
##  user actually typed.  A module with a single entry point can afford this.
PROG = "git-log-screen"

USAGE = """\
usage: git %(name)s [--lines=N] [--reserve=N] [--width=N] [--color=WHEN] [git log args...]

Show %(blurb)s, wrapped and trimmed to fit one screen with no pager.

  --lines=N     row budget (default: terminal height minus --reserve)
  --reserve=N   rows to leave free below the output (default: 3)
  --width=N     wrap at N columns (default: terminal width)
  --color=WHEN  always | never | auto (default: auto -- on when stdout is a tty)

Anything else is passed straight to `git log`, so `git %(name)s -5` and
`git %(name)s -- some/path` work.  Naming revisions yourself replaces the ones
this view would have chosen.
"""


def die(message):
    sys.stderr.write("%s: %s\n" % (PROG, message))
    sys.exit(2)


##  ---- display width -------------------------------------------------------
##
##  Everything below measures in terminal columns, never in len().

def char_width(ch):
    if ord(ch) < 32:
        return 0
    if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0                      # combining marks, ZWJ, other format chars
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def visible(text):
    """`text` with its SGR color escapes removed."""
    return SGR.sub("", text)


def width(text):
    return sum(char_width(c) for c in visible(text))


def clip(text, limit):
    """Cut `text` to at most `limit` columns, keeping its color escapes intact."""
    out = []
    used = 0
    i = 0
    while i < len(text):
        match = SGR.match(text, i)
        if match:
            out.append(match.group())
            i = match.end()
            continue
        step = char_width(text[i])
        if used + step > limit:
            break
        out.append(text[i])
        used += step
        i += 1
    return "".join(out)


##  ---- wrapping ------------------------------------------------------------

def first_slice(text, avail):
    """Greedy word wrap: return the end offset of the longest prefix of `text`
    that fits in `avail` columns, breaking on spaces.  The result is a contiguous
    slice, so whatever spacing the subject had inside a line is preserved.  A
    single word wider than `avail` is split mid-word, since the alternative is
    overflowing the screen."""
    end = 0
    i = 0
    n = len(text)
    while i < n:
        start = i
        while start < n and text[start] == " ":
            start += 1
        stop = start
        while stop < n and text[stop] != " ":
            stop += 1
        if stop == start:
            break
        if width(text[:stop]) > avail:
            break
        end = stop
        i = stop
    if end:
        return end
    used = 0
    end = 0
    while end < n:
        step = char_width(text[end])
        if used + step > avail:
            break
        used += step
        end += 1
    return max(end, 1)


def paint(text, colors, start, end, color_on):
    """`text[start:end]`, colored by the per-character `colors` list."""
    if not color_on:
        return text[start:end]
    out = []
    i = start
    while i < end:
        color = colors[i]
        j = i
        while j < end and colors[j] == color:
            j += 1
        out.append(color + text[i:j] + RESET if color else text[i:j])
        i = j
    return "".join(out)


def rails(prefix):
    """The graph prefix as it should look on a continuation line: vertical rails
    keep their glyph and their color, every other glyph (`*`, `/`, `\\`) is blanked
    so the commit's own marker is not repeated."""
    out = []
    i = 0
    while i < len(prefix):
        match = SGR.match(prefix, i)
        if match:
            out.append(match.group())
            i = match.end()
            continue
        ch = prefix[i]
        out.append(ch if ch == "|" else " " * char_width(ch))
        i += 1
    return "".join(out)


##  ---- rendering -----------------------------------------------------------

def render_commit(prefix, sha, date, deco, subject, author, cols, color_on):
    """One commit -> the list of physical rows it occupies."""
    head = prefix + sha + " " + date + " "
    date_col = width(head)                    # where the subject sits with no decoration
    if visible(deco):
        if color_on:
            head += DECO + "(" + RESET + deco + DECO + ")" + RESET + " "
        else:
            head += "(" + deco + ") "

    subject = subject.replace("\t", " ")
    text = subject + " (" + author + ")"
    colors = [WHITE] * len(subject) + [""] + [GREEN] * (len(author) + 2)

    # "(Jonny Reckless)" is one thing to read, so it must not be split across rows.
    # The wrapper only ever breaks on a space, so hide the author's internal spaces
    # behind NBSP: same character count, same display width, but no break point --
    # the whole parenthesized name now moves to the next row as a unit.  Wrapping
    # decisions are made on `flow`, output still comes from `text`, and the two are
    # index-for-index identical.
    flow = subject + " (" + author.replace(" ", NBSP) + ")"

    if cols is None:                          # piped: one row, no wrapping
        return [head + paint(text, colors, 0, len(text), color_on)]

    col = width(head)
    hang = col
    rows = []
    if cols - col < MIN_TEXT:
        # A long ref name has pushed the subject column so far right that there is
        # no usable text column left.  Give the head a row of its own and hang the
        # subject at the date column -- where it would have sat with no decoration
        # at all -- which is both a column the eye already knows and much wider
        # than hanging under the decoration would leave.
        hang = date_col
        rows.append(head)
        if cols - hang < MIN_TEXT:
            # Still no room: a graph deep enough that even the date column is at
            # the right edge.  Give up on alignment and take the columns.
            hang = max(width(prefix), cols - MIN_TEXT)
    cont = rails(prefix) + " " * max(0, hang - width(prefix))

    pos = 0
    while pos < len(flow):
        avail = max(1, cols - (col if not rows else hang))
        end = pos + first_slice(flow[pos:], avail)
        chunk = paint(text, colors, pos, end, color_on)
        rows.append((head if not rows else cont) + chunk)
        pos = end
        while pos < len(flow) and flow[pos] == " ":
            pos += 1
    return rows or [head]


def fit(row, cols, color_on):
    """Last line of defence: no row may be wider than the window, or the screen
    scrolls and the whole exercise is pointless.  Wrapping keeps text rows inside
    the window on its own; this catches the cases wrapping cannot, namely a
    graph-only row on a very wide graph, and a window so narrow that the fixed
    `hash + date` head does not fit in it at all."""
    row = row.rstrip()
    if cols is None or width(row) <= cols:
        return row
    row = clip(row, cols)
    return row + RESET if color_on else row


def render(line, cols, color_on):
    if SEP not in line:
        return [fit(line, cols, color_on)]      # a graph-only row (`|\`, `|/`)
    prefix, rest = line.split(SEP, 1)
    fields = rest.split(SEP)
    if len(fields) < 5:
        return [line.replace(SEP, " ")]
    if len(fields) > 5:
        # A separator inside the subject itself.  Vanishingly rare; keep the
        # field count right rather than mangling the line.
        fields = fields[:3] + [SEP.join(fields[3:-1]), fields[-1]]
    rows = render_commit(prefix, *fields, cols=cols, color_on=color_on)
    return [fit(row, cols, color_on) for row in rows]


##  ---- plumbing ------------------------------------------------------------

def terminal_size():
    for stream in (sys.stdout, sys.stderr):
        try:
            if stream.isatty():
                size = os.get_terminal_size(stream.fileno())
                if size.columns and size.lines:
                    return size.columns, size.lines
        except (OSError, ValueError):
            pass
    try:
        fd = os.open("/dev/tty", os.O_RDONLY)
    except OSError:
        return FALLBACK_SIZE
    try:
        size = os.get_terminal_size(fd)
        return (size.columns or FALLBACK_SIZE[0], size.lines or FALLBACK_SIZE[1])
    except OSError:
        return FALLBACK_SIZE
    finally:
        os.close(fd)


def parse_args(args, name, blurb):
    """Split our own flags out of the argument list.  Everything we do not
    recognize -- and everything after a literal `--` -- goes to git log."""
    opts = {"lines": None, "reserve": RESERVE_DEFAULT, "width": None, "color": "auto"}
    numeric = ("lines", "reserve", "width")
    rest = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            rest.extend(args[i:])
            break
        if arg in ("-h", "--help"):
            sys.stdout.write(USAGE % {"name": name, "blurb": blurb})
            sys.exit(0)
        name, value = None, None
        if arg.startswith("--"):
            name, _, tail = arg[2:].partition("=")
            value = tail if _ else None
        if name in opts:
            if value is None:
                i += 1
                if i >= len(args):
                    die("--%s needs a value" % name)
                value = args[i]
            if name in numeric:
                if not value.isdigit() or int(value) < 1:
                    die("--%s needs a positive integer, got %r" % (name, value))
                opts[name] = int(value)
            else:
                if value not in ("always", "never", "auto"):
                    die("--color must be always, never or auto, got %r" % value)
                opts[name] = value
        else:
            rest.append(arg)
        i += 1
    return opts, rest


def user_named_revisions(args):
    """True if the caller named revisions themselves, in which case the mode's
    own selection steps aside rather than fighting with theirs.  A pathspec
    after `--` is not a revision.

    A separated option value would read as a revision here (`-S foo` looks like
    `foo`), which at worst drops the mode's default selection for that one
    command.  Use the `--opt=value` form to avoid it."""
    for arg in args:
        if arg == "--":
            return False
        if not arg.startswith("-"):
            return True
    return False


def user_capped_count(args):
    """True if the caller already asked for a commit limit, in which case ours
    would only fight with theirs."""
    for arg in args:
        if arg == "--":
            break
        if arg.startswith("--max-count") or arg.startswith("-n") or re.fullmatch(r"-\d+", arg):
            return True
    return False


def screen_log(name, blurb, extra_log_args=(), revs=None, argv=None):
    """Render one view of the log, fitted to the terminal.  Returns an exit code.

    name            the git subcommand this is, e.g. "tree" -- messages only
    blurb           one line for the usage: "Show <blurb>, wrapped and ..."
    extra_log_args  `git log` arguments beyond the ones every view gets, which
                    are --graph, --decorate=short, the date and pretty formats
                    and the decoration refs from _decorate_refs()
    revs            optional callable returning the revisions to ask for.
                    Skipped when the user named revisions themselves, so they
                    always win.
    argv            defaults to sys.argv[1:]; arguments without argv[0]
    """
    global PROG
    PROG = "git-" + name

    opts, passthrough = parse_args(
        list(sys.argv[1:] if argv is None else argv), name, blurb)
    tty = sys.stdout.isatty()
    color_on = {"always": True, "never": False}.get(opts["color"], tty)

    term_cols, term_lines = terminal_size()
    cols = opts["width"] or (term_cols if tty else None)
    if opts["lines"] is not None:
        budget = opts["lines"]
    elif tty:
        budget = max(1, term_lines - opts["reserve"])
    else:
        budget = None

    cmd = ["git", "--no-pager"]
    if color_on:
        cmd += ["-c", "color.ui=always"]
    cmd += ["log", "--graph", "--decorate=short",
            "--date=" + DATE, "--pretty=format:" + PRETTY]
    cmd += _decorate_refs() + list(extra_log_args)
    if revs is not None and not user_named_revisions(passthrough):
        cmd += revs()
    if budget is not None and not user_capped_count(passthrough):
        # A commit costs at least one row, so the budget bounds how many could
        # ever be displayed.  Free, and it keeps git from formatting output we
        # would throw away -- but see the note on --graph and --topo-order in the
        # header: the cap does NOT bound the revision walk itself.
        cmd.append("--max-count=%d" % budget)
    cmd += passthrough

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True, errors="replace")
    emitted = 0
    full = False
    try:
        for raw in proc.stdout:
            for row in render(raw.rstrip("\n"), cols, color_on):
                if budget is not None and emitted >= budget:
                    full = True
                    break
                sys.stdout.write(row + "\n")
                emitted += 1
            if full:
                break
        sys.stdout.flush()
    except BrokenPipeError:
        # Someone closed our stdout (`git trunk | head`).  Redirect the rest of
        # our writes to /dev/null so the interpreter's final flush stays quiet.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        proc.stdout.close()
        proc.wait()
        return 128 + 13
    finally:
        if proc.poll() is None and full:
            proc.stdout.close()       # git gets SIGPIPE and stops walking
            proc.wait()

    if full:
        return 0
    proc.stdout.close()
    return proc.wait()

