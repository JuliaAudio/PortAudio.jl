__precompile__()

module PortAudio

using SampleTypes
using Devectorize
using RingBuffers

# Get binary dependencies loaded from BinDeps
include( "../deps/deps.jl")
include("libportaudio.jl")

export PortAudioStream

const DEFAULT_BUFSIZE=4096

function __init__()
    # initialize PortAudio on module load
    Pa_Initialize()

    # the portaudio callbacks are parametric on the sample type
    global const pa_callbacks = Dict{Type, Ptr{Void}}()

    for T in (Float32, Int32, Int16, Int8, UInt8)
        pa_callbacks[T] = cfunction(portaudio_callback, Cint,
            (Ptr{T}, Ptr{T}, Culong, Ptr{Void}, Culong,
            Ptr{CallbackInfo{T}}))
    end
end

function versioninfo(io::IO=STDOUT)
    println(io, Pa_GetVersionText())
    println(io, "Version Number: ", Pa_GetVersion())
end

type PortAudioDevice
    name::UTF8String
    hostapi::UTF8String
    maxinchans::Int
    maxoutchans::Int
    idx::PaDeviceIndex
end

PortAudioDevice(info::PaDeviceInfo, idx) = PortAudioDevice(
        bytestring(info.name),
        bytestring(Pa_GetHostApiInfo(info.host_api).name),
        info.max_input_channels,
        info.max_output_channels,
        idx)

function devices()
    ndevices = Pa_GetDeviceCount()
    infos = PaDeviceInfo[Pa_GetDeviceInfo(i) for i in 0:(ndevices - 1)]
    PortAudioDevice[PortAudioDevice(info, idx-1) for (idx, info) in enumerate(infos)]
end

# not for external use, used in error message printing
devnames() = join(["\"$(dev.name)\"" for dev in devices()], "\n")

"""Give a pointer to the given field within a Julia object"""
function fieldptr{T}(obj::T, field::Symbol)
    fieldnum = findfirst(fieldnames(T), field)
    offset = fieldoffsets(T)[fieldnum]
    FT = fieldtype(T, field)

    Ptr{FT}(pointer_from_objref(obj) + offset)
end

# Used to synchronize the portaudio callback and Julia task
@enum BufferState JuliaPending PortAudioPending

# we want this to be immutable so we can stack allocate it
immutable CallbackInfo{T}
    inchannels::Int
    inbuf::Ptr{T}
    outchannels::Int
    outbuf::Ptr{T}
    taskhandle::Ptr{Void}
    bufstate::Ptr{BufferState}
end

# paramaterized on the sample type and sampling rate type
type PortAudioStream{T, U}
    samplerate::U
    bufsize::Int
    stream::PaStream
    sink # untyped because of circular type definition
    source # untyped because of circular type definition
    taskwork::Base.SingleAsyncWork
    bufstate::BufferState # used to synchronize the portaudio and julia sides
    bufinfo::CallbackInfo{T} # immutable data used in the portaudio callback

    # this inner constructor is generally called via the top-level outer
    # constructor below
    function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
            inchans, outchans, sr, bufsize)
        inparams = (inchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(indev.idx, inchans, type_to_fmt[T], 0.0, C_NULL))
        outparams = (outchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(outdev.idx, outchans, type_to_fmt[T], 0.0, C_NULL))
        this = new(sr, bufsize, C_NULL)
        finalizer(this, close)
        this.sink = PortAudioSink{T, U}(outdev.name, this, outchans, bufsize;
                                        prefill=false, underflow=PAD)
        this.source = PortAudioSource{T, U}(indev.name, this, inchans, bufsize;
                                            prefill=true, overflow=OVERWRITE)
        this.taskwork = Base.SingleAsyncWork(_ -> audiotask(this))
        this.bufstate = PortAudioPending
        this.bufinfo = CallbackInfo(inchans, pointer(this.source.pabuf),
                                    outchans, pointer(this.sink.pabuf),
                                    this.taskwork.handle,
                                    fieldptr(this, :bufstate))
        this.stream = Pa_OpenStream(inparams, outparams, float(sr), bufsize,
            paNoFlag, pa_callbacks[T], fieldptr(this, :bufinfo))

        Pa_StartStream(this.stream)

        this
    end

end

# this is the top-level outer constructor that all the other outer constructors
# end up calling
function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
        inchans=2, outchans=2; eltype=Float32, samplerate=48000Hz, bufsize=DEFAULT_BUFSIZE)
    PortAudioStream{eltype, typeof(samplerate)}(indev, outdev, inchans, outchans, samplerate, bufsize)
end

function PortAudioStream(indevname::AbstractString, outdevname::AbstractString, args...; kwargs...)
    indev = nothing
    outdev = nothing
    for d in devices()
        if d.name == indevname
            indev = d
        end
        if d.name == outdevname
            outdev = d
        end
    end
    if indev == nothing
        error("No device matching \"$indevname\" found.\nAvailable Devices:\n$(devnames())")
    end
    if outdev == nothing
        error("No device matching \"$outdevname\" found.\nAvailable Devices:\n$(devnames())")
    end

    PortAudioStream(indev, outdev, args...; kwargs...)
end

# if one device is given, use it for input and output
PortAudioStream(device::PortAudioDevice, args...; kwargs...) = PortAudioStream(device, device, args...; kwargs...)
PortAudioStream(device::AbstractString, args...; kwargs...) = PortAudioStream(device, device, args...; kwargs...)

