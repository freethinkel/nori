# Outputs are written to a temp file and renamed: Dock maps payload.dylib, and overwriting
# the mapped file in place can crash it.
BUILD = build
SKYLIGHT = -F/System/Library/PrivateFrameworks -framework SkyLight

all: $(BUILD)/niri-mac $(BUILD)/payload.dylib $(BUILD)/loader

$(BUILD)/niri-mac: main.swift | $(BUILD)
	swiftc -O $< -o $@.tmp && mv -f $@.tmp $@

$(BUILD)/payload.dylib: payload.m | $(BUILD)
	clang -arch arm64e -O2 -dynamiclib -framework Foundation -framework CoreGraphics -framework CoreVideo $(SKYLIGHT) $< -o $@.tmp && mv -f $@.tmp $@

$(BUILD)/loader: loader.m | $(BUILD)
	clang -arch arm64e -O2 -framework Cocoa $< -o $@.tmp && mv -f $@.tmp $@

$(BUILD):
	mkdir -p $@

# Restarts Dock with a fresh payload, then runs the daemon in the foreground.
run: all
	-pkill -f $(BUILD)/niri-mac
	killall Dock
	sleep 1
	sudo $(BUILD)/loader
	$(BUILD)/niri-mac

clean:
	rm -rf $(BUILD)

.PHONY: all run clean
