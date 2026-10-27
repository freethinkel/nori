# Outputs are written to a temp file and renamed: Dock maps payload.dylib, and overwriting
# the mapped file in place can crash it.
BUILD = build
SKYLIGHT = -F/System/Library/PrivateFrameworks -framework SkyLight

APP = $(BUILD)/Nori.app
DMG = $(BUILD)/Nori.dmg

# Ad-hoc by default. A real identity (make app SIGN="Developer ID Application") also gets the hardened runtime
# and a secure timestamp, which notarization requires.
SIGN ?= -
CODESIGN = codesign --force --sign "$(SIGN)" $(if $(filter -,$(SIGN)),,--options runtime --timestamp)

all: $(BUILD)/nori $(BUILD)/payload.dylib $(BUILD)/loader $(BUILD)/status.png

$(BUILD)/status.png: assets/status.png | $(BUILD)
	cp $< $@

$(BUILD)/nori: $(wildcard daemon/*.swift) | $(BUILD)
	swiftc -O $^ -o $@.tmp && mv -f $@.tmp $@

$(BUILD)/payload.dylib: payload/payload.m | $(BUILD)
	clang -arch arm64e -O2 -dynamiclib -framework Foundation -framework CoreGraphics -framework CoreVideo $(SKYLIGHT) $< -o $@.tmp && mv -f $@.tmp $@

$(BUILD)/loader: loader/loader.m | $(BUILD)
	clang -arch arm64e -O2 -framework Cocoa $< -o $@.tmp && mv -f $@.tmp $@

$(BUILD):
	mkdir -p $@

# Restarts Dock with a fresh payload, then runs the daemon in the foreground.
run: all
	-pkill -f $(BUILD)/nori
	killall Dock
	sleep 1
	sudo $(BUILD)/loader $(abspath $(BUILD)/payload.dylib)
	$(BUILD)/nori

# The menu bar app: the same three binaries, side by side in Contents/MacOS. It sets itself up on launch, see App.swift.
# Built next to the old bundle and swapped in, so Dock keeps its mapped payload until it restarts.
# Ad-hoc signed, macOS may ask for Accessibility again after a rebuild; a real SIGN identity stops that.
app: all
	rm -rf $(APP).tmp
	mkdir -p $(APP).tmp/Contents/MacOS $(APP).tmp/Contents/Resources
	cp app/Info.plist $(APP).tmp/Contents/
	cp assets/AppIcon.icns assets/status.png $(APP).tmp/Contents/Resources/
	cp $(BUILD)/nori $(BUILD)/loader $(BUILD)/payload.dylib $(APP).tmp/Contents/MacOS/
	$(CODESIGN) $(APP).tmp/Contents/MacOS/loader $(APP).tmp/Contents/MacOS/payload.dylib
	$(CODESIGN) $(APP).tmp
	rm -rf $(APP)
	mv $(APP).tmp $(APP)

# The app in a dmg next to an Applications link, on assets/dmg-background.png (assets/dmg.py), signed like the app.
dmg: app
	rm -f $(DMG)
	pipx run --spec dmgbuild==1.6.7 dmgbuild -s assets/dmg.py -D app=$(APP) Nori $(DMG)
	$(if $(filter -,$(SIGN)),,codesign --force --timestamp --sign "$(SIGN)" $(DMG))

# Regenerates the app icon from assets/icon.png (1024, already masked to the macOS squircle).
icon:
	rm -rf $(BUILD)/AppIcon.iconset && mkdir -p $(BUILD)/AppIcon.iconset
	for n in 16 32 128 256 512; do \
		sips -z $$n $$n assets/icon.png --out $(BUILD)/AppIcon.iconset/icon_$${n}x$${n}.png >/dev/null; \
		sips -z $$((n * 2)) $$((n * 2)) assets/icon.png --out $(BUILD)/AppIcon.iconset/icon_$${n}x$${n}@2x.png >/dev/null; \
	done
	iconutil -c icns $(BUILD)/AppIcon.iconset -o assets/AppIcon.icns

version:  # app/Info.plist's version, which a push to main releases (.github/workflows/build.yml)
	@plutil -extract CFBundleShortVersionString raw app/Info.plist

test: | $(BUILD)
	swiftc daemon/TOML.swift daemon/Scroll.swift daemon/Rules.swift daemon/Config.swift test/main.swift -o $(BUILD)/test && $(BUILD)/test

clean:
	rm -rf $(BUILD)

.PHONY: all run app dmg icon version test clean
