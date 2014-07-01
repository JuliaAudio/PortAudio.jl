#!/usr/bin/env julia

using FactCheck

test_regex = r"^test_.*\.jl$"
test_dir = "test"

test_files = filter(n -> ismatch(test_regex, n), readdir(test_dir))
if length(test_files) == 0
    error("No test files found. Make sure you're running from the root directory")
end

for test_file in test_files
    include(test_file)
end

# return the overall exit status
exitstatus()
