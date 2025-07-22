# Makefile for Metal HDLL

CFLAGS = -shared -fPIC -D HL_METAL -I ../../src -I ../sdl
LIBS = -L../.. -lhl -L/usr/local/lib -lSDL2
FRAMEWORKS = -framework Metal -framework Foundation -framework QuartzCore -framework AppKit

# Architecture flags for universal binary
ARCH_FLAGS = -arch x86_64

all: metal.hdll

metal.hdll: metal.m
	$(CC) -ObjC $(ARCH_FLAGS) $(CFLAGS) $(FRAMEWORKS) -o ../../metal.hdll metal.m $(LIBS)

clean:
	rm -f ../../metal.hdll

.PHONY: all clean
