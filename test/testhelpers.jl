# convenience function to calculate the mean-squared error
function mse(arr1::AbstractArray, arr2::AbstractArray)
    @assert length(arr1) == length(arr2)
    N = length(arr1)
    err = 0.0
    for i in 1:N
        err += (arr2[i] - arr1[i])^2
    end
    err /= N
end

mse(X::AbstractArray, thresh=1e-8) = Y::AbstractArray -> begin
    if size(X) != size(Y)
        return false
    end

    return mse(X, Y) < thresh
end

issubtype(T::Type) = x -> typeof(x) <: T
lessthan(rhs) = lhs -> lhs < rhs
greaterthan(rhs) = lhs -> lhs > rhs
