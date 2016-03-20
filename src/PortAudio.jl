module PortAudio

using SampleTypes
using Devectorize

# Get binary dependencies loaded from BinDeps
include( "../deps/deps.jl")
include("libportaudio.jl")

export PortAudioSink, PortAudioSource

const DEFAULT_BUFSIZE=4096
const POLL_SECONDS=0.005

# initialize PortAudio on module load
Pa_Initialize()

type PortAudioDevice
    name::UTF8String
    hostapi::UTF8String
    maxinchans::Int
    maxoutchans::Int
    idx::PaDeviceIndex
end

function devices()
    ndevices = Pa_GetDeviceCount()
    infos = PaDeviceInfo[Pa_GetDeviceInfo(i) for i in 0:(ndevices - 1)]

    [PortAudioDevice(bytestring(d.name),
                        bytestring(Pa_GetHostApiInfo(d.host_api).name),
                        d.max_input_channels,
                        d.max_output_channels,
                        i-1)
     for (i, d) in enumerate(infos)]
end

# paramaterized on the sample type and sampling rate type
for (TypeName, Super) in ((:PortAudioSink, :SampleSink),
                          (:PortAudioSource, :SampleSource))
    @eval type $TypeName{T, U} <: $Super
        stream::PaStream
        samplerate::U
        jlbuf::Array{T, 2}
        pabuf::Array{T, 2}
        waiters::Vector{Condition}
        busy::Bool
    end

    @eval function $TypeName(T, stream, sr, channels, bufsize)
        jlbuf = Array(T, bufsize, channels)
        # as of portaudio 19.20140130 (which is the HomeBrew version as of 20160319)
        # noninterleaved data is not supported for the read/write interface on OSX
        # so we need to use another buffer to interleave (transpose)
        pabuf = Array(T, channels, bufsize)
        waiters = Condition[]

        Pa_StartStream(stream)

        this = $TypeName(stream, sr, jlbuf, pabuf, waiters, false)
        finalizer(this, close)

        this
    end
end

function PortAudioSink(eltype=Float32, sr=48000Hz, channels=2, bufsize=DEFAULT_BUFSIZE)
    stream = Pa_OpenDefaultStream(0, channels, type_to_fmt[eltype], float(sr), bufsize)
    PortAudioSink(eltype, stream, sr, channels, bufsize)
end

function PortAudioSink(device::PortAudioDevice, eltype=Float32, sr=48000Hz, channels=2, bufsize=DEFAULT_BUFSIZE)
    params = Pa_StreamParameters(device.idx, channels, type_to_fmt[eltype], 0.0, C_NULL)
    stream = Pa_OpenStream(C_NULL, pointer_from_objref(params), float(sr), bufsize, paNoFlag)
    PortAudioSink(eltype, stream, sr, channels, bufsize)
end

function PortAudioSink(devname::AbstractString, args...)
    for d in devices()
        if d.name == devname
            return PortAudioSink(d, args...)
        end
    end
end

function PortAudioSource(eltype=Float32, sr=48000Hz, channels=2, bufsize=DEFAULT_BUFSIZE)
    stream = Pa_OpenDefaultStream(channels, 0, type_to_fmt[eltype], float(sr), bufsize)
    PortAudioSource(eltype, stream, sr, channels, bufsize)
end

function PortAudioSource(device::PortAudioDevice, eltype=Float32, sr=48000Hz, channels=2, bufsize=DEFAULT_BUFSIZE)
    params = Pa_StreamParameters(device.idx, channels, type_to_fmt[eltype], 0.0, C_NULL)
    stream = Pa_OpenStream(pointer_from_objref(params), C_NULL, float(sr), bufsize, paNoFlag)
    PortAudioSource(eltype, stream, sr, channels, bufsize)
end

function PortAudioSource(devname::AbstractString, args...)
    for d in devices()
        if d.name == devname
            return PortAudioSource(d, args...)
        end
    end
end


# most of these methods are the same for Sources and Sinks, so define them on
# the union
typealias PortAudioStream{T, U} Union{PortAudioSink{T, U}, PortAudioSource{T, U}}

function Base.close(stream::PortAudioStream)
    Pa_StopStream(stream.stream)
    Pa_CloseStream(stream.stream)
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

end # module PortAudio
