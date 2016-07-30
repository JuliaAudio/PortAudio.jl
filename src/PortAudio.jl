__precompile__()

module PortAudio

using SampledSignals
using Devectorize
using RingBuffers
using Compat
import Compat: UTF8String, view

# Get binary dependencies loaded from BinDeps
include( "../deps/deps.jl")
include("libportaudio.jl")

export PortAudioStream

# Size of the ringbuffer in frames. 85ms latency at 48kHz
const DEFAULT_BLOCKSIZE=4096
# data is passed to and from the ringbuffer in chunks with this many frames
# it should be at most the ringbuffer size, and must evenly divide into the
# the underlying portaudio buffer size. E.g. if PortAudio is running with a
# 2048-frame buffer period, the chunk size can be 2048, 1024, 512, 256, etc.
const CHUNKSIZE=128

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
        unsafe_string(info.name),
        unsafe_string(Pa_GetHostApiInfo(info.host_api).name),
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
    offset = fieldoffset(T, fieldnum)
    FT = fieldtype(T, field)

    Ptr{FT}(pointer_from_objref(obj) + offset)
end

# we want this to be immutable so we can stack allocate it
immutable CallbackInfo{T}
    inchannels::Int
    inbuf::LockFreeRingBuffer{T}
    outchannels::Int
    outbuf::LockFreeRingBuffer{T}
end

# paramaterized on the sample type and sampling rate type
type PortAudioStream{T, U}
    samplerate::U
    blocksize::Int
    stream::PaStream
    sink # untyped because of circular type definition
    source # untyped because of circular type definition
    bufinfo::CallbackInfo{T} # immutable data used in the portaudio callback

    # this inner constructor is generally called via the top-level outer
    # constructor below
    function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
            inchans, outchans, sr, blocksize)
        inparams = (inchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(indev.idx, inchans, type_to_fmt[T], 0.0, C_NULL))
        outparams = (outchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(outdev.idx, outchans, type_to_fmt[T], 0.0, C_NULL))
        this = new(sr, blocksize, C_NULL)
        finalizer(this, close)
        this.sink = PortAudioSink{T, U}(outdev.name, this, outchans, blocksize)
        this.source = PortAudioSource{T, U}(indev.name, this, inchans, blocksize)
        if inchans > 0 && outchans > 0
            # we've got a duplex stream. initialize with the output buffer full
            write(this.sink, SampleBuf(zeros(T, blocksize, outchans), sr))
        end
        this.bufinfo = CallbackInfo(inchans, this.source.ringbuf,
                                    outchans, this.sink.ringbuf)
        this.stream = Pa_OpenStream(inparams, outparams, float(sr), blocksize,
            paNoFlag, pa_callbacks[T], fieldptr(this, :bufinfo))

        Pa_StartStream(this.stream)

        this
    end
end

# this is the top-level outer constructor that all the other outer constructors
# end up calling
function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
        inchans=2, outchans=2; eltype=Float32, samplerate=48000Hz, blocksize=DEFAULT_BLOCKSIZE)
    PortAudioStream{eltype, typeof(samplerate)}(indev, outdev, inchans, outchans, samplerate, blocksize)
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
        close(stream.source)
        close(stream.sink)
        stream.stream = C_NULL
    end

    nothing
end

Base.isopen(stream::PortAudioStream) = stream.stream != C_NULL

SampledSignals.samplerate(stream::PortAudioStream) = stream.samplerate
Base.eltype{T, U}(stream::PortAudioStream{T, U}) = T

Base.read(stream::PortAudioStream, args...) = read(stream.source, args...)
Base.read!(stream::PortAudioStream, args...) = read!(stream.source, args...)
Base.write(stream::PortAudioStream, args...) = write(stream.sink, args...)
Base.write(sink::PortAudioStream, source::PortAudioStream, args...) = write(sink.sink, source.source, args...)

function Base.show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    println(io, "  Samplerate: ", samplerate(stream))
    print(io, "  Buffer Size: ", stream.blocksize, " frames")
    if nchannels(stream.sink) > 0
        print(io, "\n  ", nchannels(stream.sink), " channel sink: \"", stream.sink.name, "\"")
    end
    if nchannels(stream.source) > 0
        print(io, "\n  ", nchannels(stream.source), " channel source: \"", stream.source.name, "\"")
    end
