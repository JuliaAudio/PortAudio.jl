#!/bin/bash

# User docker to build pa_shim library for all supported platforms.

set -e

make clean

echo ""
# NOTE: the darwin build ends up actually being x86_64-apple-darwin14. It gets
# mapped within the docker machine
for platform in \
    	arm-linux-gnueabihf \
    	powerpc64le-linux-gnu \
    	x86_64-apple-darwin \
    	x86_64-w64-mingw32 \
    	i686-w64-mingw32; do
    echo "================================"
    echo "building for $platform..."
    docker run --rm \
        -v $(pwd)/../..:/workdir \
        -v $(pwd)/../../../RingBuffers:/RingBuffers \
        -w /workdir/deps/src \
        -e CROSS_TRIPLE=$platform \
        multiarch/crossbuild \
        ./dockerbuild_cb.sh
    echo "================================"
    echo ""
done

# we use holy-build-box for the x86 linux builds because it uses an older
# glibc so it should be compatible with more user environments
echo "================================"
echo "building for x86_64-linux-gnu..."
docker run --rm \
    -v $(pwd)/../..:/workdir \
    -v $(pwd)/../../../RingBuffers:/RingBuffers \
    -w /workdir/deps/src \
    -e HOST=x86_64-linux-gnu \
    phusion/holy-build-box-64 \
    ./dockerbuild_hbb.sh
echo "================================"
echo ""

echo "================================"
echo "building for i686-linux-gnu..."
docker run --rm \
    -v $(pwd)/../..:/workdir \
    -v $(pwd)/../../../RingBuffers:/RingBuffers \
    -w /workdir/deps/src \
    -e HOST=i686-linux-gnu \
    phusion/holy-build-box-32 \
    ./dockerbuild_hbb.sh
echo "================================"
