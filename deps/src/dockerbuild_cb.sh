#!/bin/bash

# this script is run by build.sh within each docker instance to do the build.

set -e

make HOST=$CROSS_TRIPLE
make cleantemp
