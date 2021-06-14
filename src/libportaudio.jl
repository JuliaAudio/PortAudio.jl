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
const PaStream = Ptr{Cvoid}
const PaStreamCallback = Cvoid
const PaStreamFlags = Culong

const paNoFlag = PaStreamFlags(0x00)

const PA_NO_ERROR = 0
const PA_INPUT_OVERFLOWED = -10000 + 19
const PA_OUTPUT_UNDERFLOWED = -10000 + 20

# sample format types
const paFloat32 = PaSampleFormat(0x01)
const paInt32 = PaSampleFormat(0x02)
const paInt24 = PaSampleFormat(0x04)
const paInt16 = PaSampleFormat(0x08)
const paInt8 = PaSampleFormat(0x10)
const paUInt8 = PaSampleFormat(0x20)
const paNonInterleaved = PaSampleFormat(0x80000000)

const type_to_fmt = Dict{Type, PaSampleFormat}(
    Float32 => 1,
    Int32 => 2,
    # Int24   => 4,
    Int16 => 8,
    Int8 => 16,
    UInt8 => 3,
)

const PaStreamCallbackResult = Cint
# Callback return values
const paContinue = PaStreamCallbackResult(0)
const paComplete = PaStreamCallbackResult(1)
const paAbort = PaStreamCallbackResult(2)

function safe_load(result, an_error)
    if result == C_NULL
        throw(an_error)
    end
    unsafe_load(result)
end

"""
Call the given expression in a separate thread, waiting on the result. This is
useful when running code that would otherwise block the Julia process (like a
`ccall` into a function that does IO).
"""
macro tcall(ex)
    :(fetch(Base.Threads.@spawn $(esc(ex))))
end

# because we're calling Pa_ReadStream and PA_WriteStream from separate threads,
# we put a mutex around libportaudio calls
const pamutex = ReentrantLock()

macro locked(ex)
    quote
        lock(pamutex) do
            $(esc(ex))
        end
    end
end

function Pa_Initialize()
    handle_status(@locked ccall((:Pa_Initialize, libportaudio), PaError, ()))
    nothing
end

function Pa_Terminate()
    handle_status(@locked ccall((:Pa_Terminate, libportaudio), PaError, ()))
    nothing
end

Pa_GetVersion() = @locked ccall((:Pa_GetVersion, libportaudio), Cint, ())

function Pa_GetVersionText()
    unsafe_string(@locked ccall((:Pa_GetVersionText, libportaudio), Ptr{Cchar}, ()))
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
    14 => "AudioScience HPI",
)

mutable struct PaHostApiInfo
    struct_version::Cint
    api_type::PaHostApiTypeId
    name::Ptr{Cchar}
    deviceCount::Cint
    defaultInputDevice::PaDeviceIndex
    defaultOutputDevice::PaDeviceIndex
end

function Pa_GetHostApiInfo(i)
    safe_load(
        (@locked ccall(
            (:Pa_GetHostApiInfo, libportaudio),
            Ptr{PaHostApiInfo},
            (PaHostApiIndex,),
            i,
        )),
        BoundsError(Pa_GetHostApiInfo, i),
    )
end

# Device Functions

mutable struct PaDeviceInfo
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

function Pa_GetDeviceCount()
    handle_status(@locked ccall((:Pa_GetDeviceCount, libportaudio), PaDeviceIndex, ()))
end

function Pa_GetDeviceInfo(i)
    safe_load(
        (@locked ccall(
            (:Pa_GetDeviceInfo, libportaudio),
            Ptr{PaDeviceInfo},
            (PaDeviceIndex,),
            i,
        )),
        BoundsError(Pa_GetDeviceInfo, i),
    )
end

function Pa_GetDefaultInputDevice()
    handle_status(
        @locked ccall((:Pa_GetDefaultInputDevice, libportaudio), PaDeviceIndex, ())
    )
end

function Pa_GetDefaultOutputDevice()
    handle_status(
        @locked ccall((:Pa_GetDefaultOutputDevice, libportaudio), PaDeviceIndex, ())
    )
end

# Stream Functions

mutable struct Pa_StreamParameters
    device::PaDeviceIndex
    channelCount::Cint
    sampleFormat::PaSampleFormat
    suggestedLatency::PaTime
    hostAPISpecificStreamInfo::Ptr{Cvoid}
end

mutable struct PaStreamInfo
    structVersion::Cint
    inputLatency::PaTime
    outputLatency::PaTime
    sampleRate::Cdouble
end

convert_nothing(::Nothing) = C_NULL
convert_nothing(something) = something

