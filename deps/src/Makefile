# Makefile lifted from Clang.jl

all: default

ifeq (exists, $(shell [ -e Make.user ] && echo exists ))
include Make.user
endif

.PHONY: all clean check-env default

#check-env:
#ifndef JULIA_INC
#        $(error Environment variable JULIA_INC is not set.)
#endif

#INC =-I"$(JULIA_INC)"
FLAGS =-Wall -Wno-strict-aliasing -fno-omit-frame-pointer -fPIC
CFLAGS =-g
LIBS =-lportaudio -lrt

OBJS = shim.o

# Figure out OS and architecture
OS = $(shell uname)
ifeq ($(OS), MINGW32_NT-6.1)
  OS=WINNT
endif

# file extensions
ifeq ($(OS), WINNT)
  SHLIB_EXT = dll
else ifeq ($(OS), Darwin)
  SHLIB_EXT = dylib
else
  SHLIB_EXT = so
endif

default: libportaudio_shim.$(SHLIB_EXT)

%.o: %.c
	$(CC) $< -fPIC -c -o $@ $(INC) $(CFLAGS) $(FLAGS)

libportaudio_shim.$(SHLIB_EXT): $(OBJS)
	$(CC) $(OBJS) -rdynamic -shared -o $@ $(LDFLAGS) $(LIBS)

clean:
	rm -f *.o *.$(SHLIB_EXT)
