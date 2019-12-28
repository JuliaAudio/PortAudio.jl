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
