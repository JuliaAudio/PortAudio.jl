const shim_processcb_c = Ref{Ptr{Cvoid}}(0)
const libpa_shim = Ref{String}("")

function init_pa_shim()
    libdir = joinpath(dirname(@__FILE__), "..", "deps", "usr", "lib")
    libsuffix = ""
    basename = "pa_shim"
    @static if Sys.islinux() && Sys.ARCH == :x86_64
        libsuffix = "x86_64-linux-gnu"
    elseif Sys.islinux() && Sys.ARCH == :i686
        libsuffix = "i686-linux-gnu"
    elseif is_apple() && Sys.ARCH == :x86_64
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
    libpa_shim[]::String = Libdl.find_library(
            [basename, "$(basename)_$libsuffix"],
            [libdir])
    libpa_shim[] == "" && error("Could not load $basename library, please file an issue at https://github.com/JuliaAudio/RingBuffers.jl/issues with your `versioninfo()` output")
    shim_dlib = Libdl.dlopen(libpa_shim[])
    # pointer to the shim's process callback
    shim_processcb_c[] = Libdl.dlsym(shim_dlib, :pa_shim_processcb)
    if shim_processcb_c[] == C_NULL
        error("Got NULL pointer loading `pa_shim_processcb`")
    end
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
    notifycb::Ptr{Nothing} # Julia callback to notify on updates (called from audio thread)
    inputhandle::Ptr{Nothing} # condition to notify on new input data
    outputhandle::Ptr{Nothing} # condition to notify when ready for output
    errorhandle::Ptr{Nothing} # condition to notify on new errors
end

"""
    PortAudio.shimhash()

Return the sha256 hash(as a string) of the source file used to build the shim.
We may use this sometime to verify that the distributed binary stays in sync
with the rest of the package.
"""
function shimhash()
    libname = libpa_shim[]
    return unsafe_string(
        ccall((:pa_shim_getsourcehash::Symbol, libname), Cstring, ()))
end
Base.unsafe_convert(::Type{Ptr{Nothing}}, info::pa_shim_info_t) = pointer_from_objref(info)
