typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
typealias PaStream Void

const PA_NO_ERROR = 0
const libportaudio_shim = find_library(["libportaudio_shim",],
        [Pkg.dir("AudioIO", "deps", "usr", "lib"),])

# track whether we've already inited PortAudio
portaudio_inited = false

################## Types ####################

type PortAudioStream <: AudioStream
    mixer::AudioMixer
    info::DeviceInfo

    function PortAudioStream(sample_rate::Int=44100, buf_size::Int=1024)
        global portaudio_inited
        if !portaudio_inited
            @assert(libportaudio_shim != "", "Failed to find required library libportaudio_shim. Try re-running the package script using Pkg.build(\"AudioIO\"), then reloading with reload(\"AudioIO\")")

            init_portaudio()
            portaudio_inited = true
        else
            error("Currently only 1 stream is supported at a time")
        end
        mixer = AudioMixer()
        stream = new(mixer, DeviceInfo(sample_rate, buf_size))
        # we need to start up the stream with the portaudio library
        open_portaudio_stream(stream)
        return stream
    end
end

############ Internal Functions ############

function wake_callback_thread(out_array)
    ccall((:wake_callback_thread, libportaudio_shim), Void,
          (Ptr{Void}, Cuint),
          out_array, size(out_array, 1))
end


function init_portaudio()
    info("Initializing PortAudio. Expect errors as we scan devices")
    err = ccall((:Pa_Initialize, "libportaudio"), PaError, ())
    handle_status(err)
end

function open_portaudio_stream(stream::PortAudioStream)
    # starts up a stream with the portaudio library and associates it with the
    # given AudioIO PortAudioStream

    # TODO: handle more streams

    fd = ccall((:make_pipe, libportaudio_shim), Cint, ())

    info("Launching PortAudio Task...")
    function task_wrapper()
        portaudio_task(fd, stream)
    end
    schedule(Task(task_wrapper))
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
    in_array = zeros(AudioSample, stream.info.buf_size)
    desc_bytes = Cchar[0]
    jl_stream = fdio(jl_filedesc)
    jl_rawfd = RawFD(jl_filedesc)
    while true
        # assume the root mixer is always active
        out_array, _ = render(stream.mixer, in_array, stream.info)::AudioBuf
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
