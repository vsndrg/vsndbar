# make            build build/VsndBar.app
# make install    copy it to ~/Applications, (re)start the LaunchAgent
# make uninstall  stop and remove the LaunchAgent and the app
#
# Command Line Tools are enough. The target is spelled out: swiftc's default
# minos (the SDK's) makes LaunchServices refuse the app (-10825).

APP      := build/VsndBar.app
DEST     := $(HOME)/Applications/VsndBar.app
STATE    := $(HOME)/.local/state/vsndbar
LABEL    := com.vsndrg.vsndbar
AGENT    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
BIN      := $(HOME)/.local/bin/vsndbar
# the local code signing certificate AeroSpace is signed with (stable identity);
# ad-hoc without it
IDENTITY := $(shell security find-identity -v -p codesigning | grep -q '"aerospace-local-codesign"' && echo aerospace-local-codesign || echo -)

SOURCES  := $(wildcard Sources/*.swift)

all: $(APP)

$(APP): $(SOURCES) Resources/Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	swiftc -O -target arm64-apple-macos26.0 -framework AppKit -framework Carbon -framework SwiftUI -framework IOKit \
	  $(SOURCES) -o $(APP)/Contents/MacOS/VsndBar
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(IDENTITY)" $(APP)
	@touch $(APP)

install: $(APP)
	@mkdir -p $(HOME)/Applications $(STATE) $(dir $(BIN))
	rsync -a --delete $(APP)/ $(DEST)/
	ln -sf $(DEST)/Contents/MacOS/VsndBar $(BIN)
	sed -e 's#@APP@#$(DEST)#' -e 's#@STATE@#$(STATE)#' Resources/launchagent.plist > $(AGENT)
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	@for i in $$(seq 50); do launchctl print gui/$$(id -u)/$(LABEL) >/dev/null 2>&1 || break; sleep 0.1; done
	@# the agent runs `launch`: the app itself is LaunchServices' child
	@pkill -x VsndBar || true
	@for i in $$(seq 50); do pgrep -xq VsndBar || break; sleep 0.1; done
	launchctl bootstrap gui/$$(id -u) $(AGENT)

uninstall:
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	@pkill -x VsndBar || true
	rm -f $(AGENT) $(BIN)
	rm -rf $(DEST)

clean:
	rm -rf build

.PHONY: all install uninstall clean
