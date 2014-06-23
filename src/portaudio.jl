typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
typealias PaStream Void
typealias PaDeviceIndex Cint
typealias PaHostApiIndex Cint
typealias PaTime Cdouble
typealias PaHostApiTypeId Cint

const PA_NO_ERROR = 0
const libportaudio_shim = find_library(["libportaudio_shim",],
        [Pkg.dir("AudioIO", "deps", "usr", "lib"),])

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

    function PortAudioStream(sample_rate::Int=44100, buf_size::Int=1024)
        init_portaudio()
        root = AudioMixer()
        stream = new(root, DeviceInfo(sample_rate, buf_size))
        # we need to start up the stream with the portaudio library
        open_portaudio_stream(stream)
        return stream
    end
end

############ Internal Functions ############

function synchronize_buffer(buffer)
    ccall((:synchronize_buffer, libportaudio_shim), Void, (Ptr{Void},), buffer)
end

function open_portaudio_stream(stream::PortAudioStream)
    # starts up a stream with the portaudio library and associates it with the
    # given AudioIO PortAudioStream

    # TODO: handle more streams

    fd = ccall((:make_pipe, libportaudio_shim), Cint, ())

    info("Launching PortAudio Task...")
    schedule(Task(() -> portaudio_task(fd, stream)))
    # TODO: test not yielding here
    yield()
    info("Audio Task Yielded, starting the stream...")

    err = ccall((:open_stream, libportaudio_shim), PaError,
                (Cuint, Cuint),
                stream.info.sample_rate, stream.info.buf_size)
    handle_status(err)
    info("Portaudio stream started.")
end

function handle_status(err::PaError)
    if err != PA_NO_ERROR
        msg = ccall((:Pa_GetErrorText, "libportaudio"),
                    Ptr{Cchar}, (PaError,), err)
        error("libportaudio: " * bytestring(msg))
    end
end

function portaudio_task(jl_filedesc::Integer, stream::PortAudioStream)
    info("Audio Task Launched")
    buffer = zeros(AudioSample, stream.info.buf_size)
    desc_bytes = Cchar[0]
    jl_stream = fdio(jl_filedesc)
    jl_rawfd = RawFD(jl_filedesc)
    try
        while true
            # assume the root is always active
            rendered = render(stream.root, buffer, stream.info)
            for i in 1:length(rendered)
                buffer[i] = rendered[i]
            end
            for i in (length(rendered)+1):length(buffer)
                buffer[i] = 0.0
            end

            # wake the C code so it knows we've given it some more data
            synchronize_buffer(buffer)
            # wait for new data to be available from the sound card (and for it
            # to have processed our last frame of data). At some point we
            # should do something with the data we get from the callback
            wait(jl_rawfd, readable=true)
            # read from the file descriptor so that it's empty. We're using
            # ccall here because readbytes() was blocking the whole julia
            # thread. This shouldn't block at all because we just waited on it
            ccall(:read, Clong, (Cint, Ptr{Void}, Culong),
                  jl_filedesc, desc_bytes, 1)
        end
    finally
        # TODO: we need to close the stream here. Otherwise the audio callback
        # will segfault accessing the output array if there were exceptions
        # thrown in the render loop
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

# some thin wrappers to portaudio calls
get_device_info(i) = unsafe_load(ccall((:Pa_GetDeviceInfo, "libportaudio"),
                                 Ptr{PaDeviceInfo}, (PaDeviceIndex,), i))
get_host_api_info(i) = unsafe_load(ccall((:Pa_GetHostApiInfo, "libportaudio"),
                                   Ptr{PaHostApiInfo}, (PaHostApiIndex,), i))

function get_portaudio_devices()
    init_portaudio()
    device_count = ccall((:Pa_GetDeviceCount, "libportaudio"), PaDeviceIndex, ())
    pa_devices = [get_device_info(i) for i in 0:(device_count - 1)]
    [PortAudioInterface(bytestring(d.name),
                        bytestring(get_host_api_info(d.host_api).name),
                        d.max_input_channels,
                        d.max_output_channels)
     for d in pa_devices]
end

function init_portaudio()
    # can be called multiple times with no effect
    global portaudio_inited
    if !portaudio_inited
        @assert(libportaudio_shim != "", "Failed to find required library libportaudio_shim. Try re-running the package script using Pkg.build(\"AudioIO\"), then reloading with reload(\"AudioIO\")")

        info("Initializing PortAudio. Expect errors as we scan devices")
        err = ccall((:Pa_Initialize, "libportaudio"), PaError, ())
        handle_status(err)
        portaudio_inited = true
    end
end


# Old code for reference during initial development. We can get rid of this
# once the library is a little more mature


#type PaStreamCallbackTimeInfo
#    inputBufferAdcTime::PaTime
#    currentTime::PaTime
#    outputBufferDacTime::PaTime
#end
#
#typealias PaStreamCallbackFlags Culong
#
#
#function stream_callback{T}(    input_::Ptr{T}, 
#    output_::Ptr{T}, 
#    frame_count::Culong, 
#    time_info::Ptr{PaStreamCallbackTimeInfo},
#    status_flags::PaStreamCallbackFlags,
#    user_data::Ptr{Void})
#
#
#    println("stfl:$status_flags  \tframe_count:$frame_count")
#
#    ret = 0
#    return convert(Cint,ret)::Cint    #continue stream
#
#end
#
#T=Float32
#stream_callback_c = cfunction(stream_callback,Cint,
#(Ptr{T},Ptr{T},Culong,Ptr{PaStreamCallbackTimeInfo},PaStreamCallbackFlags,Ptr{Void})
#)
#stream_obj = Array(Ptr{PaStream},1)
#
#pa_err = ccall( 
#(:Pa_Initialize,"libportaudio"), 
#PaError,
#(),
#)
#
#println(get_error_text(pa_err))
#
#pa_err = ccall( 
#(:Pa_OpenDefaultStream,"libportaudio"), 
#PaError,
#(Ptr{Ptr{PaStream}},Cint,Cint,PaSampleFormat,Cdouble,Culong,Ptr{Void},Any),
#stream_obj,0,1,0x1,8000.0,4096,stream_callback_c,None
#)
#
#println(get_error_text(pa_err))
#
#function start_stream(stream)
#    pa_err = ccall( 
#    (:Pa_StartStream,"libportaudio"), 
#    PaError,
#    (Ptr{PaStream},),
#    stream
#    )    
#    println(get_error_text(pa_err))
#end
#
#end #module
