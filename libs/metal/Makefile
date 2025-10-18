# Makefile for Metal library

BUILD_OUTPUT_DIR ?= ../../build-arm64

CFLAGS = -Wall -O3 -I ../../src -std=c99 -fPIC -fobjc-arc
LIBS = -L$(BUILD_OUTPUT_DIR) -lhl -L/opt/homebrew/lib -lSDL2
ARCH_FLAGS = -arch arm64

UNAME := $(shell uname)

ifeq ($(UNAME),Darwin)
	# macOS
	LIB = metal.hdll
	INSTALL_DIR = $(HAXE_STD_PATH)/darwin/lib
	CFLAGS += $(ARCH_FLAGS)
	FRAMEWORKS = -framework Metal -framework Foundation -framework QuartzCore -framework AppKit -framework MetalKit
	# Changed from -bundle to -dynamiclib so it can be linked at compile time (needed for ARM64 native builds)
	LIBFLAGS = -dynamiclib -undefined dynamic_lookup $(ARCH_FLAGS) -Wl,-install_name,@rpath/metal.hdll
endif

# Source files
SOURCES = metal.m

# Object files (will be generated from sources)
OBJECTS = $(SOURCES:.m=.o)

# Default target
all: $(LIB)

# Rule to create the dynamic library
$(LIB): $(OBJECTS)
	mkdir -p $(BUILD_OUTPUT_DIR)
	${CC} $(LIBFLAGS) -o $(BUILD_OUTPUT_DIR)/$(LIB) $^ $(LIBS) $(FRAMEWORKS)
	@rm -f $(OBJECTS)

# Rule to compile .m files to .o files
%.o: %.m metal.h
	${CC} ${CFLAGS} -o $@ -c $<

install: $(LIB)
	cp $(BUILD_OUTPUT_DIR)/$(LIB) $(INSTALL_DIR)

clean:
	rm -rf $(OBJECTS) $(BUILD_OUTPUT_DIR)/$(LIB)

.PHONY: all clean install

.SUFFIXES: .m .o