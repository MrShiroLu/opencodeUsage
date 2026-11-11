APP = build/OpenCodeMeter.app
BIN = $(APP)/Contents/MacOS/OpenCodeMeter
TARGET = $(HOME)/Applications/OpenCodeMeter.app

.PHONY: build run install uninstall print render icon clean

build:
	./build.sh

run: build
	open $(APP)

install: build
	mkdir -p $(HOME)/Applications
	rm -rf $(TARGET)
	cp -R $(APP) $(HOME)/Applications/
	@echo "Installed $(TARGET)"

uninstall:
	pkill -f "Applications/OpenCodeMeter.app" || true
	rm -rf $(TARGET)
	@echo "Removed $(TARGET)"

print: build
	OCMETER_PRINT=1 $(BIN)

render: build
	OCMETER_DEMO=1 OCMETER_RENDER=docs/preview.png $(BIN)
	OCMETER_DEMO=1 OCMETER_RENDER=docs/welcome.png OCMETER_WELCOME=1 $(BIN)

icon: build
	swiftc -O -o build/make-icon Support/make-icon.swift
	build/make-icon docs/icon.png

clean:
	rm -rf build
