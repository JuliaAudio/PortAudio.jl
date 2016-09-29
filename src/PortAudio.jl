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

# These sizes are all in frames
# the block size is what we request from portaudio if no blocksize is given.
# The ringbuffer and pre-fill will be twice the blocksize
const DEFAULT_BLOCKSIZE=4096
# data is passed to and from the ringbuffer in chunks with this many frames
# it should be at most the ringbuffer size, and must evenly divide into the
# the underlying portaudio buffer size. E.g. if PortAudio is running with a
# 2048-frame buffer period, the chunk size can be 2048, 1024, 512, 256, etc.
const CHUNKSIZE=128

function __init__()
    # initialize PortAudio on module load
    swallow_stderr() do
        Pa_Initialize()
    end

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
    defaultsamplerate::Float64
    idx::PaDeviceIndex
end

PortAudioDevice(info::PaDeviceInfo, idx) = PortAudioDevice(
        unsafe_string(info.name),
        unsafe_string(Pa_GetHostApiInfo(info.host_api).name),
        info.max_input_channels,
        info.max_output_channels,
        info.default_sample_rate,
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
    synced::Bool
end

type PortAudioStream{T}
    samplerate::Float64
    blocksize::Int
    stream::PaStream
    sink # untyped because of circular type definition
    source # untyped because of circular type definition
    bufinfo::CallbackInfo{T} # immutable data used in the portaudio callback

    # this inner constructor is generally called via the top-level outer
    # constructor below
    function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
            inchans, outchans, sr, blocksize, synced)
        inchans = inchans == -1 ? indev.maxinchans : inchans
        outchans = outchans == -1 ? outdev.maxoutchans : outchans
        inparams = (inchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(indev.idx, inchans, type_to_fmt[T], 0.0, C_NULL))
        outparams = (outchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(outdev.idx, outchans, type_to_fmt[T], 0.0, C_NULL))
        this = new(sr, blocksize, C_NULL)
        finalizer(this, close)
        this.sink = PortAudioSink{T}(outdev.name, this, outchans, blocksize*2)
        this.source = PortAudioSource{T}(indev.name, this, inchans, blocksize*2)
        if synced && inchans > 0 && outchans > 0
            # we've got a synchronized duplex stream. initialize with the output buffer full
            write(this.sink, SampleBuf(zeros(T, blocksize*2, outchans), sr))
        end
        this.bufinfo = CallbackInfo(inchans, this.source.ringbuf,
                                    outchans, this.sink.ringbuf, synced)
        this.stream = swallow_stderr() do
            Pa_OpenStream(inparams, outparams, float(sr), blocksize,
                paNoFlag, pa_callbacks[T], fieldptr(this, :bufinfo))
        end

        Pa_StartStream(this.stream)

        this
    end
end

# this is the top-level outer constructor that all the other outer constructors
# end up calling
function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
        inchans=2, outchans=2; eltype=Float32, samplerate=-1, blocksize=DEFAULT_BLOCKSIZE, synced=false)
    if samplerate == -1
        sampleratein = indev.defaultsamplerate
        samplerateout = outdev.defaultsamplerate
        if inchans > 0 && outchans > 0 && sampleratein != samplerateout
            error("""
            Can't open duplex stream with mismatched samplerates (in: $sampleratein, out: $samplerateout).
                   Try changing your sample rate in your driver settings or open separate input and output
                   streams""")
        elseif inchans > 0
            samplerate = sampleratein
        else
            samplerate = samplerateout
        end
    end
    PortAudioStream{eltype}(indev, outdev, inchans, outchans, samplerate, blocksize, synced)
end

# handle device names given as streams
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

# if one device is given, use it for input and output, but set inchans=0 so we
# end up with an output-only stream
function PortAudioStream(device::PortAudioDevice, inchans=2, outchans=2; kwargs...)
    PortAudioStream(device, device, inchans, outchans; kwargs...)
end
function PortAudioStream(device::AbstractString, inchans=2, outchans=2; kwargs...)
    PortAudioStream(device, device, inchans, outchans; kwargs...)
end

# use the default input and output devices
function PortAudioStream(inchans=2, outchans=2; kwargs...)
    inidx = Pa_GetDefaultInputDevice()
    indevice = PortAudioDevice(Pa_GetDeviceInfo(inidx), inidx)
    outidx = Pa_GetDefaultOutputDevice()
    outdevice = PortAudioDevice(Pa_GetDeviceInfo(outidx), outidx)
    PortAudioStream(indevice, outdevice, inchans, outchans; kwargs...)
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
Base.eltype{T}(stream::PortAudioStream{T}) = T

