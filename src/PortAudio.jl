module PortAudio

using alsa_plugins_jll: alsa_plugins_jll
using libportaudio_jll: libportaudio
using SampledSignals
using Suppressor: @capture_err

import Base: eltype, getproperty, show
import Base: close, isopen
import Base: read, read!, write

using LinearAlgebra: LinearAlgebra
import LinearAlgebra: transpose!

export PortAudioStream

include("libportaudio.jl")

macro stderr_as_debug(expression)
    quote
        local result
        debug_message = @capture_err result = $(esc(expression))
        @debug debug_message
        result
    end
end

# This size is in frames

# data is passed to and from portaudio in chunks with this many frames, because
# we need to interleave the samples
const CHUNKFRAMES = 128

function versioninfo(io::IO = stdout)
    println(io, Pa_GetVersionText())
    println(io, "Version: ", Pa_GetVersion())
end

struct PortAudioDevice
    name::String
    hostapi::String
    maxinchans::Int
    maxoutchans::Int
    defaultsamplerate::Float64
    idx::PaDeviceIndex
    lowinputlatency::Float64
    lowoutputlatency::Float64
    highinputlatency::Float64
    highoutputlatency::Float64
end

function PortAudioDevice(info::PaDeviceInfo, idx)
    PortAudioDevice(
        unsafe_string(info.name),
        unsafe_string(Pa_GetHostApiInfo(info.host_api).name),
        info.max_input_channels,
        info.max_output_channels,
        info.default_sample_rate,
        idx,
        info.default_low_input_latency,
        info.default_low_output_latency,
        info.default_high_input_latency,
        info.default_high_output_latency,
    )
end

function devices()
    ndevices = Pa_GetDeviceCount()
    infos = PaDeviceInfo[Pa_GetDeviceInfo(i) for i in 0:(ndevices - 1)]
    PortAudioDevice[PortAudioDevice(info, idx - 1) for (idx, info) in enumerate(infos)]
end

# not for external use, used in error message printing
devnames() = join(["\"$(dev.name)\"" for dev in devices()], "\n")

struct Buffer{T}
    device::PortAudioDevice
    chunkbuf::Array{T, 2}
    nchannels::Int
end

#
# PortAudioStream
#

struct PortAudioStream{T}
    samplerate::Float64
    latency::Float64
    pointer_ref::Ref{PaStream}
    warn_xruns::Bool
    recover_xruns::Bool
    sink_buffer::Buffer{T}
    source_buffer::Buffer{T}

    # this inner constructor is generally called via the top-level outer
    # constructor below

    # TODO: pre-fill outbut buffer on init
    # TODO: recover from xruns - currently with low latencies (e.g. 0.01) it
    # will run fine for a while and then fail with the first xrun.
    # TODO: figure out whether we can get deterministic latency...
    function PortAudioStream{T}(
        indev::PortAudioDevice,
        outdev::PortAudioDevice,
        inchans,
        outchans,
        sr,
        latency,
        warn_xruns,
        recover_xruns,
    ) where {T}
        inchans = inchans == -1 ? indev.maxinchans : inchans
        outchans = outchans == -1 ? outdev.maxoutchans : outchans
        inparams = if (inchans == 0)
            Ptr{Pa_StreamParameters}(0)
        else
            Ref(Pa_StreamParameters(indev.idx, inchans, type_to_fmt[T], latency, C_NULL))
        end
        outparams = if (outchans == 0)
            Ptr{Pa_StreamParameters}(0)
        else
            Ref(Pa_StreamParameters(outdev.idx, outchans, type_to_fmt[T], latency, C_NULL))
        end
        # finalizer(close, this)
        pointer_ref = @stderr_as_debug Pa_OpenStream(
            inparams,
            outparams,
            sr,
            0,
            paNoFlag,
            nothing,
            nothing,
        )
        sink_buffer = Buffer{T}(outdev, outchans)
        source_buffer = Buffer{T}(indev, inchans)
        Pa_StartStream(pointer_ref[])
        this = new(
            sr, 
            latency, 
            pointer_ref, 
            warn_xruns,
            recover_xruns,
            sink_buffer,
            source_buffer
        )
        # pre-fill the output stream so we're less likely to underrun
        prefill_output(this.sink)

        this
    end
