# Makefile originally lifted from Clang.jl
# Copyright (c) 2012-: Isaiah Norton and [contributors](https://github.com/ihnorton/Clang.jl/graphs/contributors)

ifeq (exists, $(shell [ -e Make.user ] && echo exists ))
include Make.user
endif

TARGETDIR=../usr/lib
TARGETBASENAME=pa_shim
OBJS = pa_shim.o

# check to see if the user passed in a HOST variable for cross-compiling
ifeq ($(HOST),)
	# Figure out OS and architecture
	OS=$(shell uname)
	ifneq ($(findstring MINGW,$(OS)),)
		OS=WINNT
	endif
else
	HOSTSUFFIX=_$(HOST)
	ifneq ($(findstring linux,$(HOST)),)
		OS=Linux
	else ifneq ($(findstring darwin,$(HOST)),)
		OS=Darwin
	else ifneq ($(findstring mingw,$(HOST)),)
		OS=WINNT
	endif
endif

CFLAGS = -Wall -Wno-strict-aliasing -fno-omit-frame-pointer -I../../../RingBuffers/deps/src
LDFLAGS +=

ifeq ($(OS), WINNT)
	LIBS +=
	LDFLAGS += -shared -L../../../RingBuffers/deps/usr/lib -lpa_ringbuffer$(HOSTSUFFIX)
	INC +=
	SHACMD = sha256sum
	SHLIB_EXT = dll
else ifeq ($(OS), Darwin)
	LIBS +=
	INC +=
	# we'll rely on Julia to load RingBuffers.jl, which will in turn load the C
	# library that we depend on for these symbols
	LDFLAGS += -dynamiclib -Wl,-undefined,dynamic_lookup
	SHLIB_EXT = dylib
	SHACMD = shasum -a256
else
	CFLAGS += -fPIC
	LIBS +=
	INC +=
	LDFLAGS += -shared
	SHLIB_EXT = so
	SHACMD = sha256sum
endif

SOURCEHASH = $(shell $(SHACMD) pa_shim.c | awk '{print $$1}')
CFLAGS += -DSOURCEHASH=\"$(SOURCEHASH)\"

TARGET=$(TARGETDIR)/$(TARGETBASENAME)$(HOSTSUFFIX).$(SHLIB_EXT)

.PHONY: clean cleantemp default

default: $(TARGET)

%.o: %.c Makefile
	$(CC) $< -c -o $@ $(INC) $(CFLAGS)

$(TARGETDIR):
	mkdir -p $@

$(TARGET): $(OBJS) $(TARGETDIR) Makefile
	$(CC) $(OBJS) $(LDFLAGS) -o $@ $(LIBS)

cleantemp:
	rm -f $(OBJS)

clean: cleantemp
	rm -f $(TARGETDIR)/$(TARGETBASENAME)*.so
	rm -f $(TARGETDIR)/$(TARGETBASENAME)*.dylib
	rm -f $(TARGETDIR)/$(TARGETBASENAME)*.dll