end

# Define our source and sink types
for (TypeName, Super) in ((:PortAudioSink, :SampleSink),
                          (:PortAudioSource, :SampleSource))
    @eval type $TypeName{T, U} <: $Super
        name::UTF8String
        stream::PortAudioStream{T, U}
        chunkbuf::Array{T, 2}
        ringbuf::LockFreeRingBuffer{T}
        nchannels::Int

        function $TypeName(name, stream, channels, blocksize)
            # portaudio data comes in interleaved, so we'll end up transposing
            # it back and forth to julia column-major
            chunkbuf = zeros(T, channels, CHUNKSIZE)
            ringbuf = LockFreeRingBuffer(T, blocksize * channels)
            new(name, stream, chunkbuf, ringbuf, channels)
        end
    end
end

SampledSignals.nchannels(s::Union{PortAudioSink, PortAudioSource}) = s.nchannels
SampledSignals.samplerate(s::Union{PortAudioSink, PortAudioSource}) = samplerate(s.stream)
SampledSignals.blocksize(s::Union{PortAudioSink, PortAudioSource}) = s.stream.blocksize
Base.eltype{T, U}(::Union{PortAudioSink{T, U}, PortAudioSource{T, U}}) = T
Base.close(s::Union{PortAudioSink, PortAudioSource}) = close(s.ringbuf)

function Base.show{T <: Union{PortAudioSink, PortAudioSource}}(io::IO, stream::T)
    println(io, T, "(\"", stream.name, "\")")
    print(io, nchannels(stream), " channels")
end


function SampledSignals.unsafe_write(sink::PortAudioSink, buf::SampleBuf)
    total = nframes(buf)
    nwritten = 0
    while nwritten < total
        towrite = min(CHUNKSIZE, total-nwritten)
        # make a buffer of interleaved samples
        # TODO: don't directly access buf.data
        transpose!(view(sink.chunkbuf, :, 1:towrite),
                   view(buf.data, (1:towrite)+nwritten, :))
        while nwritable(sink.ringbuf) < towrite
            wait(sink.ringbuf)
        end
        write(sink.ringbuf, sink.chunkbuf, towrite*nchannels(sink))

        nwritten += towrite
    end

    nwritten
end

function SampledSignals.unsafe_read!(source::PortAudioSource, buf::SampleBuf)
    total = nframes(buf)
    nread = 0
    while nread < total
        toread = min(CHUNKSIZE, total-nread)
        while nreadable(source.ringbuf) < toread
            wait(source.ringbuf)
        end
        read!(source.ringbuf, source.chunkbuf, toread*nchannels(source))
        # de-interleave the samples
        # TODO: don't directly access buf.data
        transpose!(view(buf.data, (1:toread)+nread, :),
                   view(source.chunkbuf, :, 1:toread))

        nread += toread
    end

    nread
end

# This is the callback function that gets called directly in the PortAudio
# audio thread, so it's critical that it not interact with the Julia GC
function portaudio_callback{T}(inptr::Ptr{T}, outptr::Ptr{T},
        nframes, timeinfo, flags, userdata::Ptr{CallbackInfo{T}})
    info = unsafe_load(userdata)
    insamples = nframes * info.inchannels
    outsamples = nframes * info.outchannels

    if nreadable(info.outbuf) < outsamples ||
            nwritable(info.inbuf) < insamples
        # xrun, copy zeros to outbuffer
        # TODO: send a notification to an error msg ringbuf
        # TODO (maybe): we could do a partial write if there's anything in the
        # ringbuf, and minimize the dropout
        memset(outptr, 0, sizeof(T)*nframes*info.outchannels)
        return paContinue
    end

    read!(info.outbuf, outptr, outsamples)
    write(info.inbuf, inptr, insamples)

    paContinue
end


memset(buf, val, count) = ccall(:memset, Ptr{Void},
    (Ptr{Void}, Cint, Csize_t),
    buf, val, count)

end # module PortAudio
