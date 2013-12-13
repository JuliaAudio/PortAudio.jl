# thanks to Gustavo Goretkin for the start on this

module PortAudio

export play_sin, stop_sin

typealias PaTime Cdouble
typealias PaError Cint
typealias PaSampleFormat Culong
typealias PaStream Void

const PA_NO_ERROR = 0

############ Exported Functions #############

function play_sin()
    err = ccall((:play_sin, libportaudio_shim), PaError, ())
    handle_status(err)
end

function stop_sin()
    err = ccall((:stop_sin, libportaudio_shim), PaError, ())
    handle_status(err)
end

############ Internal Functions ############

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
