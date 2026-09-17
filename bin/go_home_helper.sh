#!/usr/bin/env bash
##----------------------------------------------------------------------------
## go_home_helper.sh
##
## Switches the monitor to its DisplayPort input, for use from a desktop
## keybinding.  The work is done by the "home" shell function in .aliases.
##
## A keybinding runs a non-interactive shell, so none of the shell setup has
## happened yet.  bashrc_jjk is sourced instead of .bashrc because .bashrc
## returns immediately when the shell is not interactive, before it gets as
## far as the linuxjjk hook.
##----------------------------------------------------------------------------
source "$(dirname "$(realpath "$0")")/../bashrc_jjk" || exit 1

##  A keybinding has no terminal, so change_input's complaint goes nowhere.
if ! home; then
    notify-send -u critical "go_home_helper" \
                "Could not switch the monitor to DisplayPort"
    exit 1
fi
