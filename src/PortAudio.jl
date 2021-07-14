module PortAudio

using alsa_plugins_jll: alsa_plugins_jll
import Base:
    close,
    eltype,
    getindex,
    getproperty,
    IteratorSize,
    isopen,
    iterate,
    length,
    read,
    read!,
    show,
    showerror,
    write
using Base.Iterators: flatten, repeated
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

# for structs and strings
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
    if !isempty(debug_message)
        @debug debug_message
    end
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
    throw(ArgumentError("Could not find alsa.conf in $folders"))
end

function __init__()
    if Sys.islinux()
        config_folder = "ALSA_CONFIG_DIR"
        if config_folder ∉ keys(ENV)
            ENV[config_folder] =
                seek_alsa_conf(("/usr/share/alsa", "/usr/local/share/alsa", "/etc/alsa"))
        end
        # the plugin folder will contain plugins for, critically, PulseAudio
        plugin_folder = "ALSA_PLUGIN_DIR"
        if plugin_folder ∉ keys(ENV) && alsa_plugins_jll.is_available()
            ENV[plugin_folder] = joinpath(alsa_plugins_jll.artifact_dir, "lib", "alsa-lib")
        end
    end
    initialize()
    atexit(() -> terminate())
end

function versioninfo(io::IO = stdout)
    println(io, unsafe_string(Pa_GetVersionText()))
    println(io, "Version: ", Pa_GetVersion())
end

# bounds for when a device is used as an input or output
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
# show name and input and output bounds
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
function get_device(index::Integer)
    PortAudioDevice(safe_key(Pa_GetDeviceInfo, index), index)
end

function get_device(device_name::AbstractString)
    for device in devices()
        potential_match = name(device)
        if potential_match == device_name
            return device
        end
    end
    throw(KeyError(device_name))
end

function devices()
    # need to use 0 indexing for C
    map(get_device, 0:(handle_status(Pa_GetDeviceCount()) - 1))
end

# we can handle reading and writing from buffers in a similar way
function read_or_write(a_function, buffer, use_frames)
    handle_status(
        # because we're calling Pa_ReadStream and Pa_WriteStream from separate threads,
        # we put a lock around these calls
        lock(
            let a_function = a_function,
                pointer_to = buffer.pointer_to,
                data = buffer.data,
                use_frames = use_frames

                () -> a_function(pointer_to, data, use_frames)
            end,
            buffer.stream_lock,
        ),
        warn_xruns = buffer.warn_xruns,
    )
end

function write_buffer(buffer, use_frames)
    read_or_write(Pa_WriteStream, buffer, use_frames)
end

function read_buffer(buffer, use_frames)
    read_or_write(Pa_ReadStream, buffer, use_frames)
end

# these will do the actual reading and writing
# you can switch out the SampledSignalsReader/Writer defaults if you want more direct access
# a Scribe must implement the following interface:
# must have get_input_type and get_output_type methods
# must overload call for 2 arguments:
# 1) the buffer
# 2) a tuple of custom input_channel
# and return the output type
# this call method can make use of read_buffer/write_buffer methods above
abstract type Scribe end

struct SampledSignalsReader{Sample} <: Scribe end

struct SampledSignalsWriter{Sample} <: Scribe end

# define on types
# throw an error if not defined
function get_input_type(a_type::Type)
    throw(MethodError(get_input_type, (a_type,)))
end
function get_output_type(a_type::Type)
    throw(MethodError(get_output_type, (a_type,)))
end

# convenience functions so you can pass objects too
function get_input_type(::Thing) where {Thing}
    get_input_type(Thing)
end

function get_output_type(::Thing) where {Thing}
    get_output_type(Thing)
end

# SampledSignals input_channel will be a triple of the last 3 arguments to unsafe_read/write
# we will already have access to the stream itself
function get_input_type(
    ::Type{<:Union{<:SampledSignalsReader{Sample}, <:SampledSignalsWriter{Sample}}},
) where {Sample}
    Tuple{Array{Sample, 2}, Int, Int}
