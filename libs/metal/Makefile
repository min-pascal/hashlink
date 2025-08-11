# Makefile for Metal library

CFLAGS = -Wall -O3 -I ../../src -std=c99 -fPIC -fobjc-arc
LIBS = -L../.. -lhl -L/usr/local/lib -lSDL2
ARCH_FLAGS = -arch x86_64

UNAME := $(shell uname)

ifeq ($(UNAME),Darwin)
	# macOS
	LIB = metal.hdll
	INSTALL_DIR = $(HAXE_STD_PATH)/darwin/lib
	CFLAGS += $(ARCH_FLAGS) -Wl,-install_name,@loader_path/metal.hdll
	FRAMEWORKS = -framework Metal -framework Foundation -framework QuartzCore -framework AppKit -framework MetalKit
	LIBFLAGS = -bundle -undefined dynamic_lookup $(ARCH_FLAGS)
endif

# Source files
SOURCES = metal.m

# Object files (will be generated from sources)
OBJECTS = $(SOURCES:.m=.o)

# Default target
all: $(LIB)

# Rule to create the dynamic library
$(LIB): $(OBJECTS)
	${CC} $(LIBFLAGS) -o ../../$(LIB) $^ $(LIBS) $(FRAMEWORKS)
	@rm -f $(OBJECTS)

# Rule to compile .m files to .o files
%.o: %.m metal.h
	${CC} ${CFLAGS} -o $@ -c $<

install: $(LIB)
	cp $(LIB) $(INSTALL_DIR)

clean:
	rm -rf $(OBJECTS) ../../$(LIB)

.PHONY: all clean install

.SUFFIXES: .m .o