#!/usr/bin/env julia

test_regex = r"^test_.*\.jl$"
test_dir = "test"

test_files = filter(n -> ismatch(test_regex, n), readdir(test_dir))
if length(test_files) == 0
    error("No test files found. Make sure you're running from the root directory")
end

# convenience function to calculate the mean-squared error
function mse(arr1::Array, arr2::Array)
    @assert length(arr1) == length(arr2)
    N = length(arr1)
    err = 0.0
    for i in 1:N
        err += (arr2[i] - arr1[i])^2
    end
    err /= N
end

for test_file in test_files
    info("")
    info("Running tests from \"$(test_file)\"...")
    info("===================================================================")
    include(test_file)
    info("===================================================================")
end
