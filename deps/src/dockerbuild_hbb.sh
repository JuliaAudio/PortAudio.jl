#!/bin/bash

# this script is run by build.sh within each docker instance to do the build.
# it's meant to be run from within a "Holy Build Box" docker instance.

set -e

# Activate Holy Build Box environment.
source /hbb_exe/activate

set -x
make HOST=$HOST
make cleantemp
