module PortAudio

using alsa_plugins_jll: alsa_plugins_jll
import Base: close, eltype, getproperty, isopen, read, read!, show, write
using libportaudio_jll: libportaudio
using LinearAlgebra: transpose!
import SampledSignals: nchannels, samplerate, unsafe_read!, unsafe_write
using SampledSignals: SampleSink, SampleSource
using Suppressor: @capture_err

export PortAudioStream

include("libportaudio.jl")
using .LibPortAudio:
    Pa_CloseStream,
    PaDeviceIndex,
    PaDeviceInfo,
    PaErrorCode,
    Pa_GetDefaultInputDevice,
    Pa_GetDefaultOutputDevice,
    Pa_GetDeviceCount,
    Pa_GetDeviceInfo,
    Pa_GetErrorText,
    Pa_GetHostApiInfo,
    Pa_GetStreamReadAvailable,
    Pa_GetStreamWriteAvailable,
    Pa_GetVersionText,
    Pa_GetVersion,
    PaHostApiTypeId,
    Pa_Initialize,
    paInputOverflowed,
    paNoFlag,
    Pa_OpenStream,
    paOutputUnderflowed,
    Pa_ReadStream,
    PaSampleFormat,
    Pa_StartStream,
    Pa_StopStream,
    PaStream,
    PaStreamParameters,
    Pa_Terminate,
    Pa_WriteStream

function safe_load(result, an_error)
    if result == C_NULL
        throw(an_error)
    end
    unsafe_load(result)
end

"""
Call the given expression in a separate thread, waiting on the result. This is
useful when running code that would otherwise block the Julia process (like a
`ccall` into a function that does IO).
"""
macro tcall(ex)
    :(fetch(Base.Threads.@spawn $(esc(ex))))
end

# because we're calling Pa_ReadStream and PA_WriteStream from separate threads,
# we put a mutex around libportaudio calls
const pamutex = ReentrantLock()

macro locked(ex)
    quote
        lock(pamutex) do
            $(esc(ex))
        end
    end
end

convert_nothing(::Nothing) = C_NULL
convert_nothing(something) = something

function is_xrun(error_code)
    error_code == paOutputUnderflowed || error_code == paInputOverflowed
end

function is_xrun(number::Integer)
    is_xrun(PaErrorCode(number))
end

function get_error_text(error_code)
    unsafe_string(@locked Pa_GetErrorText(error_code))
end

# General utility function to handle the status from the Pa_* functions
function handle_status(err; warn_xruns::Bool = true)
    if Int(err) < 0
        if is_xrun(err)
            if warn_xruns
                @warn("libportaudio: " * get_error_text(err))
            end
        else
            throw(ErrorException("libportaudio: " * get_error_text(err)))
        end
    end
    err
end

macro stderr_as_debug(expression)
    quote
        local result
        debug_message = @capture_err result = $(esc(expression))
        @debug debug_message
        result
    end
end

function initialize()
    @stderr_as_debug handle_status(@locked Pa_Initialize())
end

function terminate()
    handle_status(@locked Pa_Terminate())
end

# This size is in frames

# data is passed to and from portaudio in chunks with this many frames, because
# we need to interleave the samples
const CHUNKFRAMES = 128

function versioninfo(io::IO = stdout)
    println(io, unsafe_string(@locked Pa_GetVersionText()))
    println(io, "Version: ", @locked Pa_GetVersion())
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
        unsafe_string(
            safe_load(
                (@locked Pa_GetHostApiInfo(info.hostApi)),
                BoundsError(Pa_GetHostApiInfo, idx),
            ).name,
        ),
        info.defaultSampleRate,
        idx,
        Bounds(
            info.maxInputChannels,
            info.defaultLowInputLatency,
            info.defaultHighInputLatency,
        ),
        Bounds(
            info.maxOutputChannels,
            info.defaultLowOutputLatency,
            info.defaultHighInputLatency,
        ),
    )
end

name(device::PortAudioDevice) = device.name

function get_default_input_device()
    handle_status(@locked Pa_GetDefaultInputDevice())
end

function get_default_output_device()
    handle_status(@locked Pa_GetDefaultOutputDevice())
end

function get_device_info(i)
    safe_load((@locked Pa_GetDeviceInfo(i)), BoundsError(Pa_GetDeviceInfo, i))
end

