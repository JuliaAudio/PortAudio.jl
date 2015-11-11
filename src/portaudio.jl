typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
# PaStream is always used as an opaque type, so we're always dealing
# with the pointer
typealias PaStream Ptr{Void}
typealias PaDeviceIndex Cint
typealias PaHostApiIndex Cint
typealias PaTime Cdouble
typealias PaHostApiTypeId Cint
typealias PaStreamCallback Void
typealias PaStreamFlags Culong

const PA_NO_ERROR = 0
const PA_INPUT_OVERFLOWED = -10000 + 19
const PA_OUTPUT_UNDERFLOWED = -10000 + 20

const paFloat32 = convert(PaSampleFormat, 0x01)
const paInt32   = convert(PaSampleFormat, 0x02)
const paInt24   = convert(PaSampleFormat, 0x04)
const paInt16   = convert(PaSampleFormat, 0x08)
const paInt8    = convert(PaSampleFormat, 0x10)
const paUInt8   = convert(PaSampleFormat, 0x20)

# PaHostApiTypeId values
@compat const pa_host_api_names = Dict(
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

# track whether we've already inited PortAudio
portaudio_inited = false

################## Types ####################

type PortAudioStream <: AudioStream
    root::AudioMixer
    info::DeviceInfo
    show_warnings::Bool
    stream::PaStream

    function PortAudioStream(sample_rate::Integer=44100,
                             buf_size::Integer=1024,
                             show_warnings::Bool=false)
        require_portaudio_init()
        stream = Pa_OpenDefaultStream(1, 1, paFloat32, sample_rate, buf_size)
        Pa_StartStream(stream)
        root = AudioMixer()
        this = new(root, DeviceInfo(sample_rate, buf_size),
                   show_warnings, stream)
        info("Scheduling PortAudio Render Task...")
        # the task will actually start running the next time the current task yields
        @schedule(portaudio_task(this))
        finalizer(this, destroy)

        this
    end
end

function destroy(stream::PortAudioStream)
    # in 0.3 we can't print from a finalizer, as STDOUT may have been GC'ed
    # already and we get a segfault. See
    # https://github.com/JuliaLang/julia/issues/6075
    #info("Cleaning up stream")
    Pa_StopStream(stream.stream)
    Pa_CloseStream(stream.stream)
    # we only have 1 stream at a time, so if we're closing out we can just
    # terminate PortAudio.
    Pa_Terminate()
    portaudio_inited = false
end

type Pa_StreamParameters
    device::PaDeviceIndex
    channelCount::Cint
    sampleFormat::PaSampleFormat
    suggestedLatency::PaTime
    hostAPISpecificStreamInfo::Ptr{Void}
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
    if input
        err = ccall((:Pa_OpenStream, libportaudio), PaError,
                    (PaStream, Ref{Pa_StreamParameters}, Ptr{Void},
                    Cdouble, Culong, Culong,
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

type Pa_AudioStream <: AudioStream
    root::AudioMixer
    info::DeviceInfo
    show_warnings::Bool
    stream::PaStream
    sformat::PaSampleFormat
    sbuffer::Array{Real}
    sbuffer_output_waiting::Integer
    parent_may_use_buffer::Bool

    """
        Get device parameters needed for opening with portaudio
        default is input as 44100/16bit int, same as CD audio type input
    """
    function Pa_AudioStream(device_index, channels=2, input=false,
                              sample_rate::Integer=44100,
                              framesPerBuffer::Integer=2048,
                              show_warnings::Bool=false,
                              sample_format::PaSampleFormat=paInt16)
        require_portaudio_init()
        stream = Pa_OpenStream(device_index, channels, input, sample_format,
                               Cdouble(sample_rate), Culong(framesPerBuffer))
        Pa_StartStream(stream)
        root = AudioMixer()
        datatype = PaSampleFormat_to_T(sample_format)
        sbuf = ones(datatype, framesPerBuffer)
        this = new(root, DeviceInfo(sample_rate, framesPerBuffer),
                   show_warnings, stream, sample_format, sbuf, 0, false)
        info("Scheduling PortAudio Render Task...")
        if input
            @schedule(pa_input_task(this))
        else
            @schedule(pa_output_task(this))
        end
        this
    end
end

"""
Blocking read from a Pa_AudioStream that is open as input
"""
function read_Pa_AudioStream(stream::Pa_AudioStream)
    while true
        while stream.parent_may_use_buffer == false
            sleep(0.001)
        end
        buffer = deepcopy(stream.sbuffer)
        stream.parent_may_use_buffer = false
        return buffer
     end
end

"""
Blocking write to a Pa_AudioStream that is open for output
"""
function write_Pa_AudioStream(stream::Pa_AudioStream, buffer)
    retval = 1
    sbufsize = length(stream.sbuffer)
    inputlen = length(buffer)
    if(inputlen > sbufsize)
        info("Overflow at write_Pa_AudioStream")
        retval = 0
    elseif(inputlen < sbufsize)
        info("Underflow at write_Pa_AudioStream")
        retval = -1
    end
    while true
        while stream.parent_may_use_buffer == false
            sleep(0.001)
        end
        for idx in 1:min(sbufsize, inputlen)
            stream.sbuffer[idx] = buffer[idx]
        end
        stream.parent_may_use_buffer = false
    end
    retval
end

############ Internal Functions ############

function portaudio_task(stream::PortAudioStream)
    info("PortAudio Render Task Running...")
    n = bufsize(stream)
    buffer = zeros(AudioSample, n)
    try
        while true
            while Pa_GetStreamReadAvailable(stream.stream) < n
                sleep(0.005)
            end
            Pa_ReadStream(stream.stream, buffer, n, stream.show_warnings)
            # assume the root is always active
            rendered = render(stream.root.renderer, buffer, stream.info)::AudioBuf
            for i in 1:length(rendered)
                buffer[i] = rendered[i]
            end
            for i in (length(rendered)+1):n
                buffer[i] = 0.0
            end
            while Pa_GetStreamWriteAvailable(stream.stream) < n
                sleep(0.005)
            end
            Pa_WriteStream(stream.stream, buffer, n, stream.show_warnings)
        end
    catch ex
        warn("Audio Task died with exception: $ex")
        Base.show_backtrace(STDOUT, catch_backtrace())
    end
end

"""
    Helper function to make the right type of buffer for various
    sample formats. Converts PaSampleFormat to a typeof
"""
function PaSampleFormat_to_T(fmt::PaSampleFormat)
    retval = UInt8(0x0)
    if fmt == 1
        retval = Float32(1.0)
    elseif fmt == 2
        retval = Int32(0x02)
    elseif fmt == 4
        retval = Int24(0x04)
    elseif fmt == 8
        retval = Int16(0x08)
    elseif fmt == 16
        retval = Int8(0x10)
    elseif fmt == 32
        retval = UInt8(0x20)
    else
        info("Flawed input to PaSampleFormat_to_T, primitive unknown")
    end
    typeof(retval)
end

"""
    Get input device data, pass as a producer, no rendering
"""
function pa_input_task(stream::Pa_AudioStream)
    info("PortAudio Input Task Running...")
    n = bufsize(stream)
    datatype = PaSampleFormat_to_T(stream.sformat)
    # bigger ccall buffer to avoid overflow related errors
    buffer = zeros(datatype, n * 8)
    try
        while true
            while Pa_GetStreamReadAvailable(stream.stream) < n
                sleep(0.005)
            end
            while stream.parent_may_use_buffer
                sleep(0.005)
            end
            err = ccall((:Pa_ReadStream, libportaudio), PaError,
                        (PaStream, Ptr{Void}, Culong),
                        stream.stream, buffer, n)
            handle_status(err, stream.show_warnings)
            stream.sbuffer[1: n] = buffer[1: n]
            stream.parent_may_use_buffer = true
            sleep(0.005)
        end
    catch ex
        warn("Audio Input Task died with exception: $ex")
        Base.show_backtrace(STDOUT, catch_backtrace())
    end
end

"""
    Send output device data, no rendering
"""
function pa_output_task(stream::Pa_AudioStream)
    info("PortAudio Output Task Running...")
    n = bufsize(stream)
    try
        while true
            navail = stream.sbuffer_output_waiting
            if navail > n
                info("Possible output buffer overflow in stream")
                navail = n
            end
            if (navail > 1) & (stream.parent_may_use_buffer == false) &
               (Pa_GetStreamWriteAvailable(stream.stream) < navail)
                Pa_WriteStream(stream.stream, stream.sbuffer,
                               navail, stream.show_warnings)
                stream.parent_may_use_buffer = true
            else
                sleep(0.005)
            end
        end
    catch ex
        warn("Audio Output Task died with exception: $ex")
        Base.show_backtrace(STDOUT, catch_backtrace())
    end
end

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

type PaHostApiInfo
    struct_version::Cint
    api_type::PaHostApiTypeId
    name::Ptr{Cchar}
    deviceCount::Cint
    defaultInputDevice::PaDeviceIndex
    defaultOutputDevice::PaDeviceIndex
end

type PortAudioInterface <: AudioInterface
    name::AbstractString
    host_api::AbstractString
    max_input_channels::Int
    max_output_channels::Int
    device_index::PaDeviceIndex
end

function get_portaudio_devices()
    require_portaudio_init()
    device_count = ccall((:Pa_GetDeviceCount, libportaudio), PaDeviceIndex, ())
    pa_devices = [ [Pa_GetDeviceInfo(i), i] for i in 0:(device_count - 1)]
    [PortAudioInterface(bytestring(d[1].name),
                        bytestring(Pa_GetHostApiInfo(d[1].host_api).name),
                        d[1].max_input_channels,
                        d[1].max_output_channels,
                        d[2])
     for d in pa_devices]
end

function require_portaudio_init()
    # can be called multiple times with no effect
    global portaudio_inited
    if !portaudio_inited
        info("Initializing PortAudio. Expect errors as we scan devices")
        Pa_Initialize()
        portaudio_inited = true
    end
end

# Low-level wrappers for Portaudio calls
Pa_GetDeviceInfo(i) = unsafe_load(ccall((:Pa_GetDeviceInfo, libportaudio),
                                 Ptr{PaDeviceInfo}, (PaDeviceIndex,), i))
Pa_GetHostApiInfo(i) = unsafe_load(ccall((:Pa_GetHostApiInfo, libportaudio),
                                   Ptr{PaHostApiInfo}, (PaHostApiIndex,), i))

function Pa_Initialize()
    err = ccall((:Pa_Initialize, libportaudio), PaError, ())
    handle_status(err)
end

function Pa_Terminate()
    err = ccall((:Pa_Terminate, libportaudio), PaError, ())
    handle_status(err)
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

Pa_GetVersion() = ccall((:Pa_GetVersion, libportaudio), Cint, ())

function Pa_GetVersionText()
    versionPtr = ccall((:Pa_GetVersionText, libportaudio), Ptr{Cchar}, ())
    bytestring(versionPtr)
end

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
