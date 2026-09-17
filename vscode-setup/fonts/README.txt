Cascadia Code, from the official release:
  https://github.com/microsoft/cascadia-code/releases/tag/v2407.24
  (asset CascadiaCode-2407.24.zip, files ttf/CascadiaCode.ttf and
  ttf/CascadiaCodeItalic.ttf)

These are bundled here on purpose. install.sh installs them into
~/.local/share/fonts and runs fc-cache, needing no network and no sudo.
Without them it falls back to downloading from GitHub, which means a 150 MB
archive for these two ~740 KB files -- upstream publishes exactly one release
asset containing otf + ttf + woff2 + every static instance, and there is no
lighter one.

editor.fontFamily in settings-fragment.json names the single family "Cascadia
Code". Note that the "Cascadia Code PL" and "Cascadia Code NF" variants, and
the whole "Cascadia Mono" family (which is what Debian/Ubuntu/Mint's
fonts-cascadia-code package provides), are all DIFFERENT families and will not
satisfy it.

Licensed under the SIL Open Font License 1.1 -- see LICENSE in this folder,
which is required to accompany redistribution.
