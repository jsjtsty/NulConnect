# dmgbuild settings for the NulConnect disk image (used by make-dmg.sh).
#
# dmgbuild writes the Finder layout (.DS_Store) itself instead of scripting
# Finder, so the result does not depend on the Finder preferences of the
# machine that builds it (tab bar, path bar, ...) and also works on headless
# CI runners.
#
# Defines passed by make-dmg.sh: app (path to the .app bundle).

import os.path

app = defines["app"]  # noqa: F821 - injected by dmgbuild
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# The window bounds include the title bar (about 28 pt), so the icon area is
# 640 x ~352. Icon positions are icon centers; with the label below each
# icon, y = 160 centres the icon-plus-label group vertically.
window_rect = ((200, 120), (640, 380))
icon_size = 128
text_size = 14
icon_locations = {
    app_name: (170, 160),
    "Applications": (470, 160),
}

default_view = "icon-view"
arrange_by = None
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
