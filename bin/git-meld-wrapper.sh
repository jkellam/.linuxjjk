#!/bin/bash
# git difftool --dir-diff wrapper for Meld.
#
# Meld is pointed DIRECTLY at the temp dirs git hands us ($LOCAL/$REMOTE), so
# git's native dir-diff copy-back keeps working: edits made to the working-tree
# side are copied back to the real working tree when Meld exits, and comparing
# two commits touches nothing. We only add pane labels via `meld -L`; we never
# copy or relocate the dirs (doing so is what previously lost edits).

LEFT="$1"    # $LOCAL  -> left pane  (pre-image: a ref, or the index)
RIGHT="$2"   # $REMOTE -> right pane (post-image: the working tree, or a 2nd ref)

MELD="/usr/bin/meld"

# Recover the revisions the user asked to compare (handed over by the `dt`
# alias via MELD_DIFF_ARGS) so we can label the panes. Drop flags and pathspecs;
# keep only tokens that actually resolve to a commit. Range syntax (A..B, A...B)
# is split into its endpoints (A...B is approximated as A..B for labelling).
revs=()
for tok in $MELD_DIFF_ARGS; do
    case "$tok" in
        --) break ;;      # everything after -- is a pathspec, not a rev
        -*) continue ;;   # skip flags like -d, -r
    esac
    tok="${tok//.../..}"
    if [[ "$tok" == *..* ]]; then
        for r in "${tok%%..*}" "${tok##*..}"; do
            [ -n "$r" ] && git rev-parse --verify --quiet "${r}^{commit}" >/dev/null 2>&1 && revs+=("$r")
        done
    else
        git rev-parse --verify --quiet "${tok}^{commit}" >/dev/null 2>&1 && revs+=("$tok")
    fi
done

label() {  # -> "name (shorthash)"
    local r="$1" h
    h=$(git rev-parse --short "$r" 2>/dev/null)
    if [ -n "$h" ]; then echo "$r ($h)"; else echo "$r"; fi
}

case "${#revs[@]}" in
    0) LEFT_LABEL="index";                  RIGHT_LABEL="working tree" ;;
    1) LEFT_LABEL="$(label "${revs[0]}")";   RIGHT_LABEL="working tree" ;;
    *) LEFT_LABEL="$(label "${revs[0]}")";   RIGHT_LABEL="$(label "${revs[1]}")" ;;
esac

"$MELD" -L "$LEFT_LABEL" -L "$RIGHT_LABEL" "$LEFT" "$RIGHT"