end

# output is the number of frames read/written
function get_output_type(::Type{<:Union{SampledSignalsReader, SampledSignalsWriter}})
    Int
end

# the julia buffer is bigger than the port audio buffer
# so we need to split it up into chunks
# we do this the same way for both reading and writing
function split_up(
    buffer,
    julia_buffer,
    already,
    frame_count,
    whole_function,
    partial_function,
)
    frames_per_buffer = buffer.frames_per_buffer
    # when we're done, we'll have written this many frames
    goal = already + frame_count
    # this is what we'll have left after doing all complete chunks
    left = frame_count % frames_per_buffer
    # this is how many we'll have written after doing all complete chunks
    even = goal - left
    foreach(
        let whole_function = whole_function,
            buffer = buffer,
            julia_buffer = julia_buffer,
            frames_per_buffer = frames_per_buffer

            already -> whole_function(
                buffer,
                julia_buffer,
                (already + 1):(already + frames_per_buffer),
                frames_per_buffer,
            )
        end,
        # start at the already, keep going until there is less than a chunk left
        already:frames_per_buffer:(even - frames_per_buffer),
        # each time we loop, add chunk frames to already
        # after the last loop, we'll reach "even"
    )
    # now we just have to read/write what's left
    if left > 0
        partial_function(buffer, julia_buffer, (even + 1):goal, left)
    end
    frame_count
end

# the full version doesn't have to make a view, but the partial version does
function full_write!(buffer, julia_buffer, julia_range, frames)
    @inbounds transpose!(buffer.data, view(julia_buffer, julia_range, :))
    write_buffer(buffer, frames)
end

function partial_write!(buffer, julia_buffer, julia_range, frames)
    @inbounds transpose!(view(buffer.data, :, 1:frames), view(julia_buffer, julia_range, :))
    write_buffer(buffer, frames)
end

function (writer::SampledSignalsWriter)(buffer, arguments)
    split_up(buffer, arguments..., full_write!, partial_write!)
end

# similar to above
function full_read!(buffer, julia_buffer, julia_range, frames_per_buffer)
    read_buffer(buffer, frames_per_buffer)
    @inbounds transpose!(view(julia_buffer, julia_range, :), buffer.data)
end

function partial_read!(buffer, julia_buffer, end_range, left)
    read_buffer(buffer, left)
    @inbounds transpose!(view(julia_buffer, end_range, :), view(buffer.data, :, 1:left))
end

function (reader::SampledSignalsReader)(buffer, arguments)
    split_up(buffer, arguments..., full_read!, partial_read!)
end

# a buffer is contains just what we need to do reading/writing
struct Buffer{Sample}
    stream_lock::ReentrantLock
    pointer_to::Ptr{PaStream}
    data::Array{Sample}
    number_of_channels::Int
    frames_per_buffer::Int
    warn_xruns::Bool
end

function Buffer(
    stream_lock,
    pointer_to,
    number_of_channels;
    Sample = Float32,
    frames_per_buffer = 128,
    warn_xruns = true,
)
    Buffer{Sample}(
        stream_lock,
        pointer_to,
        zeros(Sample, number_of_channels, frames_per_buffer),
        number_of_channels,
        frames_per_buffer,
        warn_xruns,
    )
end

eltype(::Type{Buffer{Sample}}) where {Sample} = Sample
nchannels(buffer::Buffer) = buffer.number_of_channels

# the messanger will send tasks to the scribe
# the scribe will read/write from the buffer
struct Messanger{Sample, Scribe, Input, Output}
    device_name::String
    buffer::Buffer{Sample}
    scribe::Scribe
    input_channel::Channel{Input}
    output_channel::Channel{Output}
end

eltype(::Type{Messanger{Sample}}) where {Sample} = Sample
name(messanger::Messanger) = messanger.device_name
nchannels(messanger::Messanger) = nchannels(messanger.buffer)

