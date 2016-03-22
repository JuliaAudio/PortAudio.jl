module PortAudio

using SampleTypes
using Devectorize

# Get binary dependencies loaded from BinDeps
include( "../deps/deps.jl")
include("libportaudio.jl")

export PortAudioSink, PortAudioSource

const DEFAULT_BUFSIZE=4096

function __init__()
    # initialize PortAudio on module load
    Pa_Initialize()

    global const portaudio_callback_float =
        cfunction(portaudio_callback, Cint,
            (Ptr{Float32}, Ptr{Float32}, Culong, Ptr{Void}, Culong,
            Ptr{CallbackInfo{Float32}}))
    global const portaudio_callback_int32 =
        cfunction(portaudio_callback, Cint,
            (Ptr{Int32}, Ptr{Int32}, Culong, Ptr{Void}, Culong,
            Ptr{CallbackInfo{Int32}}))
    # TODO: figure out how we're handling Int24
    global const portaudio_callback_int16 =
        cfunction(portaudio_callback, Cint,
            (Ptr{Int16}, Ptr{Int16}, Culong, Ptr{Void}, Culong,
            Ptr{CallbackInfo{Int16}}))
    global const portaudio_callback_int8 =
        cfunction(portaudio_callback, Cint,
            (Ptr{Int8}, Ptr{Int8}, Culong, Ptr{Void}, Culong,
            Ptr{CallbackInfo{Int8}}))
    global const portaudio_callback_uint8 =
        cfunction(portaudio_callback, Cint,
            (Ptr{UInt8}, Ptr{UInt8}, Culong, Ptr{Void}, Culong,
            Ptr{CallbackInfo{UInt8}}))
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

    pointer_from_objref(obj) + offset
end

# Used to synchronize the portaudio callback and Julia task
@enum BufferState JuliaPending PortaudioPending

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
    stream::PaStream
    name::UTF8String
    samplerate::U
    bufsize::Int
    sink # untyped because of circular type definition
    source # untyped because of circular type definition
    bufinfo::CallbackInfo{T}
    bufstate::BufferState
    taskwork::Base.SingleAsyncWork

    function PortAudioStream(T, stream, sr, inchans, outchans, bufsize, name)
        this = new(stream, utf8(name), sr, bufsize)
        finalizer(this, close)
        this.sink = PortAudioSink{T, U}(this, outchans, bufsize)
        this.source = PortAudioSource{T, U}(this, inchans, bufsize)
        this.taskwork = Base.SingleAsyncWork(data -> audiotask(this))
        inbuf = pointer_from_objref(this.source) + fieldoffsets(PortAudioSource)[]
        this.bufstate = PortAudioPending
        this.bufinfo = CallbackInfo(inchans, fieldptr(this.source, :pabuf),
                                    outchans, fieldptr(this.sink, :pabuf),
                                    this.taskwork.handle,
                                    fieldptr(this, bufstate))

        Pa_StartStream(stream)

        this
    end

end

function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
        eltype=Float32, sr=48000Hz, inchans=2, outchans=2, bufsize=DEFAULT_BUFSIZE)
    if inchans == 0
        inparams = Ptr{Pa_StreamParameters}(0)
    else
        inparams = Ref(Pa_StreamParameters(indev.idx, inchans, type_to_fmt[eltype], 0.0, C_NULL))
    end
    if outchans == 0
        outparams = Ptr{Pa_StreamParameters}(0)
    else
        outparams = Ref(Pa_StreamParameters(outdev.idx, outchans, type_to_fmt[eltype], 0.0, C_NULL))
    end
    stream = Pa_OpenStream(inparams, outparams, float(sr), bufsize, paNoFlag)
    PortAudioStream{eltype, typeof(sr)}(eltype, stream, sr, inchans, outchans, bufsize, device.name)
end

function PortAudioStream(indevname::AbstractString, outdevname::AbstractString, args...)
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

    PortAudioStream(indev, outdev, args...)
end

# if one device is given, use it for input and output
PortAudioStream(device::PortAudioDevice, args...) = PortAudioStream(device, device, args...)
PortAudioStream(device::AbstractString, args...) = PortAudioStream(device, device, args...)

function PortAudioStream(args...)
    outidx = Pa_GetDefaultOutputDevice()
    outdevice = PortAudioDevice(Pa_GetDeviceInfo(outidx), outidx)
    inidx = Pa_GetDefaultInputDevice()
    indevice = PortAudioDevice(Pa_GetDeviceInfo(inidx), inidx)
    PortAudioSink(indevice, outdevice, args...)
end

for (TypeName, Super) in ((:PortAudioSink, :SampleSink),
                          (:PortAudioSource, :SampleSource))
    @eval type $TypeName{T, U} <: $Super
        stream::PortAudioStream{T, U}
        waiters::Vector{Condition}
        jlbuf::Array{T, 2}
        pabuf::Array{T, 2}

        function $TypeName(stream, channels, bufsize)
            jlbuf = zeros(T, busize, channels)
            pabuf = zeros(T, channels, bufsize)
            new(stream, Condition[], jlbuf, pabuf)
        end
    end
