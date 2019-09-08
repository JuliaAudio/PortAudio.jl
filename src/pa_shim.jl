function find_pa_shim()
    libdir = joinpath(@__DIR__, "..", "deps", "usr", "lib")
    libsuffix = ""
    basename = "pa_shim"
    @static if Sys.islinux() && Sys.ARCH == :x86_64
        libsuffix = "x86_64-linux-gnu"
    elseif Sys.islinux() && Sys.ARCH == :i686
        libsuffix = "i686-linux-gnu"
    elseif Sys.isapple() && Sys.ARCH == :x86_64
        libsuffix = "x86_64-apple-darwin14"
    elseif Sys.iswindows() && Sys.ARCH == :x86_64
        libsuffix = "x86_64-w64-mingw32"
    elseif Sys.iswindows() && Sys.ARCH == :i686
        libsuffix = "i686-w64-mingw32"
    elseif !any(
            (sfx) -> isfile(joinpath(libdir, "$basename.$sfx")),
            ("so", "dll", "dylib"))
        error("Unsupported platform $(Sys.MACHINE). You can build your own library by running `make` from $(joinpath(@__FILE__, "..", "deps", "src"))")
    end
    # if there's a suffix-less library, it was built natively on this machine,
    # so load that one first, otherwise load the pre-built one
    libpa_shim = Libdl.find_library(
            [basename, "$(basename)_$libsuffix"],
            [libdir])
    libpa_shim == "" && error("Could not load $basename library, please file an issue at https://github.com/JuliaAudio/RingBuffers.jl/issues with your `versioninfo()` output")
    return libpa_shim
end

const pa_shim_errmsg_t = Cint
const PA_SHIM_ERRMSG_OVERFLOW = Cint(0) # input overflow
const PA_SHIM_ERRMSG_UNDERFLOW = Cint(1) # output underflow
const PA_SHIM_ERRMSG_ERR_OVERFLOW = Cint(2) # error buffer overflowed


# This struct is shared with pa_shim.c
mutable struct pa_shim_info_t
    inputbuf::Ptr{PaUtilRingBuffer} # ringbuffer for input
    outputbuf::Ptr{PaUtilRingBuffer} # ringbuffer for output
    errorbuf::Ptr{PaUtilRingBuffer} # ringbuffer to send error notifications
    sync::Cint # keep input/output ring buffers synchronized (0/1)
    notifycb::Ptr{Cvoid} # Julia callback to notify on updates (called from audio thread)
    inputhandle::Ptr{Cvoid} # condition to notify on new input data
    outputhandle::Ptr{Cvoid} # condition to notify when ready for output
    errorhandle::Ptr{Cvoid} # condition to notify on new errors
    globalhandle::Ptr{Cvoid} # only needed for libuv workaround
end