end

function recover_xrun(stream::PortAudioStream)
    playback = nchannels(stream.sink) > 0
    capture = nchannels(stream.source) > 0
    if playback && capture
        # the best we can do to avoid further xruns is to fill the playback buffer and
        # discard the capture buffer. Really there's a fundamental problem with our
        # read/write-based API where you don't know whether we're currently in a state
        # when the reads and writes should be balanced. In the future we should probably
        # move to some kind of transaction API that forces them to be balanced, and also
        # gives a way for the application to signal that the same number of samples
        # should have been read as written.
        discard_input(stream.source)
        prefill_output(stream.sink)
    end
end

function defaultlatency(devices...)
    maximum(d -> max(d.highoutputlatency, d.highinputlatency), devices)
end

function combine_default_sample_rates(inchans, sampleratein, outchans, samplerateout)
    if inchans > 0 && outchans > 0 && sampleratein != samplerateout
        error(
            """
          Can't open duplex stream with mismatched samplerates (in: $sampleratein, out: $samplerateout).
          Try changing your sample rate in your driver settings or open separate input and output
          streams.
          """,
        )
    elseif inchans > 0
        sampleratein
    else
        samplerateout
    end
end

# this is the top-level outer constructor that all the other outer constructors end up calling
"""
    PortAudioStream(inchannels=2, outchannels=2; options...)
    PortAudioStream(duplexdevice, inchannels=2, outchannels=2; options...)
    PortAudioStream(indevice, outdevice, inchannels=2, outchannels=2; options...)

Audio devices can either be `PortAudioDevice` instances as returned
by `PortAudio.devices()`, or strings with the device name as reported by the
operating system. If a single `duplexdevice` is given it will be used for both
input and output. If no devices are given the system default devices will be
used.

Options:

  - `eltype`:         Sample type of the audio stream (defaults to Float32)
  - `samplerate`:     Sample rate (defaults to device sample rate)
  - `latency`:        Requested latency. Stream could underrun when too low, consider
    using provided device defaults
  - `warn_xruns`:     Display a warning if there is a stream overrun or underrun, which
    often happens when Julia is compiling, or with a particularly large
    GC run. This can be quite verbose so is false by default.
  - `recover_xruns`:  Attempt to recover from overruns and underruns by emptying and
    filling the input and output buffers, respectively. Should result in
    fewer xruns but could make each xrun more audible. True by default.
    Only effects duplex streams.
"""
function PortAudioStream(
    indev::PortAudioDevice,
    outdev::PortAudioDevice,
    inchans = 2,
    outchans = 2;
    eltype = Float32,
    samplerate = -1,
    latency = defaultlatency(indev, outdev),
    warn_xruns = false,
    recover_xruns = true,
)
    if samplerate == -1
        samplerate = combine_default_sample_rates(
            inchans,
            indev.defaultsamplerate,
            outchans,
            outdev.defaultsamplerate,
        )
    end
    PortAudioStream{eltype}(
        indev,
        outdev,
        inchans,
        outchans,
        samplerate,
        latency,
        warn_xruns,
        recover_xruns,
    )
end

# handle device names given as streams
function PortAudioStream(
    indevname::AbstractString,
    outdevname::AbstractString,
    args...;
    kwargs...,
)
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
        error(
            "No device matching \"$outdevname\" found.\nAvailable Devices:\n$(devnames())",
        )
    end

    PortAudioStream(indev, outdev, args...; kwargs...)
end

# if one device is given, use it for input and output, but set inchans=0 so we
# end up with an output-only stream
function PortAudioStream(
    device::Union{PortAudioDevice, AbstractString},
    inchans = 2,
    outchans = 2;
    kwargs...,
)
    PortAudioStream(device, device, inchans, outchans; kwargs...)
end

