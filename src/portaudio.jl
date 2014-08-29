typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
# PaStream is always used as an opaque type, so we're always dealing with the
# pointer
typealias PaStream Ptr{Void}
typealias PaDeviceIndex Cint
typealias PaHostApiIndex Cint
typealias PaTime Cdouble
typealias PaHostApiTypeId Cint
typealias PaStreamCallback Void

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
const pa_host_api_names = {
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
}

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
    name::String
    host_api::String
    max_input_channels::Int
    max_output_channels::Int
end

function get_portaudio_devices()
    require_portaudio_init()
    device_count = ccall((:Pa_GetDeviceCount, libportaudio), PaDeviceIndex, ())
    pa_devices = [Pa_GetDeviceInfo(i) for i in 0:(device_count - 1)]
    [PortAudioInterface(bytestring(d.name),
                        bytestring(Pa_GetHostApiInfo(d.host_api).name),
                        d.max_input_channels,
                        d.max_output_channels)
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
