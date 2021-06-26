module PortAudio

using Base: alloc_buf_hook, Bool
using alsa_plugins_jll: alsa_plugins_jll
import Base: close, eltype, getproperty, isopen, read, read!, show, showerror, write
using Base.Threads: @spawn
using libportaudio_jll: libportaudio
using LinearAlgebra: transpose!
import SampledSignals: nchannels, samplerate, unsafe_read!, unsafe_write
using SampledSignals: SampleSink, SampleSource
using Suppressor: @capture_err

export PortAudioStream

include("libportaudio.jl")

using .LibPortAudio:
    paBadStreamPtr,
    Pa_CloseStream,
    PaDeviceIndex,
    PaDeviceInfo,
    PaError,
    PaErrorCode,
    Pa_GetDefaultInputDevice,
    Pa_GetDefaultOutputDevice,
    Pa_GetDeviceCount,
    Pa_GetDeviceInfo,
    Pa_GetErrorText,
    Pa_GetHostApiInfo,
    Pa_GetStreamReadAvailable,
    Pa_GetStreamWriteAvailable,
    Pa_GetVersion,
    Pa_GetVersionText,
    PaHostApiTypeId,
    Pa_Initialize,
    paInputOverflowed,
    Pa_IsStreamStopped,
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

# for structs from indexes
# PortAudio will return C_NULL instead of erroring
# so we need to handle these errors
function safe_load(result, an_error)
    if result == C_NULL
        throw(an_error)
    end
    unsafe_load(result)
end

# for functions that retrieve an index, throw a key error if it doesn't exist
function safe_key(a_function, an_index)
    safe_load(a_function(an_index), KeyError(an_index))
end

# error numbers are integers, while error codes are an @enum
function get_error_text(error_number)
    unsafe_string(Pa_GetErrorText(error_number))
end

struct PortAudioException <: Exception
    code::PaErrorCode
end
function showerror(io::IO, exception::PortAudioException)
    print(io, "PortAudioException: ")
    print(io, get_error_text(PaError(exception.code)))
end

# for integer results, PortAudio will return a negative number instead of erroring
# so we need to handle these errors
function handle_status(error_number; warn_xruns = true)
    if error_number < 0
        error_code = PaErrorCode(error_number)
        if error_code == paOutputUnderflowed || error_code == paInputOverflowed
            # warn instead of error after an xrun
            # allow users to disable these warnings
            if warn_xruns
                @warn("libportaudio: " * get_error_text(error_number))
            end
        else
            throw(PortAudioException(error_code))
        end
    end
    error_number
end

function initialize()
    # ALSA will throw extraneous warnings on start-up
    # send them to debug instead
    debug_message = @capture_err handle_status(Pa_Initialize())
    @debug debug_message
end

function terminate()
    handle_status(Pa_Terminate())
end

# alsa needs to know where the configure file is
function seek_alsa_conf(folders)
    for folder in folders
        if isfile(joinpath(folder, "alsa.conf"))
            return folder
        end
    end
    throw(ArgumentError("Could not find ALSA config"))
end

function __init__()
    if Sys.islinux()
        config_folder = "ALSA_CONFIG_DIR"
        if config_folder ∉ keys(ENV)
            ENV[config_folder] =
                seek_alsa_conf(["/usr/share/alsa", "/usr/local/share/alsa", "/etc/alsa"])
        end
        # the plugin folder will contain plugins for, critically, PulseAudio
        plugin_folder = "ALSA_PLUGIN_DIR"
        if plugin_folder ∉ keys(ENV) && alsa_plugins_jll.is_available()
            ENV[plugin_folder] = joinpath(alsa_plugins_jll.artifact_dir, "lib", "alsa-lib")
        end
    end
    initialize()
    atexit() do
        terminate()
    end
end

# data is passed to and from portaudio in chunks with this many frames
const CHUNK_FRAMES = 128

function versioninfo(io::IO = stdout)
    println(io, unsafe_string(Pa_GetVersionText()))
    println(io, "Version: ", Pa_GetVersion())
end