# use the default input and output devices
function PortAudioStream(args...; kwargs...)
    inidx = Pa_GetDefaultInputDevice()
    indevice = PortAudioDevice(Pa_GetDeviceInfo(inidx), inidx)
    outidx = Pa_GetDefaultOutputDevice()
    outdevice = PortAudioDevice(Pa_GetDeviceInfo(outidx), outidx)
    PortAudioStream(indevice, outdevice, args...; kwargs...)
end

function Base.close(stream::PortAudioStream)
    if stream.stream != C_NULL
        Pa_StopStream(stream.stream)
        Pa_CloseStream(stream.stream)
        stream.stream = C_NULL
    end

    nothing
end

Base.isopen(stream::PortAudioStream) = stream.stream != C_NULL

SampleTypes.samplerate(stream::PortAudioStream) = stream.samplerate
Base.eltype{T, U}(stream::PortAudioStream{T, U}) = T

Base.read(stream::PortAudioStream, args...) = read(stream.source, args...)
Base.read!(stream::PortAudioStream, args...) = read!(stream.source, args...)
Base.write(stream::PortAudioStream, args...) = write(stream.sink, args...)
Base.write(sink::PortAudioStream, source::PortAudioStream, args...) = write(sink.sink, source.source, args...)

function Base.show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    println(io, "  Samplerate: ", samplerate(stream))
    print(io, "  Buffer Size: ", stream.bufsize, " frames")
    if nchannels(stream.sink) > 0
        println()
        print(io, "  ", nchannels(stream.sink), " channel sink: \"", stream.sink.name, "\"")
    end
    if nchannels(stream.source) > 0
        println()
        print(io, "  ", nchannels(stream.source), " channel source: \"", stream.source.name, "\"")
    end
end

# Define our source and sink types
for (TypeName, Super) in ((:PortAudioSink, :SampleSink),
                          (:PortAudioSource, :SampleSource))
    @eval type $TypeName{T, U} <: $Super
        name::UTF8String
        stream::PortAudioStream{T, U}
        jlbuf::Array{T, 2}
        pabuf::Array{T, 2}
        ringbuf::RingBuffer{T}

        function $TypeName(name, stream, channels, bufsize; prefill=false, ringbuf_args...)
            # portaudio data comes in interleaved, so we'll end up transposing
            # it back and forth to julia column-major
            jlbuf = zeros(T, bufsize, channels)
            pabuf = zeros(T, channels, bufsize)
            ringbuf = RingBuffer(T, bufsize, channels; ringbuf_args...)
            if prefill
                write(ringbuf, zeros(T, bufsize, channels))
            end
            new(name, stream, jlbuf, pabuf, ringbuf)
        end
    end
end

SampleTypes.nchannels(s::Union{PortAudioSink, PortAudioSource}) = size(s.jlbuf, 2)
SampleTypes.samplerate(s::Union{PortAudioSink, PortAudioSource}) = samplerate(s.stream)
Base.eltype{T, U}(::Union{PortAudioSink{T, U}, PortAudioSource{T, U}}) = T

function Base.show{T <: Union{PortAudioSink, PortAudioSource}}(io::IO, stream::T)
    println(io, T, "(\"", stream.name, "\")")
    print(io, nchannels(stream), " channels")
end


function SampleTypes.unsafe_write(sink::PortAudioSink, buf::SampleBuf)
    write(sink.ringbuf, buf)
end

function SampleTypes.unsafe_read!(source::PortAudioSource, buf::SampleBuf)
    read!(source.ringbuf, buf)
end

# This is the callback function that gets called directly in the PortAudio
# audio thread, so it's critical that it not interact with the Julia GC
function portaudio_callback{T}(inptr::Ptr{T}, outptr::Ptr{T},
        nframes, timeinfo, flags, userdata::Ptr{CallbackInfo{T}})
    info = unsafe_load(userdata)

    if(unsafe_load(info.bufstate) != PortAudioPending)
        # xrun, copy zeros to outbuffer
        memset(outptr, 0, sizeof(T)*nframes*info.outchannels)
        return paContinue
    end

    unsafe_copy!(info.inbuf, inptr, nframes * info.inchannels)
    unsafe_copy!(outptr, info.outbuf, nframes * info.outchannels)

    unsafe_store!(info.bufstate, JuliaPending)

    # notify the julia audio task
    ccall(:uv_async_send, Void, (Ptr{Void},), info.taskhandle)

    paContinue
end

# this gets called from uv_async_send, so it MUST NOT BLOCK
function audiotask{T, U}(stream::PortAudioStream{T, U})
    try
        if stream.bufstate != JuliaPending
            return
        end

        transpose!(stream.source.jlbuf, stream.source.pabuf)
        write(stream.source.ringbuf, stream.source.jlbuf)

        read!(stream.sink.ringbuf, stream.sink.jlbuf)
        transpose!(stream.sink.pabuf, stream.sink.jlbuf)

        stream.bufstate = PortAudioPending
    catch ex
        warn("Audio Task died with exception: $ex")
        Base.show_backtrace(STDOUT, catch_backtrace())
    end
end

memset(buf, val, count) = ccall(:memset, Ptr{Void},
    (Ptr{Void}, Cint, Csize_t),
    buf, val, count)

end # module PortAudio
