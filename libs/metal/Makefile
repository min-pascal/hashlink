# Makefile for Metal HDLL
CFLAGS = -fPIC -D HL_METAL -I ../../src -ObjC
FRAMEWORKS = -framework Metal -framework Foundation -framework QuartzCore
FRAMEWORKS = -framework Metal -framework Foundation -framework QuartzCore -framework AppKit
LFLAGS = -L../.. -lhl

# Force x86_64 to match HashLink library
ARCH_FLAGS = -arch x86_64

all: metal.hdll

metal.hdll:
	clang -shared $(CFLAGS) $(FRAMEWORKS) -o ../../metal.hdll metal.m $(LFLAGS)
	clang -shared $(CFLAGS) $(ARCH_FLAGS) $(FRAMEWORKS) -o ../../metal.hdll metal.m $(LFLAGS)

clean:
	rm -f ../../metal.hdll

.PHONY: all metal.hdll clean