# bounds for when a device is used as an input, or as an output
struct Bounds
    max_channels::Int
    low_latency::Float64
    high_latency::Float64
end

struct PortAudioDevice
    name::String
    host_api::String
    default_sample_rate::Float64
    index::PaDeviceIndex
    input_bounds::Bounds
    output_bounds::Bounds
end

function PortAudioDevice(info::PaDeviceInfo, index)
    PortAudioDevice(
        unsafe_string(info.name),
        # replace host api code with its name
        unsafe_string(safe_key(Pa_GetHostApiInfo, info.hostApi).name),
        info.defaultSampleRate,
        index,
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
# show just key info about the device
function show(io::IO, device::PortAudioDevice)
    print(io, repr(name(device)))
    print(io, ' ')
    print(io, device.input_bounds.max_channels)
    print(io, '→')
    print(io, device.output_bounds.max_channels)
end

function get_default_input_index()
    handle_status(Pa_GetDefaultInputDevice())
end

function get_default_output_index()
    handle_status(Pa_GetDefaultOutputDevice())
end

# we can look up devices by index or name
function get_device_info(index::Integer)
    safe_key(Pa_GetDeviceInfo, index)
end

function get_device_info(device_name::AbstractString)
    for device in devices()
        potential_match = name(device)
        if potential_match == device_name
            return device
        end
    end
    throw(KeyError(device_name))
end

function devices()
    [
        PortAudioDevice(get_device_info(index), index) for
        # 0 indexing for C
        index in (1:handle_status(Pa_GetDeviceCount())) .- 1
    ]
end

# because we're calling Pa_ReadStream and Pa_WriteStream from separate threads,
# we put a lock around these calls
function write_stream(
    stream_lock,
    pointer_to,
    port_audio_buffer,
    chunk_frames;
    warn_xruns = true,
)
    handle_status(
        lock(stream_lock) do
            Pa_WriteStream(pointer_to, port_audio_buffer, chunk_frames)
        end,
        warn_xruns = warn_xruns,
    )
end

function read_stream(
    stream_lock,
    pointer_to,
    port_audio_buffer,
    chunk_frames;
    warn_xruns = true,
)
    handle_status(
        lock(stream_lock) do
            Pa_ReadStream(pointer_to, port_audio_buffer, chunk_frames)
        end;
        warn_xruns = warn_xruns,
    )
end

# these will do the actual reading and writing
# you can switch out the SampledSignalsReader/Writer defaults if you want more direct access
# a ReaderOrWriter must implement the following interface:
# must have a warn_xruns::Bool field 
# must have get_input_type and get_output_type methods
# must overload call for four arguments:
# 1) stream_lock: a lock around the stream
# 2) pointer_to: the pointer to the stream
# 3) port_audio_buffer: the source/sink buffer
# 4) custom inputs
# and return the output type
# this call method should make use of read_stream/write_stream methods above
abstract type ReaderOrWriter end

struct SampledSignalsReader{Sample} <: ReaderOrWriter
    warn_xruns::Bool
end
struct SampledSignalsWriter{Sample} <: ReaderOrWriter
    warn_xruns::Bool
end

# inputs will be a triple of the last 3 arguments to unsafe_read/write
# we will already have access to the stream itself
function get_input_type(
    ::Union{<:SampledSignalsReader{Sample}, <:SampledSignalsWriter{Sample}},
) where {Sample}
    Tuple{Array{Sample, 2}, Int, Int}
end
# output is the number of frames read/written
function get_output_type(::Union{SampledSignalsReader, SampledSignalsWriter})
    Int
end

# we need to transpose column-major buffer from Julia back and forth between the row-major buffer from PortAudio
function translate!(
    julia_buffer,
    port_audio_buffer,
    chunk_frames,
    offset,
    already,
    port_audio_to_julia,
)
    port_audio_range = 1:chunk_frames
    # the julia buffer is longer, so we might need to start from the middle
    julia_view = view(julia_buffer, port_audio_range .+ offset .+ already, :)
    port_audio_view = view(port_audio_buffer, :, port_audio_range)
    if port_audio_to_julia
        transpose!(julia_view, port_audio_view)
    else
        transpose!(port_audio_view, julia_view)
    end
end

function (writer::SampledSignalsWriter)(
    stream_lock,
    pointer_to,
    port_audio_buffer,
    (julia_buffer, offset, frame_count),
)
    warn_xruns = writer.warn_xruns
    already = 0
    # if we still have frames to write
    while already < frame_count
        # take either a whole chunk, or whatever is left if it's smaller
        chunk_frames = min(frame_count - already, CHUNK_FRAMES)
        # transpose, then send the data
        translate!(julia_buffer, port_audio_buffer, chunk_frames, offset, already, false)
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        write_stream(
            stream_lock,
            pointer_to,
            port_audio_buffer,
            chunk_frames;
            warn_xruns = warn_xruns,
        )
        already += chunk_frames
    end
    already
end

function (reader::SampledSignalsReader)(
    stream_lock,
    pointer_to,
    port_audio_buffer,
    (julia_buffer, offset, frame_count),
)
    warn_xruns = reader.warn_xruns
    already = 0
    # if we still have frames to write
    while already < frame_count
        # take either a whole chunk, or whatever is left if it's smaller
        chunk_frames = min(frame_count - already, CHUNK_FRAMES)
        # receive the data, then transpose
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        read_stream(
            stream_lock,
            pointer_to,
            port_audio_buffer,
            chunk_frames;
            warn_xruns = warn_xruns,
        )
        translate!(julia_buffer, port_audio_buffer, chunk_frames, offset, already, true)
        already += chunk_frames
    end
    already
end

# a Messanger contains
# the PortAudio device
# the number of channels
# an input channel, for passing inputs to the messanger
# an output channel for sending outputs from the messanger
struct Messanger{InputType, OutputType}
    device::PortAudioDevice
    number_of_channels::Int
    inputs::Channel{InputType}
    outputs::Channel{OutputType}
end

nchannels(messanger::Messanger) = messanger.number_of_channels
name(messanger::Messanger) = name(messanger.device)

function close(messanger::Messanger)
    close(messanger.inputs)
    close(messanger.outputs)
end

#
# PortAudioStream
#

struct PortAudioStream{Sample, SinkMessanger, SourceMessanger}
    sample_rate::Float64
    # pointer to the c object
    pointer_to::Ptr{PaStream}
    sink_messanger::SinkMessanger
    source_messanger::SourceMessanger
end

function PortAudioStream{Sample}(
    sample_rate::Float64,
    pointer_to::Ptr{PaStream},
    sink_messanger::SinkMessanger,
    source_messanger::SourceMessanger,
) where {Sample, SinkMessanger, SourceMessanger}
    PortAudioStream{Sample, SinkMessanger, SourceMessanger}(
        sample_rate,
        pointer_to,
        sink_messanger,
        source_messanger,
    )
end

# portaudio uses codes instead of types for the sample format
const TYPE_TO_FORMAT = Dict{Type, PaSampleFormat}(
    Float32 => 1,
    Int32 => 2,
    # Int24 => 4,
    Int16 => 8,
    Int8 => 16,
    UInt8 => 3,
)

# we need to convert nothing so it will be handled by C correctly
nothing_to_c_null(::Nothing) = C_NULL
nothing_to_c_null(something) = something

function make_parameters(device, channels, Sample, latency, host_api_specific_stream_info)
    if channels == 0
        # if we don't need any channels, we don't need the source/sink at all
        C_NULL
    else
        Ref(
            PaStreamParameters(
                device.index,
                channels,
                TYPE_TO_FORMAT[Sample],
                latency,
                nothing_to_c_null(host_api_specific_stream_info),
            ),
        )
    end
end

# if users pass max as the number of channels, we fill it in for them
# this is currently undocumented
function fill_max_channels(channels, bounds)
    max_channels = bounds.max_channels
    if channels === max
        max_channels
    elseif channels > max_channels
        throw(DomainError(channels, "max channels exceeded"))
    else
        channels
    end
end

const AT_LEAST_ONE = ArgumentError("Input or output must have at least 1 channel")

# fill max for both channels based on device bounds
function fill_both_channels(input_channels, input_device, output_channels, output_device)
    input_channels_filled = fill_max_channels(input_channels, input_device.input_bounds)
    output_channels_filled = fill_max_channels(output_channels, output_device.output_bounds)
    if input_channels_filled == 0 && output_channels_filled == 0
        throw(AT_LEAST_ONE)
    else
        input_channels_filled, output_channels_filled
    end
end

# if input or output only, use the corresponding value
# otherwise, run a custom combine function
function combine_defaults(
    combine_function,
    input_channels_filled,
    output_channels_filled,
    input,
    output,
)
    if input_channels_filled > 0
        if output_channels_filled > 0
            combine_function(input, output)
        else
            input
        end
    else
        if output_channels_filled > 0
            output
        else
            # this check is probably redundant, but included for completeness
            throw(AT_LEAST_ONE)
        end
    end
end

function get_default_latency(input_channels, input_device, output_channels, output_device)
    input_channels_filled, output_channels_filled =
        fill_both_channels(input_channels, input_device, output_channels, output_device)
    combine_defaults(
        # worst case scenario: max of high latency for input and output
        max,
        input_channels_filled,
        output_channels_filled,
        input_device.input_bounds.high_latency,
        output_device.output_bounds.high_latency,
    )
end

# we can only have one sample rate
# so if the default sample rates differ, throw an error
function combine_default_sample_rates(input_sample_rate, output_sample_rate)
    if input_sample_rate != output_sample_rate
        throw(ArgumentError("Default input and output sample rates disagree"))
    end
    input_sample_rate
end

function get_default_sample_rates(
    input_channels,
    input_device,
    output_channels,
    output_device,
)
    input_channels_filled, output_channels_filled =
        fill_both_channels(input_channels, input_device, output_channels, output_device)
    combine_defaults(
        combine_default_sample_rates,
        input_channels_filled,
        output_channels_filled,
        input_device.default_sample_rate,
        output_device.default_sample_rate,
    )
end

# the messanger will be running on a separate thread in the background
# alternating transposing and
# waiting to pass inputs and outputs back and forth to PortAudio
function run_reader_or_writer(
    messanger,
    reader_or_writer,
    stream_lock,
    pointer_to,
    port_audio_buffer,
)
    inputs = messanger.inputs
    outputs = messanger.outputs
    while true
        output = if isopen(inputs)
            reader_or_writer(stream_lock, pointer_to, port_audio_buffer, take!(inputs))
        else
            # no frames can be read/written if the input channel is closed
            0
        end
        if isopen(outputs)
            put!(outputs, output)
        else
            # if the output channel has closed too, we're done
            break
        end
    end
end

# we will spawn new threads to read from and write to port audio
# while the reading thread is talking to PortAudio, the writing thread can be setting up, and vice versa
function Messanger(reader_or_writer, stream_lock, Sample, pointer_to, device, channels)
    InputType = get_input_type(reader_or_writer)
    OutputType = get_output_type(reader_or_writer)
    # unbuffered channels so putting and taking will block till everyone's ready
    port_audio_buffer = zeros(Sample, channels, CHUNK_FRAMES)
    messanger = Messanger{InputType, OutputType}(
        device,
        channels,
        Channel{InputType}(0),
        Channel{OutputType}(0),
    )
    # start the messanger thread when its created
    @spawn run_reader_or_writer(
        messanger,
        reader_or_writer,
        stream_lock,
        pointer_to,
        port_audio_buffer,
    )
    messanger
end

# this is the top-level outer constructor that all the other outer constructors end up calling
"""
    PortAudioStream(input_channels = 2, output_channels = 2; options...)
    PortAudioStream(duplex_device, input_channels = 2, output_channels = 2; options...)
    PortAudioStream(input_device, output_device, input_channels = 2, output_channels = 2; options...)

Audio devices can either be `PortAudioDevice` instances as returned
by `PortAudio.devices()`, or strings with the device name as reported by the
operating system. If a single `duplex_device` is given it will be used for both
input and output. If no devices are given the system default devices will be
used.

Options:

  - `Sample`: Sample type of the audio stream (defaults to Float32)
  - `sample_rate`: Sample rate (defaults to device sample rate)
  - `latency`: Requested latency. Stream could underrun when too low, consider
    using provided device defaults
  - `warn_xruns`: Display a warning if there is a stream overrun or underrun, which
    often happens when Julia is compiling, or with a particularly large
    GC run. This is true by default.
    Only effects duplex streams.
"""
function PortAudioStream(
    input_device::PortAudioDevice,
    output_device::PortAudioDevice,
    input_channels = 2,
    output_channels = 2;
    Sample = Float32,
    sample_rate = get_default_sample_rates(
        input_channels,
        input_device,
        output_channels,
        output_device,
    ),
    latency = get_default_latency(
        input_channels,
        input_device,
        output_channels,
        output_device,
    ),
    warn_xruns = true,
    # these defaults are currently undocumented
    frames_per_buffer = 0,
    flags = paNoFlag,
    call_back = nothing,
    user_data = nothing,
    input_info = nothing,
    output_info = nothing,
    stream_lock = ReentrantLock(),
    # this is where you can insert custom readers or writers instead
    writer = SampledSignalsWriter{Sample}(warn_xruns),
    reader = SampledSignalsReader{Sample}(warn_xruns),
)
    input_channels_filled, output_channels_filled =
        fill_both_channels(input_channels, input_device, output_channels, output_device)
    # we need a mutable pointer so portaudio can set it for us
    mutable_pointer = Ref{Ptr{PaStream}}(0)
    handle_status(
        Pa_OpenStream(
            mutable_pointer,
            make_parameters(
                input_device,
                input_channels_filled,
                Sample,
                latency,
                input_info,
            ),
            make_parameters(
                output_device,
                output_channels_filled,
                Sample,
                latency,
                output_info,
            ),
            # can't be an integer
            float(sample_rate),
            frames_per_buffer,
            flags,
            nothing_to_c_null(call_back),
            nothing_to_c_null(user_data),
        ),
    )
    pointer_to = mutable_pointer[]
    handle_status(Pa_StartStream(pointer_to))
    PortAudioStream{Sample}(
        sample_rate,
        pointer_to,
        Messanger(
            writer,
            stream_lock,
            Sample,
            pointer_to,
            output_device,
            output_channels_filled,
        ),
        Messanger(
            reader,
            stream_lock,
            Sample,
            pointer_to,
            input_device,
            input_channels_filled,
        ),
    )
end

# handle device names given as streams
function PortAudioStream(
    in_device_name::AbstractString,
    out_device_name::AbstractString,
    arguments...;
    keywords...,
)
    PortAudioStream(
        get_device_info(in_device_name),
        get_device_info(out_device_name),
        arguments...;
        keywords...,
    )
end

# if one device is given, use it for input and output
function PortAudioStream(
    device::Union{PortAudioDevice, AbstractString},
    input_channels = 2,
    output_channels = 2;
    keywords...,
)
    PortAudioStream(device, device, input_channels, output_channels; keywords...)
end

# use the default input and output devices
function PortAudioStream(input_channels = 2, output_channels = 2; keywords...)
    in_index = get_default_input_index()
    out_index = get_default_output_index()
    PortAudioStream(
        PortAudioDevice(get_device_info(in_index), in_index),
        PortAudioDevice(get_device_info(out_index), out_index),
        input_channels,
        output_channels;
        keywords...,
    )
end

# handle do-syntax
function PortAudioStream(do_function::Function, arguments...; keywords...)
    stream = PortAudioStream(arguments...; keywords...)
    try
        do_function(stream)
    finally
        close(stream)
    end
end

function close(stream::PortAudioStream)
    # this will shut down the channels, which will shut down the threads
    close(stream.sink_messanger)
    close(stream.source_messanger)
    pointer_to = stream.pointer_to
    # only stop if it's not already stopped
    if !Bool(handle_status(Pa_IsStreamStopped(pointer_to)))
        handle_status(Pa_StopStream(pointer_to))
    end
    handle_status(Pa_CloseStream(pointer_to))
end

function isopen(pointer_to::Ptr{PaStream})
    # we aren't actually interested if the stream is stopped or not
    # instead, we are looking for the error which comes from checking on a closed stream
    error_number = Pa_IsStreamStopped(pointer_to)
    if error_number >= 0
        true
    else
        PaErrorCode(error_number) != paBadStreamPtr
    end
end
isopen(stream::PortAudioStream) = isopen(stream.pointer_to)

samplerate(stream::PortAudioStream) = stream.sample_rate
eltype(::Type{<:PortAudioStream{Sample}}) where {Sample} = Sample

read(stream::PortAudioStream, arguments...) = read(stream.source, arguments...)
read!(stream::PortAudioStream, arguments...) = read!(stream.source, arguments...)
write(stream::PortAudioStream, arguments...) = write(stream.sink, arguments...)
function write(sink::PortAudioStream, source::PortAudioStream, arguments...)
    write(sink.sink, source.source, arguments...)
end

function show(io::IO, stream::PortAudioStream)
    # just show the first parameter (eltype)
    print(io, "PortAudioStream{")
    print(io, eltype(stream))
    println(io, "}")
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
# If we had multiple inheritance, then PortAudioStreams could be both a sink and source
# Since we don't, we have to make wrappers instead
for (TypeName, Super) in ((:PortAudioSink, :SampleSink), (:PortAudioSource, :SampleSource))
    @eval struct $TypeName{Sample} <: $Super
        stream::PortAudioStream{Sample}
    end
end

# provided for backwards compatibility
# we should probably deprecate at some point
# because PortAudioSink and PortAudioSource would not be compatible with custom readers/writers
function getproperty(stream::PortAudioStream, property::Symbol)
    if property === :sink
        PortAudioSink(stream)
    elseif property === :source
        PortAudioSource(stream)
    else
        getfield(stream, property)
    end
end

function nchannels(source_or_sink::PortAudioSource)
    nchannels(source_or_sink.stream.source_messanger)
end
nchannels(source_or_sink::PortAudioSink) = nchannels(source_or_sink.stream.sink_messanger)
function samplerate(source_or_sink::Union{PortAudioSink, PortAudioSource})
    samplerate(source_or_sink.stream)
end
function eltype(
    ::Type{<:Union{PortAudioSink{Sample}, PortAudioSource{Sample}}},
) where {Sample}
    Sample
end
function isopen(source_or_sink::Union{PortAudioSink, PortAudioSource})
    isopen(source_or_sink.stream)
end
name(source_or_sink::PortAudioSink) = name(source_or_sink.stream.sink_messanger)
name(source_or_sink::PortAudioSource) = name(source_or_sink.stream.source_messanger)

# could show full type name, but the PortAudio part is probably redundant
kind(::PortAudioSink) = "sink"
kind(::PortAudioSource) = "source"
function show(io::IO, sink_or_source::Union{PortAudioSink, PortAudioSource})
    print(
        io,
        nchannels(sink_or_source),
        " channel ",
        kind(sink_or_source),
        ": ",
        # put in quotes
        repr(name(sink_or_source)),
    )
end

# both reading and writing will outsource to the readers or writers
# so we just need to pass inputs in and take outputs out
# SampledSignals can take care of this feeding for us
function exchange(messanger, arguments...)
    put!(messanger.inputs, arguments)
    take!(messanger.outputs)
end

function unsafe_write(sink::PortAudioSink, julia_buffer::Array, offset, frame_count)
    exchange(sink.stream.sink_messanger, julia_buffer, offset, frame_count)
end

function unsafe_read!(source::PortAudioSource, julia_buffer::Array, offset, frame_count)
    exchange(source.stream.source_messanger, julia_buffer, offset, frame_count)
end

end # module PortAudio
