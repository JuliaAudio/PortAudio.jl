# Low-level wrappers for Portaudio calls

# General type aliases
typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong

const PA_NO_ERROR = 0
const PA_INPUT_OVERFLOWED = -10000 + 19
const PA_OUTPUT_UNDERFLOWED = -10000 + 20

const paFloat32 = PaSampleFormat(0x01)
const paInt32   = PaSampleFormat(0x02)
const paInt24   = PaSampleFormat(0x04)
const paInt16   = PaSampleFormat(0x08)
const paInt8    = PaSampleFormat(0x10)
const paUInt8   = PaSampleFormat(0x20)

@compat const pa_sample_formats = Dict{PaSampleFormat, Type}(
    1  => Float32
    2  => Int32
    4  => Int24
    8  => Int16
    16 => Int8
    32 => UInt8
)

function Pa_Initialize()
    err = ccall((:Pa_Initialize, libportaudio), PaError, ())
    handle_status(err)
end

function Pa_Terminate()
    err = ccall((:Pa_Terminate, libportaudio), PaError, ())
    handle_status(err)
end

Pa_GetVersion() = ccall((:Pa_GetVersion, libportaudio), Cint, ())

function Pa_GetVersionText()
    versionPtr = ccall((:Pa_GetVersionText, libportaudio), Ptr{Cchar}, ())
    bytestring(versionPtr)
end

# Host API Functions

# A Host API is the top-level of the PortAudio hierarchy. Each host API has a
# unique type ID that tells you which native backend it is (JACK, ALSA, ASIO,
# etc.). On a given system you can identify each backend by its index, which
# will range between 0 and Pa_GetHostApiCount() - 1. You can enumerate through
# all the host APIs on the system by iterating through those values.

typealias PaHostApiIndex Cint
typealias PaHostApiTypeId Cint

# PaHostApiTypeId values
@compat const pa_host_api_names = Dict{PaHostApiTypeId, ASCIIString}(
    0 => "In Development", # use while developing support for a new host API
    1 => "Direct Sound",
    2 => "MME",
    3 => "ASIO",
    4 => "Sound Manager",
    5 => "Core Audio",
    7 => "OSS",
    8 => "ALSA",
    9 => "AL",
    10 => "BeOS",
    11 => "WDMKS",
    12 => "Jack",
    13 => "WASAPI",
    14 => "AudioScience HPI"
)

type PaHostApiInfo
    struct_version::Cint
    api_type::PaHostApiTypeId
    name::Ptr{Cchar}
    deviceCount::Cint
    defaultInputDevice::PaDeviceIndex
    defaultOutputDevice::PaDeviceIndex
end

Pa_GetHostApiInfo(i) = unsafe_load(ccall((:Pa_GetHostApiInfo, libportaudio),
                                   Ptr{PaHostApiInfo}, (PaHostApiIndex,), i))
                                   
# Device Functions

typealias PaDeviceIndex Cint

type PaDeviceInfo
    struct_version::Cint
    name::Ptr{Cchar}
    host_api::PaHostApiIndex
    max_input_channels::Cint
    max_output_channels::Cint
    default_low_input_latency::PaTime
    default_low_output_latency::PaTime
    default_high_input_latency::PaTime
    default_high_output_latency::PaTime
    default_sample_rate::Cdouble
end

Pa_GetDeviceInfo(i) = unsafe_load(ccall((:Pa_GetDeviceInfo, libportaudio),
                                 Ptr{PaDeviceInfo}, (PaDeviceIndex,), i))

# Stream Functions

# PaStream is always used as an opaque type, so we're always dealing
# with the pointer
typealias PaStream Ptr{Void}
typealias PaStreamCallback Void
typealias PaStreamFlags Culong

function Pa_OpenDefaultStream(inChannels::Integer, outChannels::Integer,
                              sampleFormat::PaSampleFormat,
                              sampleRate::Real, framesPerBuffer::Integer)
    streamPtr::Array{PaStream} = PaStream[0]
    err = ccall((:Pa_OpenDefaultStream, libportaudio),
                PaError, (Ptr{PaStream}, Cint, Cint,
                          PaSampleFormat, Cdouble, Culong,
                          Ptr{PaStreamCallback}, Ptr{Void}),
                streamPtr, inChannels, outChannels, sampleFormat, sampleRate,
                framesPerBuffer, 0, 0)
    handle_status(err)

    streamPtr[1]
