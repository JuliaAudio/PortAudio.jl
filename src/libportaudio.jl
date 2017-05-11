# Low-level wrappers for Portaudio calls

# General type aliases
const PaTime = Cdouble
const PaError = Cint
const PaSampleFormat = Culong
const PaDeviceIndex = Cint
const PaHostApiIndex = Cint
const PaHostApiTypeId = Cint
# PaStream is always used as an opaque type, so we're always dealing
# with the pointer
const PaStream = Ptr{Void}
const PaStreamCallback = Void
const PaStreamFlags = Culong

const paNoFlag = PaStreamFlags(0x00)

const PA_NO_ERROR = 0
const PA_INPUT_OVERFLOWED = -10000 + 19
const PA_OUTPUT_UNDERFLOWED = -10000 + 20

# sample format types
const paFloat32 = PaSampleFormat(0x01)
const paInt32   = PaSampleFormat(0x02)
const paInt24   = PaSampleFormat(0x04)
const paInt16   = PaSampleFormat(0x08)
const paInt8    = PaSampleFormat(0x10)
const paUInt8   = PaSampleFormat(0x20)
const paNonInterleaved = PaSampleFormat(0x80000000)

const type_to_fmt = Dict{Type, PaSampleFormat}(
    Float32 => 1,
    Int32   => 2,
    # Int24   => 4,
    Int16   => 8,
    Int8    => 16,
    UInt8   => 3
)

const PaStreamCallbackResult = Cint
# Callback return values
const paContinue = PaStreamCallbackResult(0)
const paComplete = PaStreamCallbackResult(1)
const paAbort = PaStreamCallbackResult(2)

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
    unsafe_string(versionPtr)
end

# Host API Functions

# A Host API is the top-level of the PortAudio hierarchy. Each host API has a
# unique type ID that tells you which native backend it is (JACK, ALSA, ASIO,
# etc.). On a given system you can identify each backend by its index, which
# will range between 0 and Pa_GetHostApiCount() - 1. You can enumerate through
# all the host APIs on the system by iterating through those values.

# PaHostApiTypeId values
const pa_host_api_names = Dict{PaHostApiTypeId, String}(
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

Pa_GetDeviceCount() = ccall((:Pa_GetDeviceCount, libportaudio), PaDeviceIndex, ())

Pa_GetDeviceInfo(i) = unsafe_load(ccall((:Pa_GetDeviceInfo, libportaudio),
                                 Ptr{PaDeviceInfo}, (PaDeviceIndex,), i))

Pa_GetDefaultInputDevice() = ccall((:Pa_GetDefaultInputDevice, libportaudio),
                                   PaDeviceIndex, ())

Pa_GetDefaultOutputDevice() = ccall((:Pa_GetDefaultOutputDevice, libportaudio),
                                    PaDeviceIndex, ())

# Stream Functions

type Pa_StreamParameters
    device::PaDeviceIndex
    channelCount::Cint
    sampleFormat::PaSampleFormat
    suggestedLatency::PaTime
    hostAPISpecificStreamInfo::Ptr{Void}
end

type PaStreamInfo
    structVersion::Cint
    inputLatency::PaTime
    outputLatency::PaTime
    sampleRate::Cdouble
end

# function Pa_OpenDefaultStream(inChannels, outChannels,
#                               sampleFormat::PaSampleFormat,
#                               sampleRate, framesPerBuffer)
#     streamPtr = Ref{PaStream}(0)
#     err = ccall((:Pa_OpenDefaultStream, libportaudio),
#                 PaError, (Ref{PaStream}, Cint, Cint,
#                           PaSampleFormat, Cdouble, Culong,
#                           Ref{Void}, Ref{Void}),
#                 streamPtr, inChannels, outChannels, sampleFormat, sampleRate,
#                 framesPerBuffer, C_NULL, C_NULL)
#     handle_status(err)
#
#     streamPtr[]
# end
#
function Pa_OpenStream(inParams, outParams,
                       sampleRate, framesPerBuffer,
                       flags::PaStreamFlags,
                       callback, userdata)
    streamPtr = Ref{PaStream}(0)
    err = ccall((:Pa_OpenStream, libportaudio), PaError,
                (Ref{PaStream},
                Ptr{Pa_StreamParameters},
                Ptr{Pa_StreamParameters},
                Cdouble, Culong, PaStreamFlags,
                Ptr{Void}, Ptr{Void}),
                streamPtr,
                inParams, outParams,
                sampleRate, framesPerBuffer, flags,
                callback, userdata)
    handle_status(err)
    streamPtr[]
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

# function Pa_GetStreamInfo(stream::PaStream)
#     infoptr = ccall((:Pa_GetStreamInfo, libportaudio), Ptr{PaStreamInfo},
#             (PaStream, ), stream)
#
#     unsafe_load(infoptr)
# end
#
# General utility function to handle the status from the Pa_* functions
function handle_status(err::PaError, show_warnings::Bool=true)
    if err == PA_OUTPUT_UNDERFLOWED || err == PA_INPUT_OVERFLOWED
        if show_warnings
            msg = ccall((:Pa_GetErrorText, libportaudio),
                        Ptr{Cchar}, (PaError,), err)
            warn("libportaudio: " * unsafe_string(msg))
        end
    elseif err != PA_NO_ERROR
        msg = ccall((:Pa_GetErrorText, libportaudio),
                    Ptr{Cchar}, (PaError,), err)
        error("libportaudio: " * unsafe_string(msg))
    end
end