# use the default input and output devices
function PortAudioStream(inchans = 2, outchans = 2; kwargs...)
    inidx = Pa_GetDefaultInputDevice()
    indevice = PortAudioDevice(Pa_GetDeviceInfo(inidx), inidx)
    outidx = Pa_GetDefaultOutputDevice()
    outdevice = PortAudioDevice(Pa_GetDeviceInfo(outidx), outidx)
    PortAudioStream(indevice, outdevice, inchans, outchans; kwargs...)
end

# handle do-syntax
function PortAudioStream(fn::Function, args...; kwargs...)
    str = PortAudioStream(args...; kwargs...)
    try
        fn(str)
    finally
        close(str)
    end
end

function close(stream::PortAudioStream)
    if stream.pointer_ref[] != C_NULL
        Pa_StopStream(stream.pointer_ref[])
        Pa_CloseStream(stream.pointer_ref[])
        stream.pointer_ref[] = C_NULL
    end
    nothing
end

isopen(stream::PortAudioStream) = stream.pointer_ref[] != C_NULL

SampledSignals.samplerate(stream::PortAudioStream) = stream.samplerate
eltype(stream::PortAudioStream{T}) where {T} = T

read(stream::PortAudioStream, args...) = read(stream.source, args...)
read!(stream::PortAudioStream, args...) = read!(stream.source, args...)
write(stream::PortAudioStream, args...) = write(stream.sink, args...)
function write(sink::PortAudioStream, source::PortAudioStream, args...)
    write(sink.sink, source.source, args...)
end

function show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    println(io, "  Samplerate: ", samplerate(stream), "Hz")
    if nchannels(stream.sink) > 0
        print(
            io,
            "\n  ",
            nchannels(stream.sink),
            " channel sink: \"",
            name(stream.sink),
            "\"",
        )
    end
    if nchannels(stream.source) > 0
        print(
            io,
            "\n  ",
            nchannels(stream.source),
            " channel source: \"",
            name(stream.source),
            "\"",
        )
    end
end

#
# PortAudioSink & PortAudioSource
#

# Define our source and sink types
for (TypeName, Super) in ((:PortAudioSink, :SampleSink), (:PortAudioSource, :SampleSource))
    @eval struct $TypeName{T} <: $Super
        stream::PortAudioStream{T}
    end
end

# provided for backwards compatibility
function getproperty(stream::PortAudioStream, property::Symbol)
    if property === :sink 
        PortAudioSink(stream)
    elseif property === :source
        PortAudioSource(stream)
    else
        getfield(stream, property)
    end
end

function Buffer{T}(device, channels) where T
    # portaudio data comes in interleaved, so we'll end up transposing
    # it back and forth to julia column-major
    chunkbuf = zeros(T, channels, CHUNKFRAMES)
    Buffer(device, chunkbuf, channels)
end

SampledSignals.nchannels(s::PortAudioSource) = s.stream.source_buffer.nchannels
SampledSignals.nchannels(s::PortAudioSink) = s.stream.sink_buffer.nchannels
SampledSignals.samplerate(s::Union{PortAudioSink, PortAudioSource}) = samplerate(s.stream)
eltype(::Union{PortAudioSink{T}, PortAudioSource{T}}) where {T} = T
function close(s::Union{PortAudioSink, PortAudioSource})
    throw(ErrorException("""
        Attempted to close PortAudioSink or PortAudioSource.
        Close the containing PortAudioStream instead
        """))
end
isopen(s::Union{PortAudioSink, PortAudioSource}) = isopen(s.stream)
name(s::PortAudioSink) = s.stream.sink_buffer.device.name
name(s::PortAudioSource) = s.stream.source_buffer.device.name

function show(io::IO, ::Type{PortAudioSink{T}}) where {T}
    print(io, "PortAudioSink{$T}")
end

function show(io::IO, ::Type{PortAudioSource{T}}) where {T}
    print(io, "PortAudioSource{$T}")
end

function show(io::IO, stream::T) where {T <: Union{PortAudioSink, PortAudioSource}}
    print(io, nchannels(stream), "-channel ", T, "(\"", name(stream), "\")")
end

