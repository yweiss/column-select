# Column Select

A lightweight, native macOS utility that restores **click-and-drag marquee multi-selection** in Finder's **Column View** on **macOS 27.x**.

## What This Fixes
In macOS 27 (including 27.0 – 27.3), a Finder regression treats the entire horizontal row in Column View as a single-file drag target rather than limiting the hit-box to the filename and icon. Clicking and dragging in the empty whitespace to the right of filenames drags a single file instead of selecting multiple rows.

**Column Select** restores expected macOS behavior:
* **Drag in row whitespace:** Selects the clicked row and sweeps across contiguous rows above or below.
* **Single-click in row whitespace:** Selects that row cleanly.
* **Drag on filename, icon, or already-selected rows:** Passes directly through to Finder for normal single- or multi-file drag-and-drop.
* **Live Behavioral Patch Detection:** Probes Finder's Column View Accessibility hit-boxes on launch rather than guessing by OS version, prompting you to disable and trash the app only once Apple actually patches the bug.

---

## Option A: Download the Compiled App
1. Download **`Column.Select.app.zip`** from the [Latest Release](https://github.com/yweiss/column-select/releases/latest).
2. Unzip and move **Column Select.app** into your **`/Applications`** folder.
3. Because the app is ad-hoc signed, right-click **Column Select.app** and choose **Open** on first launch (or run `xattr -cr "/Applications/Column Select.app"` in Terminal).
4. Open **System Settings > Privacy & Security > Accessibility**, click **`+`**, and enable **Column Select.app**.

---

## Option B: Build & Run From Source
Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/yweiss/column-select.git
cd column-select
mkdir -p build/AppIcon.iconset "Column Select.app/Contents/MacOS" "Column Select.app/Contents/Resources"
swift src/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "Column Select.app/Contents/Resources/AppIcon.icns"
cp src/Info.plist "Column Select.app/Contents/Info.plist"
swiftc -O src/main.swift -o "Column Select.app/Contents/MacOS/ColumnSelect"
codesign --force --deep --sign - "Column Select.app"
mv "Column Select.app" /Applications/
open "/Applications/Column Select.app"
```
