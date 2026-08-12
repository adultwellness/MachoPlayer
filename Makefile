APP_NAME := MachoPlayer
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
CC := xcrun --sdk macosx clang
CXX := xcrun --sdk macosx clang++
ARCHS ?= arm64 x86_64
ARCH_FLAGS := $(foreach ARCH,$(ARCHS),-arch $(ARCH))
MACOSX_DEPLOYMENT_TARGET ?= 11.0

CORE_SOURCES := \
	Core/CocoaFuncs.m \
	Core/DelayOutPut.c \
	Core/Effects.c \
	Core/FileUtils.c \
	Core/Interrupt.c \
	Core/MADDriver.c \
	Core/MainDriver.c \
	Core/MIDI-Hardware-OSX.c \
	Core/MyDebugStr.c \
	Core/OutPut8.c \
	Core/OSX-CoreAudio.c \
	Core/realft.c \
	Core/SndUtils.c \
	Core/stub-VSTPlugIn.c \
	Core/TickRemover.c \
	Core/iOS-PlugImport.c

IMPORT_SOURCES := \
	Core/Import-Export/669/669.c \
	Core/Import-Export/AMF/AMF.c \
	Core/Import-Export/DMF/DMF.c \
	Core/Import-Export/IT/IT.c \
	Core/Import-Export/MADfg/MADfg.c \
	Core/Import-Export/MADH/MADH.c \
	Core/Import-Export/MADI/MADI.c \
	Core/Import-Export/MED/MED.c \
	Core/Import-Export/MOD/Mod.c \
	Core/Import-Export/MTM/MTM.c \
	Core/Import-Export/Okta/Okta.c \
	Core/Import-Export/S3M/S3M.c \
	Core/Import-Export/ULT/ULT.c \
	Core/Import-Export/UMX/UMX.c \
	Core/Import-Export/XM/XM.c

APP_SOURCES := App/main.m App/PPApplicationController.m App/PPPreferences.m App/PPPatternCommandCodec.m App/PPSampleEditorController.m App/PPInstrumentEditorController.m App/PPPatternModeController.m App/PPMixerController.m App/PPPianoController.m App/PPEqualizerController.m
SOURCES := $(CORE_SOURCES) $(IMPORT_SOURCES) $(APP_SOURCES)

FREEVERB_HEADERS := Resources/freeverb\ dsp/allpass.hpp Resources/freeverb\ dsp/comb.hpp Resources/freeverb\ dsp/denormals.h Resources/freeverb\ dsp/revmodel.hpp Resources/freeverb\ dsp/tuning.h
FREEVERB_OBJECTS := $(BUILD_DIR)/freeverb/allpass.o $(BUILD_DIR)/freeverb/comb.o $(BUILD_DIR)/freeverb/revmodel.o $(BUILD_DIR)/freeverb/bridge.o

CFLAGS := \
	-isysroot $(SDK) \
	-mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) \
	$(ARCH_FLAGS) \
	-std=gnu11 \
	-fobjc-arc \
	-fblocks \
	-fpascal-strings \
	-fno-common \
	-I Core \
	-DEMBEDPLUGS=1 \
	-DBUILDINGPPRO=1 \
	-DUSEDEPRECATEDFUNCS=0 \
	-Wall \
	-Wextra \
	-Wno-deprecated-declarations \
	-Wno-four-char-constants \
	-Wno-missing-field-initializers \
	-Wno-sign-conversion \
	-Wno-unused-parameter \
	-Wno-unused-variable \
	-Werror=unguarded-availability-new

CXXFLAGS := \
	-isysroot $(SDK) \
	-mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) \
	$(ARCH_FLAGS) \
	-std=gnu++17 \
	-I"Resources/freeverb dsp" \
	-Wall \
	-Wextra \
	-Wno-strict-aliasing \
	-Werror=unguarded-availability-new

FRAMEWORKS := \
	-framework Cocoa \
	-framework CoreFoundation \
	-framework AudioToolbox \
	-framework AudioUnit \
	-framework CoreMIDI

.PHONY: all app clean verify

all: app

app: $(EXECUTABLE)

CLASSIC_RESOURCES := $(shell find Resources/Classic Resources/Transport -type f)

$(BUILD_DIR)/freeverb/allpass.o: Resources/freeverb\ dsp/allpass.cpp $(FREEVERB_HEADERS)
	mkdir -p "$(BUILD_DIR)/freeverb"
	$(CXX) $(CXXFLAGS) -c "$<" -o "$@"

$(BUILD_DIR)/freeverb/comb.o: Resources/freeverb\ dsp/comb.cpp $(FREEVERB_HEADERS)
	mkdir -p "$(BUILD_DIR)/freeverb"
	$(CXX) $(CXXFLAGS) -c "$<" -o "$@"

$(BUILD_DIR)/freeverb/revmodel.o: Resources/freeverb\ dsp/revmodel.cpp $(FREEVERB_HEADERS)
	mkdir -p "$(BUILD_DIR)/freeverb"
	$(CXX) $(CXXFLAGS) -c "$<" -o "$@"

$(BUILD_DIR)/freeverb/bridge.o: App/PPFreeverbDSP.cpp App/PPFreeverbDSP.h $(FREEVERB_HEADERS)
	mkdir -p "$(BUILD_DIR)/freeverb"
	$(CXX) $(CXXFLAGS) -c "$<" -o "$@"

$(EXECUTABLE): Makefile $(SOURCES) $(FREEVERB_OBJECTS) Info.plist Resources/PlayerPROIcons.icns $(CLASSIC_RESOURCES)
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	$(CC) $(CFLAGS) $(SOURCES) $(FREEVERB_OBJECTS) $(FRAMEWORKS) -lc++ -o "$@"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp Resources/PlayerPROIcons.icns "$(APP_BUNDLE)/Contents/Resources/PlayerPROIcons.icns"
	cp -R Resources/Classic Resources/Transport "$(APP_BUNDLE)/Contents/Resources/"
	xattr -cr "$(APP_BUNDLE)"
	codesign --force --sign - "$(APP_BUNDLE)"

verify: app
	file "$(EXECUTABLE)"
	lipo "$(EXECUTABLE)" -verify_arch arm64 x86_64
	xcrun vtool -show-build "$(EXECUTABLE)"
	plutil -lint "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --verify --deep --strict "$(APP_BUNDLE)"
	"$(EXECUTABLE)" --self-test "../MADDriver.source/AutoExec/Test"

clean:
	rm -rf "$(BUILD_DIR)"
