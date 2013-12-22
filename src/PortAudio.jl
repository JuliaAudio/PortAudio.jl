module PortAudio

export play

typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
typealias PaStream Void

const PA_NO_ERROR = 0

# default stream used when none is given
_stream = nothing

################## Types ####################

# A node in the render tree
abstract AudioNode

# A frame of audio, possibly multi-channel
typealias AudioBuf Array{Float32}


# Info about the hardware device
type DeviceInfo
    sample_rate::Integer
    buf_size::Integer
end

type AudioStream
    # TODO: this union may have performance penalties
    root_node::Union(AudioNode, Nothing)
    info::DeviceInfo

    function AudioStream(sample_rate, buf_size)
        new(nothing, DeviceInfo(sample_rate, buf_size))
    end
end

function render(node::Nothing, device_input::AudioBuf, info::DeviceInfo)
    return zeros(info.buf_size)
end

#### SinOsc ####

# Generates a sin tone at the given frequency

type SinOsc <: AudioNode
    freq::FloatingPoint
    phase::FloatingPoint

    function SinOsc(freq::FloatingPoint)
        new(freq, 0.0)
    end
end

function render(node::SinOsc, device_input::AudioBuf, info::DeviceInfo)
    phase = Float32[1:info.buf_size] * 2pi * node.freq / info.sample_rate
    phase += node.phase
    node.phase = phase[end]
    return sin(phase)
end

#### AudioMixer ####

# Mixes a set of inputs equally

type AudioMixer <: AudioNode
    mix_inputs::Array{AudioNode}
end

function render(node::AudioMixer, device_input::AudioBuf, info::DeviceInfo)
    # TODO: we may want to pre-allocate this buffer and share between render
    # calls
    mix_buffer = zeros(info.buf_size)
    for in_node in node.mix_inputs
        mix_buffer += render(in_node, device_input, info)
    end
end

#### Array Player ####

# Plays a Vector{Float32} by rendering it out piece-by-piece

type ArrayPlayer <: AudioNode
    arr::AudioBuf
    arr_index::Int

    function ArrayPlayer(arr::AudioBuf)
        new(arr, 1)
    end
end

function render(node::ArrayPlayer, device_input::Vector{Float32}, info::DeviceInfo)
    i = node.arr_index
    range_end = min(i + info.buf_size, length(node.arr))
    output = node.arr[i:range_end]
    if length(output) < info.buf_size
        output = vcat(output, zeros(info.buf_size - length(output)))
    end
    node.arr_index = range_end + 1
    return output
end

#### AudioInput ####

# Renders incoming audio input from the hardware

type AudioInput <: AudioNode
    channel::Int
end

function render(node::AudioInput, device_input::Vector{Float32}, info::DeviceInfo)
    @assert size(device_input, 1) == info.buf_size
    return device_input[:, node.channel]
end

############ Exported Functions #############


function register(node::AudioNode, stream::AudioStream)
    stream.root_node = node
end

function play(arr::AudioBuf, stream::AudioStream)
    player = ArrayPlayer(arr)
    register(player, stream)
end

function play(arr)
    global _stream
    if _stream == nothing
        _stream = open_stream()
    end
    play(arr, _stream)
end

############ Internal Functions ############

function open_stream(sample_rate::Int=44100, buf_size::Int=1024)
    # TODO: handle more streams
    global _stream
    if _stream != nothing
        error("Currently only 1 stream is supported at a time")
    end

    # TODO: when we support multiple streams we won't set _stream here.
    # this is just to ensure that only one stream is ever opened
    _stream = AudioStream(sample_rate, buf_size)


    fd = ccall((:make_pipe, libportaudio_shim), Cint, ())

    info("Launching Audio Task...")
    function task_wrapper()
        audio_task(fd, _stream)
    end
    schedule(Task(task_wrapper))
    # TODO: test not yielding here
    yield()
    info("Audio Task Yielded, starting the stream...")

    err = ccall((:open_stream, libportaudio_shim), PaError,
                (Cuint, Cuint),
                sample_rate, buf_size)
    handle_status(err)
    info("Portaudio stream started.")

    return _stream
end

function wake_callback_thread(out_array)
    ccall((:wake_callback_thread, libportaudio_shim), Void,
          (Ptr{Void}, Cuint),
          out_array, size(out_array, 1))
end

function audio_task(jl_filedesc::Integer, stream::AudioStream)
    info("Audio Task Launched")
    in_array = convert(AudioBuf, zeros(stream.info.buf_size))
    desc_bytes = Cchar[0]
    jl_stream = fdio(jl_filedesc)
    jl_rawfd = RawFD(jl_filedesc)
    while true
        out_array = render(stream.root_node, in_array, stream.info)
        # wake the C code so it knows we've given it some more data
        wake_callback_thread(out_array)
        # wait for new data to be available from the sound card (and for it to
        # have processed our last frame of data). At some point we should do
        # something with the data we get from the callback
        wait(jl_rawfd, readable=true)
        ccall(:read, Clong, (Cint, Ptr{Void}, Culong), jl_filedesc, desc_bytes, 1)
    end
end

function handle_status(err::PaError)
    if err != PA_NO_ERROR
        msg = ccall((:Pa_GetErrorText, "libportaudio"),
                    Ptr{Cchar}, (PaError,), err)
        error("libportaudio: " * bytestring(msg))
    end
end

function init_portaudio()
    info("Initializing PortAudio. Expect errors as we scan devices")
    err = ccall((:Pa_Initialize, "libportaudio"), PaError, ())
    handle_status(err)
end


########### Module Initialization ##############

const libportaudio_shim = find_library(["libportaudio_shim",],
        [Pkg.dir("PortAudio", "deps", "usr", "lib"),])

@assert(libportaudio_shim != "", "Failed to find required library " *
        "libportaudio_shim. Try re-running the package script using " *
        "Pkg.build(\"PortAudio\"), then reloading with reload(\"PortAudio\")")

init_portaudio()

end # module PortAudio


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
