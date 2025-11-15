
CFLAGS = -shared -fPIC -D HL_SDL -I ../../src -DGL_SILENCE_DEPRECATION
LIBS = -L../.. -lhl

# Detect macOS
UNAME := $(shell uname)
ifeq ($(UNAME),Darwin)
  # macOS specific settings
  BREW_PREFIX := $(shell arch -x86_64 /usr/local/bin/brew --prefix)
  SDL_INCLUDE = -I$(BREW_PREFIX)/include
  SDL_LIB = -L$(BREW_PREFIX)/lib -lSDL2
  FRAMEWORKS = -framework OpenGL -framework CoreFoundation
else
  # Linux/Windows settings
  SDL_INCLUDE = 
  SDL_LIB = -lSDL2
  FRAMEWORKS = -lGL
endif

all: sdl.hdll

sdl.hdll: sdl.c gl.c
	$(CC) $(CFLAGS) $(SDL_INCLUDE) -o ../../sdl.hdll sdl.c gl.c $(LIBS) $(SDL_LIB) $(FRAMEWORKS)

clean:
	rm -f ../../sdl.hdll

.PHONY: all clean
