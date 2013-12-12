# Makefile lifted from Clang.jl

all: default

ifeq (exists, $(shell [ -e Make.user ] && echo exists ))
include Make.user
endif

.PHONY: all clean check-env default

#check-env:
#ifndef JULIA_ROOT
#        $(error Environment variable JULIA_ROOT is not set.)
#endif

INC =-I"$(JULIA_ROOT)/usr/include"
FLAGS =-Wall -Wno-strict-aliasing -fno-omit-frame-pointer -fPIC
CFLAGS =-g
LIBS =

OBJS = shim.o
# libm can be removed later, it's just for the sin function used in testing
LIBS += -lportaudio -lm

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

default: portaudio_shim.$(SHLIB_EXT)

%.o: %.c
	$(CC) $< -fPIC -c -o $@ $(INC) $(CFLAGS) $(FLAGS)

portaudio_shim.$(SHLIB_EXT): $(OBJS)
	$(CC) $(OBJS) -rdynamic -shared -o $@ $(LDFLAGS) $(LIBS)

clean:
	rm -f *.o *.$(SHLIB_EXT)
