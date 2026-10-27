# dmgbuild settings for Nori.dmg (make dmg): the app next to an Applications link, on dmg-background.png
# (and its @2x, which dmgbuild picks up for Retina). The icons sit on either side of the background's arrow.
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
background = "assets/dmg-background.png"  # make runs from the repo root
format = "UDZO"
window_rect = ((200, 120), (660, 432))  # 400 for the background, 32 for the title bar
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (165, 200), "Applications": (495, 200)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