function SampledSignals.unsafe_write(
    sink::PortAudioSink,
    buf::Array,
    frameoffset,
    framecount,
)
    nwritten = 0
    sink_buffer = sink.stream.sink_buffer
    while nwritten < framecount
        n = min(framecount - nwritten, CHUNKFRAMES)
        # make a buffer of interleaved samples
        transpose!(
            view(sink_buffer.chunkbuf, :, 1:n),
            view(buf, (1:n) .+ nwritten .+ frameoffset, :),
        )
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        err = Pa_WriteStream(sink.stream.pointer_ref[], sink_buffer.chunkbuf, n, sink.stream.warn_xruns)
        if err ∈ (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && sink.stream.recover_xruns
            recover_xrun(sink.stream)
        end
        nwritten += n
    end

    nwritten
end

function SampledSignals.unsafe_read!(
    source::PortAudioSource,
    buf::Array,
    frameoffset,
    framecount,
)
    source_buffer = source.stream.source_buffer
    nread = 0
    while nread < framecount
        n = min(framecount - nread, CHUNKFRAMES)
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        err = Pa_ReadStream(
            source.stream.pointer_ref[],
            source_buffer.chunkbuf,
            n,
            source.stream.warn_xruns,
        )
        if err ∈ (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && source.stream.recover_xruns
            recover_xrun(source.stream)
        end
        # de-interleave the samples
        transpose!(
            view(buf, (1:n) .+ nread .+ frameoffset, :),
            view(source_buffer.chunkbuf, :, 1:n),
        )

        nread += n
    end

    nread
end

"""
    prefill_output(sink::PortAudioSink)

Fill the playback buffer of the given sink.
"""
function prefill_output(sink::PortAudioSink)
    if nchannels(sink) > 0
        towrite = Pa_GetStreamWriteAvailable(sink.stream.pointer_ref[])
        sink_buffer = sink.stream.sink_buffer
        while towrite > 0
            n = min(towrite, CHUNKFRAMES)
            fill!(sink_buffer.chunkbuf, zero(eltype(sink_buffer.chunkbuf)))
            Pa_WriteStream(sink.stream.pointer_ref[], sink_buffer.chunkbuf, n, false)
            towrite -= n
        end
    end
end

"""
    discard_input(source::PortAudioSource)

Read and discard data from the capture buffer.
"""
function discard_input(source::PortAudioSource)
    toread = Pa_GetStreamReadAvailable(source.stream.pointer_ref[])
    source_buffer = source.stream.source_buffer
    while toread > 0
        n = min(toread, CHUNKFRAMES)
        Pa_ReadStream(source.stream.pointer_ref[], source_buffer.chunkbuf, n, false)
        toread -= n
    end
end

function seek_alsa_conf(searchdirs)
    confdir_idx = findfirst(searchdirs) do d
        isfile(joinpath(d, "alsa.conf"))
    end
    if confdir_idx === nothing
        throw(
            ErrorException("""
                           Could not find ALSA config directory. Searched:
                           $(join(searchdirs, "\n"))

                           If ALSA is installed, set the "ALSA_CONFIG_DIR" environment
                           variable. The given directory should have a file "alsa.conf".

                           If it would be useful to others, please file an issue at
                           https://github.com/JuliaAudio/PortAudio.jl/issues
                           with your alsa config directory so we can add it to the search
                           paths.
                           """),
        )
    end
    searchdirs[confdir_idx]
end

function __init__()
    if Sys.islinux()
        envkey = "ALSA_CONFIG_DIR"
        if envkey ∉ keys(ENV)
            ENV[envkey] =
                seek_alsa_conf(["/usr/share/alsa", "/usr/local/share/alsa", "/etc/alsa"])
        end

        plugin_key = "ALSA_PLUGIN_DIR"
        if plugin_key ∉ keys(ENV) && alsa_plugins_jll.is_available()
            ENV[plugin_key] = joinpath(alsa_plugins_jll.artifact_dir, "lib", "alsa-lib")
        end
    end
    # initialize PortAudio on module load. libportaudio prints a bunch of
    # junk to STDOUT on initialization, so we swallow it.
    # TODO: actually check the junk to make sure there's nothing in there we
    # don't expect
    @stderr_as_debug Pa_Initialize()

    atexit() do
        Pa_Terminate()
    end
end

end # module PortAudio