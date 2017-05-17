function init_pa_shim()
    global const libpa_shim = Libdl.find_library(
            ["pa_shim"],
            [joinpath(dirname(@__FILE__), "..", "deps", "usr", "lib")])
    shim_dlib = Libdl.dlopen(libpa_shim)
    # pointer to the shim's process callback
    global const shim_processcb_c = Libdl.dlsym(shim_dlib, :pa_shim_processcb)
    if shim_processcb_c == C_NULL
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
    notifycb::Ptr{Void} # Julia callback to notify on updates (called from audio thread)
    inputhandle::Ptr{Void} # condition to notify on new input data
    outputhandle::Ptr{Void} # condition to notify when ready for output
    errorhandle::Ptr{Void} # condition to notify on new errors
end

"""
    PortAudio.shimhash()

Return the sha256 hash(as a string) of the source file used to build the shim.
We may use this sometime to verify that the distributed binary stays in sync
with the rest of the package.
"""
shimhash() = unsafe_string(
        ccall((:pa_shim_getsourcehash, libpa_shim), Cstring, ()))
Base.unsafe_convert(::Type{Ptr{Void}}, info::pa_shim_info_t) = pointer_from_objref(info)
