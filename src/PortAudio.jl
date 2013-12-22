module PortAudio

export play_sin, stop_sin

typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
typealias PaStream Void

const PA_NO_ERROR = 0


############ Exported Functions #############

function play_sin(sample_rate, buf_size)
    precompile(process!, (Array{Float32}, Array{Float32}))

    fd = ccall((:make_pipe, libportaudio_shim), Cint, ())

    info("Launching Audio Task...")
    function task_wrapper()
        audio_task(fd)
    end
    schedule(Task(task_wrapper))
    yield()
    info("Audio Task Yielded, starting the stream...")

    ccall((:open_stream, libportaudio_shim), PaError,
          (Cuint, Cuint),
          sample_rate, buf_size)
    info("Portaudio stream started.")
end

#function stop_sin()
#    err = ccall((:stop_sin, libportaudio_shim), PaError, ())
#    handle_status(err)
#end

############ Internal Functions ############

const sample_rate = 44100
const buf_size = 1024
const freq = 100
phase = 0.0

function process!(out_array, in_array)
    global phase
    for i in 1:buf_size
        out_array[i] = sin(phase)
        phase += 2pi * freq / sample_rate
        if phase > 2pi
            phase -= 2pi
        end
    end
    return buf_size
end

function wake_callback_thread(out_array)
    ccall((:wake_callback_thread, libportaudio_shim), Void,
          (Ptr{Void}, Cuint),
          out_array, size(out_array, 1))
end

function audio_task(jl_filedesc)
    info("Audio Task Launched")
    in_array = convert(Array{Float32}, zeros(buf_size))
    out_array = convert(Array{Float32}, zeros(buf_size))
    desc_bytes = Cchar[0]
    jl_stream = fdio(jl_filedesc)
    jl_rawfd = RawFD(jl_filedesc)
    while true
        process!(out_array, in_array)
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