# the scribe will be running on a separate thread in the background
# alternating transposing and
# waiting to pass inputs and outputs back and forth to PortAudio
function send(messanger)
    buffer = messanger.buffer
    scribe = messanger.scribe
    input_channel = messanger.input_channel
    output_channel = messanger.output_channel
    while true
        input = try
            take!(input_channel)
        catch an_error
            # if the input channel is closed, the scribe knows its done
            if an_error isa InvalidStateException && an_error.state === :closed
                break
            else
                rethrow(an_error)
            end
        end
        put!(output_channel, scribe(buffer, input))
    end
end

# convenience method
has_channels(something) = nchannels(something) > 0

# create the messanger, and start the scribe on a separate task
function messanger_task(
    device_name,
    buffer::Buffer{Sample},
    scribe::Scribe,
    debug_io,
) where {Sample, Scribe}
    Input = get_input_type(Scribe)
    Output = get_output_type(Scribe)
    input_channel = Channel{Input}(0)
    output_channel = Channel{Output}(0)
    # unbuffered channels so putting and taking will block till everyone's ready
    messanger = Messanger{Sample, Scribe, Input, Output}(
        device_name,
        buffer,
        scribe,
        input_channel,
        output_channel,
    )
    # we will spawn new threads to read from and write to port audio
    # while the reading thread is talking to PortAudio, the writing thread can be setting up, and vice versa
    # start the scribe thread when its created
    # if there's channels at all
    # we can't make the task a field of the buffer, because the task uses the buffer
    task = Task(let messanger = messanger, debug_io = debug_io
        # xruns will return an error code and send a duplicate warning to stderr
        # since we handle the error codes, we don't need the duplicate warnings
        # so we send them to a debug log
        () -> redirect_stderr(let messanger = messanger
            () -> send(messanger)
        end, debug_io)
    end)
    # makes it able to run on a separate thread
    task.sticky = false
    if has_channels(buffer)
        schedule(task)
        # output channel will close when the task ends
        bind(output_channel, task)
    else
        close(input_channel)
        close(output_channel)
    end
    messanger, task
end

function close_messanger_task(messanger, task)
    if has_channels(messanger)
        # this will shut down the channels, which will shut down the thread
        close(messanger.input_channel)
        # wait for tasks to finish to make sure any errors get caught
        wait(task)
        # output channel will close because it is bound to the task
    end
end

#
# PortAudioStream
#

struct PortAudioStream{SinkMessanger, SourceMessanger}
    sample_rate::Float64
    # pointer to the c object
    pointer_to::Ptr{PaStream}
    sink_messanger::SinkMessanger
    sink_task::Task
    source_messanger::SourceMessanger
    source_task::Task
    debug_file::String
    debug_io::IOStream
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

function make_parameters(
    device,
    channels,
    latency;
    Sample = Float32,
    host_api_specific_stream_info = C_NULL,
)
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
                host_api_specific_stream_info,
            ),
        )
    end
end

# if users passes max as the number of channels, we fill it in for them
# this is currently undocumented
function fill_max_channels(kind, device, bounds, channels; adjust_channels = false)
    max_channels = bounds.max_channels
    if channels === max
        max_channels
    elseif channels > max_channels
        if adjust_channels
            max_channels
        else
            throw(
                DomainError(
                    channels,
                    "$channels exceeds max $kind channels for $(name(device))",
                ),
            )
        end
    else
        channels
    end
end

