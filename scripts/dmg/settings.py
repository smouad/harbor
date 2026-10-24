# dmgbuild settings for the installer window (scripts/make-dmg.sh passes the paths as -D defines).
# The window, icon size and icon positions were read from the first installer's Finder layout.
app = defines["app"]
background = defines["background"]
icon = defines["icon"]

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_size = 112
text_size = 13
window_rect = ((240, 160), (600, 400))
icon_locations = {"Harbor.app": (165, 196), "Applications": (435, 196)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
