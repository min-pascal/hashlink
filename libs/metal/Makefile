# Makefile for Metal HDLL
CFLAGS = -fPIC -D HL_METAL -I ../../src -ObjC
FRAMEWORKS = -framework Metal -framework Foundation -framework QuartzCore
LFLAGS = -L../.. -lhl

all: metal.hdll

metal.hdll:
	clang -shared $(CFLAGS) $(FRAMEWORKS) -o ../../metal.hdll metal.m $(LFLAGS)

clean:
	rm -f ../../metal.hdll

.PHONY: all metal.hdll clean
