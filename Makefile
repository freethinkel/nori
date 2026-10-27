# Outputs are written to a temp file and renamed: Dock maps payload.dylib, and overwriting
# the mapped file in place can crash it.
BUILD = build
SKYLIGHT = -F/System/Library/PrivateFrameworks -framework SkyLight

APP = $(BUILD)/Nori.app

all: $(BUILD)/nori $(BUILD)/payload.dylib $(BUILD)/loader

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
# ponytail: ad-hoc signed, so macOS may ask for Accessibility again after a rebuild; sign with a real identity to stop that.
app: all
	rm -rf $(APP).tmp
	mkdir -p $(APP).tmp/Contents/MacOS $(APP).tmp/Contents/Resources
	cp app/Info.plist $(APP).tmp/Contents/
	cp assets/AppIcon.icns $(APP).tmp/Contents/Resources/
	cp $(BUILD)/nori $(BUILD)/loader $(BUILD)/payload.dylib $(APP).tmp/Contents/MacOS/
	codesign --force --sign - $(APP).tmp/Contents/MacOS/loader $(APP).tmp/Contents/MacOS/payload.dylib
	codesign --force --sign - $(APP).tmp
	rm -rf $(APP)
	mv $(APP).tmp $(APP)

# Regenerates the app icon from assets/icon.svg. Needs rsvg-convert (brew install librsvg).
icon:
	rm -rf $(BUILD)/AppIcon.iconset && mkdir -p $(BUILD)/AppIcon.iconset
	for n in 16 32 128 256 512; do \
		rsvg-convert -w $$n -h $$n assets/icon.svg -o $(BUILD)/AppIcon.iconset/icon_$${n}x$${n}.png; \
		rsvg-convert -w $$((n * 2)) -h $$((n * 2)) assets/icon.svg -o $(BUILD)/AppIcon.iconset/icon_$${n}x$${n}@2x.png; \
	done
	iconutil -c icns $(BUILD)/AppIcon.iconset -o assets/AppIcon.icns

clean:
	rm -rf $(BUILD)

.PHONY: all run app icon clean