function devices()
    [
        PortAudioDevice(get_device_info(i), i) for
        i in 0:(handle_status(@locked Pa_GetDeviceCount()) - 1)
    ]
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
    pointer_ref::Ref{Ptr{PaStream}}
    warn_xruns::Bool
    recover_xruns::Bool
    sink_buffer::Buffer{T}
    source_buffer::Buffer{T}
end

const type_to_fmt = Dict{Type, PaSampleFormat}(
    Float32 => 1,
    Int32 => 2,
    # Int24 => 4,
    Int16 => 8,
    Int8 => 16,
    UInt8 => 3,
)

function make_parameters(device, channels, T, latency, host_api_specific_stream_info)
    if channels == 0
        Ptr{PaStreamParameters}(0)
    else
        Ref(
            PaStreamParameters(
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
    pointer_ref = streamPtr = Ref{Ptr{PaStream}}(0)
    handle_status(
        @locked @stderr_as_debug Pa_OpenStream(
            streamPtr,
            make_parameters(indev, inchans, eltype, latency, input_info),
            make_parameters(outdev, outchans, eltype, latency, output_info),
            float(samplerate),
            frames_per_buffer,
            flags,
            convert_nothing(callback),
            convert_nothing(user_data),
        )
    )
    handle_status(@locked Pa_StartStream(pointer_ref[]))
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
    inidx = get_default_input_device()
    outidx = get_default_output_device()
    PortAudioStream(
        PortAudioDevice(get_device_info(inidx), inidx),
        PortAudioDevice(get_device_info(outidx), outidx),
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
        handle_status(@locked Pa_StopStream(pointer))
        handle_status(@locked Pa_CloseStream(pointer))
        pointer_ref[] = C_NULL
    end
    nothing
end

isopen(stream::PortAudioStream) = stream.pointer_ref[] != C_NULL

samplerate(stream::PortAudioStream) = stream.samplerate
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

nchannels(buffer::Buffer) = buffer.nchannels
name(buffer::Buffer) = name(buffer.device)

nchannels(s::PortAudioSource) = nchannels(s.stream.source_buffer)
nchannels(s::PortAudioSink) = nchannels(s.stream.sink_buffer)
samplerate(s::Union{PortAudioSink, PortAudioSource}) = samplerate(s.stream)
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
    if recover_xruns && is_xrun(error_code)
        recover_xrun(stream)
    end
end

function write_stream(stream::Ptr{PaStream}, buf::Array, frames::Integer; warn_xruns = true)
    handle_status(
        disable_sigint() do
            @tcall @locked Pa_WriteStream(stream, buf, frames)
        end,
        warn_xruns = warn_xruns,
    )
end

function unsafe_write(sink::PortAudioSink, buf::Array, frameoffset, framecount)
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
            write_stream(pointer, chunkbuf, n, warn_xruns = warn_xruns),
            recover_xruns,
        )
        nwritten += n
    end

    nwritten
end

function read_stream(stream::Ptr{PaStream}, buf::Array, frames::Integer; warn_xruns = true)
    # without disable_sigint I get a segfault with the error:
    # "error thrown and no exception handler available."
    # if the user tries to ctrl-C. Note I've still had some crash problems with
    # ctrl-C within `pasuspend`, so for now I think either don't use `pasuspend` or
    # don't use ctrl-C.
    handle_status(
        disable_sigint() do
            @tcall @locked Pa_ReadStream(stream, buf, frames)
        end,
        warn_xruns = warn_xruns,
    )
end

function unsafe_read!(source::PortAudioSource, buf::Array, frameoffset, framecount)
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
            read_stream(pointer, chunkbuf, n, warn_xruns = warn_xruns),
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
        towrite = handle_status(@locked Pa_GetStreamWriteAvailable(pointer))
        while towrite > 0
            n = min(towrite, CHUNKFRAMES)
            fill!(chunkbuf, zero(eltype(chunkbuf)))
            write_stream(pointer, chunkbuf, n, warn_xruns = false)
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
    toread = handle_status(@locked Pa_GetStreamReadAvailable(pointer))
    while toread > 0
        n = min(toread, CHUNKFRAMES)
        read_stream(pointer, chunkbuf, n, warn_xruns = false)
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
    @stderr_as_debug handle_status(initialize())

    atexit() do
        handle_status(@locked terminate())
    end
end

end # module PortAudio