end

"""
Open a single stream, not necessarily the default one
The stream is unidirectional, either inout or default output
see http://portaudio.com/docs/v19-doxydocs/portaudio_8h.html
"""
function Pa_OpenStream(device::PaDeviceIndex,
                       channels::Cint, input::Bool,
                       sampleFormat::PaSampleFormat,
                       sampleRate::Cdouble, framesPerBuffer::Culong)
    streamPtr::Array{PaStream} = PaStream[0]
    ioParameters = Pa_StreamParameters(device, channels,
                                       sampleFormat, PaTime(0.001),
                                       Ptr{Void}(0))
    # CURRENTLY WORKING THIS OUT
    if input
        err = ccall((:Pa_OpenStream, libportaudio), PaError,
                    (PaStream,
                    Ptr{Pa_StreamParameters}, Ptr{Pa_StreamParameters},
                    Cdouble, Culong, PaStreamFlags,
                    Ptr{PaStreamCallback}, Ptr{Void}),
                    streamPtr, ioParameters, Ptr{Void}(0),
                    sampleRate, framesPerBuffer, 0,
                    Ptr{PaStreamCallback}(0), Ptr{Void}(0))
    else
        err = ccall((:Pa_OpenStream, libportaudio), PaError,
                    (PaStream, Ptr{Void}, Ref{Pa_StreamParameters},
                    Cdouble, Culong, Culong,
                    Ptr{PaStreamCallback}, Ptr{Void}),
                    streamPtr, Ptr{Void}(0), ioParameters,
                    sampleRate, framesPerBuffer, 0,
                    Ptr{PaStreamCallback}(0), Ptr{Void}(0))
    end
    handle_status(err)
    streamPtr[1]
end

function Pa_StartStream(stream::PaStream)
    err = ccall((:Pa_StartStream, libportaudio), PaError,
                (PaStream,), stream)
    handle_status(err)
end

function Pa_StopStream(stream::PaStream)
    err = ccall((:Pa_StopStream, libportaudio), PaError,
                (PaStream,), stream)
    handle_status(err)
end

function Pa_CloseStream(stream::PaStream)
    err = ccall((:Pa_CloseStream, libportaudio), PaError,
                (PaStream,), stream)
    handle_status(err)
end

function Pa_GetStreamReadAvailable(stream::PaStream)
    avail = ccall((:Pa_GetStreamReadAvailable, libportaudio), Clong,
                (PaStream,), stream)
    avail >= 0 || handle_status(avail)
    avail
end

function Pa_GetStreamWriteAvailable(stream::PaStream)
    avail = ccall((:Pa_GetStreamWriteAvailable, libportaudio), Clong,
                (PaStream,), stream)
    avail >= 0 || handle_status(avail)
    avail
end

function Pa_ReadStream(stream::PaStream, buf::Array, frames::Integer=length(buf),
                       show_warnings::Bool=true)
    frames <= length(buf) || error("Need a buffer at least $frames long")
    err = ccall((:Pa_ReadStream, libportaudio), PaError,
                (PaStream, Ptr{Void}, Culong),
                stream, buf, frames)
    handle_status(err, show_warnings)
    buf
end

function Pa_WriteStream(stream::PaStream, buf::Array, frames::Integer=length(buf),
                        show_warnings::Bool=true)
    frames <= length(buf) || error("Need a buffer at least $frames long")
    err = ccall((:Pa_WriteStream, libportaudio), PaError,
                (PaStream, Ptr{Void}, Culong),
                stream, buf, frames)
    handle_status(err, show_warnings)
    nothing
end

# General utility function to handle the status from the Pa_* functions
function handle_status(err::PaError, show_warnings::Bool=true)
    if err == PA_OUTPUT_UNDERFLOWED || err == PA_INPUT_OVERFLOWED
        if show_warnings
            msg = ccall((:Pa_GetErrorText, libportaudio),
                        Ptr{Cchar}, (PaError,), err)
            warn("libportaudio: " * bytestring(msg))
        end
    elseif err != PA_NO_ERROR
        msg = ccall((:Pa_GetErrorText, libportaudio),
                    Ptr{Cchar}, (PaError,), err)
        error("libportaudio: " * bytestring(msg))
    end
end
