module PortAudio

using alsa_plugins_jll: alsa_plugins_jll
using libportaudio_jll: libportaudio
using SampledSignals
using Suppressor: @capture_err

import Base: eltype, getproperty, show
import Base: close, isopen
import Base: read, read!, write

using LinearAlgebra: transpose!

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

struct Bounds
    max_channels::Int
    low_latency::Float64
    high_latency::Float64
end

struct PortAudioDevice
    name::String
    hostapi::String
    defaultsamplerate::Float64
    idx::PaDeviceIndex
    input_bounds::Bounds
    output_bounds::Bounds
end

function PortAudioDevice(info::PaDeviceInfo, idx)
    PortAudioDevice(
        unsafe_string(info.name),
        unsafe_string(Pa_GetHostApiInfo(info.host_api).name),
        info.default_sample_rate,
        idx,
        Bounds(
            info.max_input_channels,
            info.default_low_input_latency,
            info.default_high_input_latency,
        ),
        Bounds(
            info.max_output_channels,
            info.default_low_output_latency,
            info.default_high_output_latency,
        ),
    )
end

name(device::PortAudioDevice) = device.name

function devices()
    [PortAudioDevice(Pa_GetDeviceInfo(i), i) for i in 0:(Pa_GetDeviceCount() - 1)]
end

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
end

function make_parameters(device, channels, T, latency, host_api_specific_stream_info)
    if channels == 0
        Ptr{Pa_StreamParameters}(0)
    else
        Ref(
            Pa_StreamParameters(
                device.idx,
                channels,
                type_to_fmt[T],
                latency,
                convert_nothing(host_api_specific_stream_info),
            ),
        )
    end
end

function fill_max_channels(channels, bounds)
    if channels === max
        bounds.max_channels
    else
        channels
    end
end

function recover_xrun(stream::PortAudioStream)
    sink = stream.sink
    source = stream.source
    if nchannels(sink) > 0 && nchannels(source) > 0
        # the best we can do to avoid further xruns is to fill the playback buffer and
        # discard the capture buffer. Really there's a fundamental problem with our
        # read/write-based API where you don't know whether we're currently in a state
        # when the reads and writes should be balanced. In the future we should probably
        # move to some kind of transaction API that forces them to be balanced, and also
        # gives a way for the application to signal that the same number of samples
        # should have been read as written.
        discard_input(source)
        prefill_output(sink)
    end
end

function defaultlatency(input_device, output_device)
    max(input_device.input_bounds.high_latency, output_device.output_bounds.high_latency)
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
    samplerate = combine_default_sample_rates(
        inchans,
        indev.defaultsamplerate,
        outchans,
        outdev.defaultsamplerate,
    ),
    latency = defaultlatency(indev, outdev),
    warn_xruns = false,
    recover_xruns = true,
    frames_per_buffer = 0,
    flags = paNoFlag,
    callback = nothing,
    user_data = nothing,
    input_info = nothing,
    output_info = nothing,
)
    inchans = fill_max_channels(inchans, indev.input_bounds)
    outchans = fill_max_channels(outchans, outdev.output_bounds)
    pointer_ref = @stderr_as_debug Pa_OpenStream(
        make_parameters(indev, inchans, eltype, latency, input_info),
        make_parameters(outdev, outchans, eltype, latency, output_info),
        samplerate,
        frames_per_buffer,
        flags,
        callback,
        user_data,
    )
    Pa_StartStream(pointer_ref[])
    this = PortAudioStream{eltype}(
        samplerate,
        latency,
        pointer_ref,
        warn_xruns,
        recover_xruns,
        Buffer{eltype}(outdev, outchans),
        Buffer{eltype}(indev, inchans),
    )
    # pre-fill the output stream so we're less likely to underrun
    prefill_output(this.sink)
    this
end

function device_by_name(device_name)
    error_message = IOBuffer()
    write(error_message, "No device matching ")
    write(error_message, repr(device_name))
    write(error_message, " found.\nAvailable Devices:\n")
    for device in devices()
        potential_match = name(device)
        if potential_match == device_name
            return device
        end
        write(error_message, repr(potential_match))
        write(error_message, '\n')
    end
    error(String(take!(error_message)))
end

# handle device names given as streams
function PortAudioStream(
    indevname::AbstractString,
    outdevname::AbstractString,
    args...;
    kwargs...,
)
    PortAudioStream(
        device_by_name(indevname),
        device_by_name(outdevname),
        args...;
        kwargs...,
    )
end

# if one device is given, use it for input and output, but set inchans=0 so we
# end up with an output-only stream
function PortAudioStream(
    device::Union{PortAudioDevice, AbstractString},
    inchans = 0,
    outchans = 2;
    kwargs...,
)
    PortAudioStream(device, device, inchans, outchans; kwargs...)
end

# use the default input and output devices
function PortAudioStream(inchans = 2, outchans = 2; kwargs...)
    inidx = Pa_GetDefaultInputDevice()
    outidx = Pa_GetDefaultOutputDevice()
    PortAudioStream(
        PortAudioDevice(Pa_GetDeviceInfo(inidx), inidx),
        PortAudioDevice(Pa_GetDeviceInfo(outidx), outidx),
        inchans,
        outchans;
        kwargs...,
    )
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
    pointer_ref = stream.pointer_ref
    pointer = pointer_ref[]
    if pointer != C_NULL
        Pa_StopStream(pointer)
        Pa_CloseStream(pointer)
        pointer_ref[] = C_NULL
    end
    nothing
