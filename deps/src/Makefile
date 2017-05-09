# Makefile lifted from Clang.jl
# Copyright (c) 2012-: Isaiah Norton and [contributors](https://github.com/ihnorton/Clang.jl/graphs/contributors)

ifeq (exists, $(shell [ -e Make.user ] && echo exists ))
include Make.user
endif

#check-env:
#ifndef JULIA_INC
#        $(error Environment variable JULIA_INC is not set.)
#endif

#INC =-I"$(JULIA_INC)"
CFLAGS =-Wall -Wno-strict-aliasing -fno-omit-frame-pointer -fPIC -g
LDFLAGS =-L../../../RingBuffers/deps/usr/lib -lpa_ringbuffer
# LINUX_LIBS =-lrt
# LINUX_LDFLAGS =-rdynamic
# add the Homebrew.jl tree to the include dirs in case we used it for
# portaudio and libsndfile
# DARWIN_LDFLAGS =-L../../../Homebrew/deps/usr/lib
# DARWIN_INC =-I../../../Homebrew/deps/usr/include
TARGETDIR=../usr/lib

OBJS = pa_shim.o

# Figure out OS and architecture
OS = $(shell uname)
ifneq (,$(findstring MINGW,$(OS)))
  OS=WINNT
endif

# file extensions and platform-specific libs
ifeq ($(OS), WINNT)
  LIBS += $(WINNT_LIBS)
  LDFLAGS += $(WINNT_LDFLAGS)
  INC += $(WINNT_INC)
  SHLIB_EXT = dll
else ifeq ($(OS), Darwin)
  INC += $(DARWIN_INC)
  LDFLAGS += $(DARWIN_LDFLAGS)
  SHLIB_EXT = dylib
else
  LIBS += $(LINUX_LIBS)
  LDFLAGS += $(LINUX_LDFLAGS)
  INC += $(LINUX_INC)
  SHLIB_EXT = so
endif

TARGET=$(TARGETDIR)/pa_shim.$(SHLIB_EXT)

.PHONY: clean default

default: $(TARGET)

%.o: %.c Makefile
	$(CC) $< -fPIC -c -o $@ $(INC) $(CFLAGS)

$(TARGETDIR):
	mkdir -p $@

$(TARGET): $(OBJS) $(TARGETDIR) Makefile
	$(CC) $(OBJS) -shared -o $@ $(LDFLAGS) $(LIBS)

clean:
	rm -f $(OBJS)
	rm -f $(TARGET)