# we can only have one sample rate
# so if the default sample rates differ, throw an error
function combine_default_sample_rates(
    input_device,
    input_sample_rate,
    output_device,
    output_sample_rate,
)
    if input_sample_rate != output_sample_rate
        throw(
            ArgumentError(
                """
Default sample rate $input_sample_rate for input $(name(input_device)) disagrees with
default sample rate $output_sample_rate for output $(name(output_device)).
Please specify a sample rate.
""",
            ),
        )
    end
    input_sample_rate
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
  - `samplerate`: Sample rate (defaults to device sample rate)
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
    # for several keywords, nothing means we will fill them with defaults
    samplerate = nothing,
    latency = nothing,
    warn_xruns = true,
    # these defaults are currently undocumented
    # data is passed to and from portaudio in chunks with this many frames
    frames_per_buffer = 128,
    flags = paNoFlag,
    call_back = C_NULL,
    user_data = C_NULL,
    input_info = C_NULL,
    output_info = C_NULL,
    stream_lock = ReentrantLock(),
    # this is where you can insert custom readers or writers instead
    writer = SampledSignalsWriter{Sample}(),
    reader = SampledSignalsReader{Sample}(),
    adjust_channels = false,
)
    debug_file, debug_io = mktemp()
    input_channels_filled = fill_max_channels(
        "input",
        input_device,
        input_device.input_bounds,
        input_channels;
        adjust_channels = adjust_channels,
    )
    output_channels_filled = fill_max_channels(
        "output",
        output_device,
        output_device.output_bounds,
        output_channels;
        adjust_channels = adjust_channels,
    )
    # which defaults we use will depend on whether input or output have any channels
    if input_channels_filled > 0
        if output_channels_filled > 0
            if latency === nothing
                # use the max of high latency for input and output
                latency = max(
                    input_device.input_bounds.high_latency,
                    output_device.output_bounds.high_latency,
                )
            end
            if samplerate === nothing
                samplerate = combine_default_sample_rates(
                    input_device,
                    input_device.default_sample_rate,
                    output_device,
                    output_device.default_sample_rate,
                )
            end
        else
            if latency === nothing
                latency = input_device.input_bounds.high_latency
            end
            if samplerate === nothing
                samplerate = input_device.default_sample_rate
            end
        end
    else
        if output_channels_filled > 0
            if latency === nothing
                latency = output_device.output_bounds.high_latency
            end
            if samplerate === nothing
                samplerate = output_device.default_sample_rate
            end
        else
            throw(ArgumentError("Input or output must have at least 1 channel"))
        end
    end
    # we need a mutable pointer so portaudio can set it for us
    mutable_pointer = Ref{Ptr{PaStream}}(0)
    handle_status(
        Pa_OpenStream(
            mutable_pointer,
            make_parameters(
                input_device,
                input_channels_filled,
                latency;
                host_api_specific_stream_info = input_info,
            ),
            make_parameters(
                output_device,
                output_channels_filled,
                latency;
                Sample = Sample,
                host_api_specific_stream_info = output_info,
            ),
            samplerate,
            frames_per_buffer,
            flags,
            call_back,
            user_data,
        ),
    )
    pointer_to = mutable_pointer[]
    handle_status(Pa_StartStream(pointer_to))
    PortAudioStream(
        samplerate,
        pointer_to,
        # we need to keep track of the tasks
        # so we can wait for them to finish and catch errors
        messanger_task(
            output_device.name,
            Buffer(
                stream_lock,
                pointer_to,
                output_channels_filled;
                Sample = Sample,
                frames_per_buffer = frames_per_buffer,
                warn_xruns = warn_xruns,
            ),
            writer,
            debug_io,
        )...,
        messanger_task(
            input_device.name,
            Buffer(
                stream_lock,
                pointer_to,
                input_channels_filled;
                Sample = Sample,
                frames_per_buffer = frames_per_buffer,
                warn_xruns = warn_xruns,
            ),
            reader,
            debug_io,
        )...,
        debug_file,
        debug_io,
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
        get_device(in_device_name),
        get_device(out_device_name),
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
        get_device(in_index),
        get_device(out_index),
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
    # closing is tricky, because we want to make sure we've read exactly as much as we've written
    # but we have don't know exactly what the tasks are doing
    # for now, just close one and then the other
    close_messanger_task(stream.source_messanger, stream.source_task)
    close_messanger_task(stream.sink_messanger, stream.sink_task)
    pointer_to = stream.pointer_to
    # only stop if it's not already stopped
    if !Bool(handle_status(Pa_IsStreamStopped(pointer_to)))
        handle_status(Pa_StopStream(pointer_to))
    end
    handle_status(Pa_CloseStream(pointer_to))
    # close the debug log and then read the file
    # this will contain duplicate xrun warnings mentioned above
    close(stream.debug_io)
    debug_log = open(io -> read(io, String), stream.debug_file, "r")
    if !isempty(debug_log)
        @debug debug_log
    end
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
function eltype(
    ::Type{<:PortAudioStream{<:Messanger{Sample}, <:Messanger{Sample}}},
) where {Sample}
    Sample
end

# these defaults will error for non-sampledsignal scribes
# which is probably ok; we want these users to define new methods
read(stream::PortAudioStream, arguments...) = read(stream.source, arguments...)
read!(stream::PortAudioStream, arguments...) = read!(stream.source, arguments...)
write(stream::PortAudioStream, arguments...) = write(stream.sink, arguments...)
function write(sink::PortAudioStream, source::PortAudioStream, arguments...)
    write(sink.sink, source.source, arguments...)
end

function show(io::IO, stream::PortAudioStream)
    # just show the first type parameter (eltype)
    print(io, "PortAudioStream{")
    print(io, eltype(stream))
    println(io, "}")
    print(io, "  Samplerate: ", samplerate(stream), "Hz")
    # show source or sink if there's any channels
    sink = stream.sink
    if has_channels(sink)
        print(io, "\n  ")
        show(io, sink)
    end
    source = stream.source
    if has_channels(source)
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
    @eval struct $TypeName{InputMessanger, OutputMessanger} <: $Super
        stream::PortAudioStream{InputMessanger, OutputMessanger}
    end
end

# provided for backwards compatibility
# only defined for SampledSignals scribes
function getproperty(
    stream::PortAudioStream{
        <:Messanger{<:Any, <:SampledSignalsWriter},
        <:Messanger{<:Any, <:SampledSignalsReader},
    },
    property::Symbol,
)
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
function nchannels(source_or_sink::PortAudioSink)
    nchannels(source_or_sink.stream.sink_messanger)
end
function samplerate(source_or_sink::Union{PortAudioSink, PortAudioSource})
    samplerate(source_or_sink.stream)
end
function eltype(
    ::Type{
        <:Union{
            <:PortAudioSink{<:Messanger{Sample}, <:Messanger{Sample}},
            <:PortAudioSource{<:Messanger{Sample}, <:Messanger{Sample}},
        },
    },
) where {Sample}
    Sample
end
function isopen(source_or_sink::Union{PortAudioSink, PortAudioSource})
    isopen(source_or_sink.stream)
end
name(source_or_sink::PortAudioSink) = name(source_or_sink.stream.sink_messanger)
name(source_or_sink::PortAudioSource) = name(source_or_sink.stream.source_messanger)

# could show full type name, but the PortAudio part is probably redundant
# because these will usually only get printed as part of show for PortAudioStream
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
# so we just need to pass input_channel in and take output_channel out
# SampledSignals can take care of this feeding for us
function exchange(messanger, arguments...)
    put!(messanger.input_channel, arguments)
    take!(messanger.output_channel)
end

# these will only work with sampledsignals scribes
function unsafe_write(
    sink::PortAudioSink{<:Messanger{<:Any, <:SampledSignalsWriter}},
    julia_buffer::Array,
    already,
    frame_count,
)
    exchange(sink.stream.sink_messanger, julia_buffer, already, frame_count)
end

function unsafe_read!(
    source::PortAudioSource{<:Any, <:Messanger{<:Any, <:SampledSignalsReader}},
    julia_buffer::Array,
    already,
    frame_count,
)
    exchange(source.stream.source_messanger, julia_buffer, already, frame_count)
end

end # module PortAudio