end

# most of these methods are the same for Sources and Sinks, so define them on
# the union
typealias PortAudioStream{T, U} Union{PortAudioSink{T, U}, PortAudioSource{T, U}}

function Base.show{T <: PortAudioStream}(io::IO, stream::T)
    println(io, T, "(\"", stream.name, "\")")
    print(io, nchannels(stream), " channels sampled at ", samplerate(stream))
end

function Base.close(stream::PortAudioStream)
    if stream.stream != C_NULL
        Pa_StopStream(stream.stream)
        Pa_CloseStream(stream.stream)
        stream.stream = C_NULL
    end
end

SampleTypes.nchannels(stream::PortAudioStream) = size(stream.jlbuf, 2)
SampleTypes.samplerate(stream::PortAudioStream) = stream.samplerate
Base.eltype{T, U}(::PortAudioStream{T, U}) = T

function SampleTypes.unsafe_write(sink::PortAudioSink, buf::SampleBuf)
    if sink.busy
        c = Condition()
        push!(sink.waiters, c)
        wait(c)
        shift!(sink.waiters)
    end

    total = nframes(buf)
    written = 0
    try
        sink.busy = true

        while written < total
            n = min(size(sink.pabuf, 2), total-written, Pa_GetStreamWriteAvailable(sink.stream))
            bufstart = 1+written
            bufend = n+written
            @devec sink.jlbuf[1:n, :] = buf[bufstart:bufend, :]
            transpose!(sink.pabuf, sink.jlbuf)
            Pa_WriteStream(sink.stream, sink.pabuf, n, false)
            written += n
            sleep(POLL_SECONDS)
        end
    finally
        # make sure we release the busy flag even if the user ctrl-C'ed out
        sink.busy = false
        if length(sink.waiters) > 0
            # let the next task in line go
            notify(sink.waiters[1])
        end
    end

    written
end

function SampleTypes.unsafe_read!(source::PortAudioSource, buf::SampleBuf)
    if source.busy
        c = Condition()
        push!(source.waiters, c)
        wait(c)
        shift!(source.waiters)
    end

    total = nframes(buf)
    read = 0

    try
        source.busy = true

        while read < total
            n = min(size(source.pabuf, 2), total-read, Pa_GetStreamReadAvailable(source.stream))
            Pa_ReadStream(source.stream, source.pabuf, n, false)
            transpose!(source.jlbuf, source.pabuf)
            bufstart = 1+read
            bufend = n+read
            @devec buf[bufstart:bufend, :] = source.jlbuf[1:n, :]
            read += n
            sleep(POLL_SECONDS)
        end

    finally
        source.busy = false
        if length(source.waiters) > 0
            # let the next task in line go
            notify(source.waiters[1])
        end
    end

    read
end

"""This is the callback function that gets called directly in the PortAudio
audio thread, so it's critical that it not interact with the Julia GC"""
function portaudio_callback{T}(inptr::Ptr{T}, outptr::Ptr{T},
        nframes, timeinfo, flags, userdata::Ptr{Ptr{Void}})
    infoptr = Ptr{BufferInfo{T}}(unsafe_load(userdata, 1))
    info = unsafe_load(infoptr)
    bufstateptr = Ptr{BufferState}(unsafe_load(userdata, 2))
    bufstate = unsafe_load(bufstateptr)

    if(bufstate != PortAudioPending)
        # xrun, copy zeros to outbuffer
        memset(info.outbuf, 0, sizeof(T)*nframes*info.outchannels)
        return
    end

    unsafe_copy!(info.inbuf, inptr, nframes * info.inchannels)
    unsafe_copy!(outptr, info.outbuf, nframes * info.outchannels)
    unsafe_store!(bufstateptr, JuliaPending)

    # notify the julia audio task
    ccall(:uv_async_send, Void, (Ptr{Void},), info.taskhandle)

    paContinue
end

# as of portaudio 19.20140130 (which is the HomeBrew version as of 20160319)
# noninterleaved data is not supported for the read/write interface on OSX
# so we need to use another buffer to interleave (transpose)
function audiotask{T}(userdata::Ptr{Ptr{Void}})
    infoptr = Ptr{BufferInfo{T}}(unsafe_load(userdata, 1))
    info = unsafe_load(infoptr)
    bufstateptr = Ptr{BufferState}(unsafe_load(userdata, 2))
    bufstate = unsafe_load(bufstateptr)

    if info.bufstate != JuliaPending
        return
    end

    unsafe_store!(bufstateptr, PortaudioPending)
end

end # module PortAudio

memset(buf, val, count) = ccall(:memset, Ptr{Void},
    (Ptr{Void}, Cint, Csize_t),
    buf, val, count)
