name := mac-input-tweaks
label := local.$(name)
binary := $(HOME)/.local/bin/$(name)
agent := $(HOME)/Library/LaunchAgents/$(label).plist
domain := gui/$(shell id -u)

.PHONY: install uninstall

# A rebuild changes the ad-hoc signature, and macOS then drops the Accessibility permission
$(binary): main.swift
	mkdir -p $(dir $@)
	swiftc -O main.swift -o $@

install: $(binary)
	sed -e 's|@BINARY@|$(binary)|' -e 's|@LABEL@|$(label)|g' launch-agent.plist > $(agent)
	launchctl bootout $(domain)/$(label) 2>/dev/null || true
	launchctl bootstrap $(domain) $(agent)

uninstall:
	launchctl bootout $(domain)/$(label) 2>/dev/null || true
	rm -f $(agent) $(binary)
