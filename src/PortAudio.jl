module PortAudio
using SampleTypes
using Compat

# Get binary dependencies loaded from BinDeps
include( "../deps/deps.jl")
include("libportaudio.jl")

# Info about the hardware device
type DeviceInfo
    sample_rate::Float32
    buf_size::Integer
end

function devices()
    return get_portaudio_devices()
end

type PortAudioStream
    info::DeviceInfo
    show_warnings::Bool
    stream::PaStream

    function PortAudioStream(sample_rate=44100Hz,
                             buf_size::Integer=1024,
                             show_warnings::Bool=false)
        # Pa_Initialize can be called multiple times, as long as each is
        # paired with Pa_Terminate()
        Pa_Initialize()
        stream = Pa_OpenDefaultStream(2, 2, paFloat32, Int(sample_rate), buf_size)
        Pa_StartStream(stream)
        this = new(root, DeviceInfo(sample_rate, buf_size), show_warnings, stream)
        @schedule(portaudio_task(this))               
        finalizer(this, close)

        this
    end
end

type PortAudioSink <: SampleSink
    stream::PaStream
end

type PortAudioSource <: SampleSource
    stream::PaStream
end

function close(stream::PortAudioStream)
    Pa_StopStream(stream.stream)
    Pa_CloseStream(stream.stream)
    Pa_Terminate()
end

type Pa_StreamParameters
    device::PaDeviceIndex
    channelCount::Cint
    sampleFormat::PaSampleFormat
    suggestedLatency::PaTime
    hostAPISpecificStreamInfo::Ptr{Void}
end

type PortAudioInterface <: AudioInterface
    name::AbstractString
    host_api::AbstractString
    max_input_channels::Int
    max_output_channels::Int
    device_index::PaDeviceIndex
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

end # module PortAudio