module PortAudio

# export the basic API
export play

typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
typealias PaStream Void

const PA_NO_ERROR = 0

# default stream used when none is given
_stream = nothing

################## Types ####################

typealias AudioSample Float32
# A frame of audio, possibly multi-channel
typealias AudioBuf Array{AudioSample}

# A node in the render tree
abstract AudioNode

# A stream of audio (for instance that writes to hardware)
# All AudioStream subtypes should have a mixer and info field
abstract AudioStream

# Info about the hardware device
type DeviceInfo
    sample_rate::Integer
    buf_size::Integer
end

include("nodes.jl")

type PortAudioStream <: AudioStream
    mixer::AudioMixer
    info::DeviceInfo

    function PortAudioStream(sample_rate, buf_size)
        mixer = AudioMixer()
        new(mixer, DeviceInfo(sample_rate, buf_size))
    end
end


############ Exported Functions #############

# TODO: we should have "stop" functions that remove nodes from the render tree

# Play an AudioNode by adding it as an input to the root mixer node
function play(node::AudioNode, stream::AudioStream)
    # TODO: don't break demeter
    append!(stream.mixer.mix_inputs, [node])
    return nothing
end

# If the stream is not given, use the default global stream
function play(node::AudioNode)
    global _stream
    if _stream == nothing
        _stream = open_portaudio_stream()
    end
    play(node, _stream)
end

# Allow users to play a raw array by wrapping it in an ArrayPlayer
function play(arr::AudioBuf, args...)
    player = ArrayPlayer(arr)
    play(player, args...)
end

# If the array is the wrong floating type, convert it
function play{T <: FloatingPoint}(arr::Array{T}, args...)
    arr = convert(AudioBuf, arr)
    play(arr, args...)
end

# If the array is an integer type, scale to [-1, 1] floating point

# integer audio can be slightly (by 1) more negative than positive,
# so we just scale so that +/- typemax(T) becomes +/- 1
function play{T <: Signed}(arr::Array{T}, args...)
    arr = arr / typemax(T)
    play(arr, args...)
end

function play{T <: Unsigned}(arr::Array{T}, args...)
    zero = (typemax(T) + 1) / 2
    range = floor(typemax(T) / 2)
    arr = (arr - zero) / range
    play(arr, args...)
end

############ Internal Functions ############

function open_portaudio_stream(sample_rate::Int=44100, buf_size::Int=1024)
    # TODO: handle more streams
    global _stream
    if _stream != nothing
        error("Currently only 1 stream is supported at a time")
    end

    # TODO: when we support multiple streams we won't set _stream here.
    # this is just to ensure that only one stream is ever opened
    _stream = PortAudioStream(sample_rate, buf_size)


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

function audio_task(jl_filedesc::Integer, stream::PortAudioStream)
    info("Audio Task Launched")
    in_array = zeros(AudioSample, stream.info.buf_size)
    desc_bytes = Cchar[0]
    jl_stream = fdio(jl_filedesc)
    jl_rawfd = RawFD(jl_filedesc)
    while true
        out_array = render(stream.mixer, in_array, stream.info)::AudioBuf
        # wake the C code so it knows we've given it some more data
        wake_callback_thread(out_array)
        # wait for new data to be available from the sound card (and for it to
        # have processed our last frame of data). At some point we should do
        # something with the data we get from the callback
        wait(jl_rawfd, readable=true)
        # read from the file descriptor so that it's empty. We're using ccall
        # here because readbytes() was blocking the whole julia thread. This
        # shouldn't block at all because we just waited on it
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