# function Pa_OpenDefaultStream(inChannels, outChannels,
#                               sampleFormat::PaSampleFormat,
#                               sampleRate, framesPerBuffer)
#     streamPtr = Ref{PaStream}(0)
#     handle_status(ccall((:Pa_OpenDefaultStream, libportaudio),
#                 PaError, (Ref{PaStream}, Cint, Cint,
#                           PaSampleFormat, Cdouble, Culong,
#                           Ref{Cvoid}, Ref{Cvoid}),
#                 streamPtr, inChannels, outChannels, sampleFormat, sampleRate,
#                 framesPerBuffer, C_NULL, C_NULL))
#     streamPtr[]
# end
#
function Pa_OpenStream(
    inParams,
    outParams,
    sampleRate,
    framesPerBuffer,
    flags::PaStreamFlags,
    callback,
    userdata::UserData,
) where {UserData}
    streamPtr = Ref{PaStream}(0)
    handle_status(
        @locked ccall(
            (:Pa_OpenStream, libportaudio),
            PaError,
            (
                Ref{PaStream},
                Ref{Pa_StreamParameters},
                Ref{Pa_StreamParameters},
                Cdouble,
                Culong,
                PaStreamFlags,
                Ref{Cvoid},
                Ref{UserData},
            ),
            streamPtr,
            inParams,
            outParams,
            float(sampleRate),
            framesPerBuffer,
            flags,
            convert_nothing(callback),
            convert_nothing(userdata),
        )
    )
    streamPtr
end

function Pa_StartStream(stream::PaStream)
    handle_status(
        @locked ccall((:Pa_StartStream, libportaudio), PaError, (PaStream,), stream)
    )
    nothing
end

function Pa_StopStream(stream::PaStream)
    handle_status(
        @locked ccall((:Pa_StopStream, libportaudio), PaError, (PaStream,), stream)
    )
    nothing
end

function Pa_CloseStream(stream::PaStream)
    handle_status(
        @locked ccall((:Pa_CloseStream, libportaudio), PaError, (PaStream,), stream)
    )
    nothing
end

function Pa_GetStreamReadAvailable(stream::PaStream)
    handle_status(
        @locked ccall(
            (:Pa_GetStreamReadAvailable, libportaudio),
            Clong,
            (PaStream,),
            stream,
        )
    )
end

function Pa_GetStreamWriteAvailable(stream::PaStream)
    handle_status(
        @locked ccall(
            (:Pa_GetStreamWriteAvailable, libportaudio),
            Clong,
            (PaStream,),
            stream,
        )
    )
end

function Pa_ReadStream(stream::PaStream, buf::Array, frames::Integer; warn_xruns = true)
    # without disable_sigint I get a segfault with the error:
    # "error thrown and no exception handler available."
    # if the user tries to ctrl-C. Note I've still had some crash problems with
    # ctrl-C within `pasuspend`, so for now I think either don't use `pasuspend` or
    # don't use ctrl-C.
    handle_status(
        disable_sigint() do
            @tcall @locked ccall(
                (:Pa_ReadStream, libportaudio),
                PaError,
                (PaStream, Ptr{Cvoid}, Culong),
                stream,
                buf,
                frames,
            )
        end,
        warn_xruns = warn_xruns,
    )
end

function Pa_WriteStream(stream::PaStream, buf::Array, frames::Integer; warn_xruns = true)
    handle_status(
        disable_sigint() do
            @tcall @locked ccall(
                (:Pa_WriteStream, libportaudio),
                PaError,
                (PaStream, Ptr{Cvoid}, Culong),
                stream,
                buf,
                frames,
            )
        end,
        warn_xruns = warn_xruns,
    )
end

# function Pa_GetStreamInfo(stream::PaStream)
#     safe_load(
#         ccall((:Pa_GetStreamInfo, libportaudio), Ptr{PaStreamInfo},
#             (PaStream, ), stream),
#         ArgumentError("Error getting stream info. Is the stream already closed?")
#     )
# end
#
# General utility function to handle the status from the Pa_* functions
function handle_status(err::Integer; warn_xruns::Bool = true)
    if err < 0
        msg = @locked ccall((:Pa_GetErrorText, libportaudio), Ptr{Cchar}, (PaError,), err)
        if err == PA_OUTPUT_UNDERFLOWED || err == PA_INPUT_OVERFLOWED
            if warn_xruns
                @warn("libportaudio: " * unsafe_string(msg))
            end
        else
            throw(ErrorException("libportaudio: " * unsafe_string(msg)))
        end
    end
    err
end
