#!/bin/bash

# Runs the tests including generating an lcov.info file

# abort on failure
set -e

julia -e 'using Coverage; clean_folder(".");'
julia --color=yes --inline=no --code-coverage=user test/runtests.jl
mkdir -p coverage
julia -e 'using Coverage; res=process_folder(); LCOV.writefile("coverage/lcov.info", res)'