Base.read(stream::PortAudioStream, args...) = read(stream.source, args...)
Base.read!(stream::PortAudioStream, args...) = read!(stream.source, args...)
Base.write(stream::PortAudioStream, args...) = write(stream.sink, args...)
Base.write(sink::PortAudioStream, source::PortAudioStream, args...) = write(sink.sink, source.source, args...)
Base.flush(stream::PortAudioStream) = flush(stream.sink)

function Base.show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    println(io, "  Samplerate: ", samplerate(stream), "Hz")
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
    @eval type $TypeName{T} <: $Super
        name::UTF8String
        stream::PortAudioStream{T}
        chunkbuf::Array{T, 2}
        ringbuf::LockFreeRingBuffer{T}
        nchannels::Int

        function $TypeName(name, stream, channels, ringbufsize)
            # portaudio data comes in interleaved, so we'll end up transposing
            # it back and forth to julia column-major
            chunkbuf = zeros(T, channels, CHUNKSIZE)
            ringbuf = LockFreeRingBuffer(T, ringbufsize * channels)
            new(name, stream, chunkbuf, ringbuf, channels)
        end
    end
end

SampledSignals.nchannels(s::Union{PortAudioSink, PortAudioSource}) = s.nchannels
SampledSignals.samplerate(s::Union{PortAudioSink, PortAudioSource}) = samplerate(s.stream)
SampledSignals.blocksize(s::Union{PortAudioSink, PortAudioSource}) = s.stream.blocksize
Base.eltype{T}(::Union{PortAudioSink{T}, PortAudioSource{T}}) = T
Base.close(s::Union{PortAudioSink, PortAudioSource}) = close(s.ringbuf)

function Base.show{T <: Union{PortAudioSink, PortAudioSource}}(io::IO, stream::T)
    println(io, T, "(\"", stream.name, "\")")
    print(io, nchannels(stream), " channels")
end

function Base.flush(sink::PortAudioSink)
    while nwritable(sink.ringbuf) < length(sink.ringbuf)
        wait(sink.ringbuf)
    end
end

function SampledSignals.unsafe_write(sink::PortAudioSink, buf::Array, frameoffset, framecount)
    nwritten = 0
    while nwritten < framecount
        while nwritable(sink.ringbuf) == 0
            wait(sink.ringbuf)
        end
        # in 0.4 transpose! throws an error if the range is a UInt
        writable = div(nwritable(sink.ringbuf), nchannels(sink))
        towrite = Int(min(writable, CHUNKSIZE, framecount-nwritten))
        # make a buffer of interleaved samples
        transpose!(view(sink.chunkbuf, :, 1:towrite),
                   view(buf, (1:towrite)+nwritten+frameoffset, :))
        write(sink.ringbuf, sink.chunkbuf, towrite*nchannels(sink))

        nwritten += towrite
    end

    nwritten
end

function SampledSignals.unsafe_read!(source::PortAudioSource, buf::Array, frameoffset, framecount)
    nread = 0
    while nread < framecount
        while nreadable(source.ringbuf) == 0
            wait(source.ringbuf)
        end
        # in 0.4 transpose! throws an error if the range is a UInt
        readable = div(nreadable(source.ringbuf), nchannels(source))
        toread = Int(min(readable, CHUNKSIZE, framecount-nread))
        read!(source.ringbuf, source.chunkbuf, toread*nchannels(source))
        # de-interleave the samples
        transpose!(view(buf, (1:toread)+nread+frameoffset, :),
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
    # if there are no channels, treat it as if we can write as many 0-frame channels as we want
    framesreadable = info.outchannels > 0 ? div(nreadable(info.outbuf), info.outchannels) : nframes
    frameswritable = info.inchannels > 0 ? div(nwritable(info.inbuf), info.inchannels) : nframes
    if info.synced
        framesreadable = min(framesreadable, frameswritable)
        frameswritable = framesreadable
    end
    towrite = min(frameswritable, nframes) * info.inchannels
    toread = min(framesreadable, nframes) * info.outchannels

    read!(info.outbuf, outptr, toread)
    write(info.inbuf, inptr, towrite)

    if framesreadable < nframes
        outsamples = nframes * info.outchannels
        # xrun, copy zeros to outbuffer
        # TODO: send a notification to an error msg ringbuf
        memset(outptr+sizeof(T)*toread, 0, sizeof(T)*(outsamples-toread))
    end

    paContinue
end


"""Call the given function and discard stdout and stderr"""
function swallow_stderr(f)
    origerr = STDERR
    (errread, errwrite) = redirect_stderr()
    result = f()
    redirect_stderr(origerr)
    close(errwrite)
    close(errread)

    result
end

memset(buf, val, count) = ccall(:memset, Ptr{Void},
    (Ptr{Void}, Cint, Csize_t),
    buf, val, count)

end # module PortAudio