end

isopen(stream::PortAudioStream) = stream.pointer_ref[] != C_NULL

SampledSignals.samplerate(stream::PortAudioStream) = stream.samplerate
eltype(::Type{PortAudioStream{T}}) where {T} = T

read(stream::PortAudioStream, args...) = read(stream.source, args...)
read!(stream::PortAudioStream, args...) = read!(stream.source, args...)
write(stream::PortAudioStream, args...) = write(stream.sink, args...)
function write(sink::PortAudioStream, source::PortAudioStream, args...)
    write(sink.sink, source.source, args...)
end

function show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    print(io, "  Samplerate: ", samplerate(stream), "Hz")
    sink = stream.sink
    if nchannels(sink) > 0
        print(io, "\n  ")
        show(io, sink)
    end
    source = stream.source
    if nchannels(source) > 0
        print(io, "\n  ")
        show(io, source)
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

function Buffer{T}(device, channels) where {T}
    # portaudio data comes in interleaved, so we'll end up transposing
    # it back and forth to julia column-major
    chunkbuf = zeros(T, channels, CHUNKFRAMES)
    Buffer(device, chunkbuf, channels)
end

SampledSignals.nchannels(buffer::Buffer) = buffer.nchannels
name(buffer::Buffer) = name(buffer.device)

SampledSignals.nchannels(s::PortAudioSource) = nchannels(s.stream.source_buffer)
SampledSignals.nchannels(s::PortAudioSink) = nchannels(s.stream.sink_buffer)
SampledSignals.samplerate(s::Union{PortAudioSink, PortAudioSource}) = samplerate(s.stream)
eltype(::Type{<:Union{PortAudioSink{T}, PortAudioSource{T}}}) where {T} = T
function close(::Union{PortAudioSink, PortAudioSource})
    throw(ErrorException("""
        Attempted to close PortAudioSink or PortAudioSource.
        Close the containing PortAudioStream instead
        """))
end
isopen(s::Union{PortAudioSink, PortAudioSource}) = isopen(s.stream)
name(s::PortAudioSink) = name(s.stream.sink_buffer)
name(s::PortAudioSource) = name(s.stream.source_buffer)

kind(::PortAudioSink) = "sink"
kind(::PortAudioSource) = "source"
function show(io::IO, sink_or_source::Union{PortAudioSink, PortAudioSource})
    print(
        io,
        nchannels(sink_or_source),
        " channel ",
        kind(sink_or_source),
        ": ",
        repr(name(sink_or_source)),
    )
end

function interleave!(long, wide, n, already, offset, wide_to_long)
    long_view = view(long, (1:n) .+ already .+ offset, :)
    wide_view = view(wide, :, 1:n)
    if wide_to_long
        transpose!(long_view, wide_view)
    else
        transpose!(wide_view, long_view)
    end
end

function handle_xrun(stream, error_code, recover_xruns)
    if recover_xruns &&
       (error_code == PA_OUTPUT_UNDERFLOWED || error_code == PA_INPUT_OVERFLOWED)
        recover_xrun(stream)
    end
end

function SampledSignals.unsafe_write(
    sink::PortAudioSink,
    buf::Array,
    frameoffset,
    framecount,
)
    stream = sink.stream
    pointer = stream.pointer_ref[]
    chunkbuf = stream.sink_buffer.chunkbuf
    warn_xruns = stream.warn_xruns
    recover_xruns = stream.recover_xruns
    nwritten = 0
    while nwritten < framecount
        n = min(framecount - nwritten, CHUNKFRAMES)
        # make a buffer of interleaved samples
        interleave!(buf, chunkbuf, n, nwritten, frameoffset, false)
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        handle_xrun(
            stream,
            Pa_WriteStream(pointer, chunkbuf, n, warn_xruns = warn_xruns),
            recover_xruns,
        )
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
    stream = source.stream
    pointer = stream.pointer_ref[]
    chunkbuf = stream.source_buffer.chunkbuf
    warn_xruns = stream.warn_xruns
    recover_xruns = stream.recover_xruns
    nread = 0
    while nread < framecount
        n = min(framecount - nread, CHUNKFRAMES)
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        handle_xrun(
            stream,
            Pa_ReadStream(pointer, chunkbuf, n, warn_xruns = warn_xruns),
            recover_xruns,
        )
        # de-interleave the samples
        interleave!(buf, chunkbuf, n, nread, frameoffset, true)
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
        stream = sink.stream
        pointer = stream.pointer_ref[]
        chunkbuf = stream.sink_buffer.chunkbuf
        towrite = Pa_GetStreamWriteAvailable(pointer)
        while towrite > 0
            n = min(towrite, CHUNKFRAMES)
            fill!(chunkbuf, zero(eltype(chunkbuf)))
            Pa_WriteStream(pointer, chunkbuf, n, warn_xruns = false)
            towrite -= n
        end
    end
end

"""
    discard_input(source::PortAudioSource)

Read and discard data from the capture buffer.
"""
function discard_input(source::PortAudioSource)
    stream = source.stream
    pointer = stream.pointer_ref[]
    chunkbuf = stream.source_buffer.chunkbuf
    toread = Pa_GetStreamReadAvailable(pointer)
    while toread > 0
        n = min(toread, CHUNKFRAMES)
        Pa_ReadStream(pointer, chunkbuf, n, warn_xruns = false)
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
