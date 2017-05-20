# while waiting for this PR to get merged: https://github.com/Ismael-VC/Suppressor.jl/pull/12
# we'll just include the relevant code here

macro suppress_err(block)
    quote
        if ccall(:jl_generating_output, Cint, ()) == 0
            ORIGINAL_STDERR = STDERR
            err_rd, err_wr = redirect_stderr()
            err_reader = @async readstring(err_rd)
        end

        value = $(esc(block))

        if ccall(:jl_generating_output, Cint, ()) == 0
            redirect_stderr(ORIGINAL_STDERR)
            close(err_wr)
        end
        value
    end
end
