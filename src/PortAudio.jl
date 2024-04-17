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

export devices, PortAudioStream

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
    paNoDevice,
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

# for structs and strings, PortAudio will return C_NULL instead of erroring
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
    log = @capture_err handle_status(Pa_Initialize())
    if !isempty(log)
        @debug log
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
function show(io::IO, device::PortAudioDevice)
    print(io, repr(name(device)))
    print(io, ' ')
    print(io, device.input_bounds.max_channels)
    print(io, '→')
    print(io, device.output_bounds.max_channels)
end

function check_device_exists(device_index, device_type)
    if device_index == paNoDevice
        throw(ArgumentError("No $device_type device available"))
    end
end

function get_default_input_index()
    device_index = Pa_GetDefaultInputDevice()
    check_device_exists(device_index, "input")
    device_index
end

function get_default_output_index()
    device_index = Pa_GetDefaultOutputDevice()
    check_device_exists(device_index, "output")
    device_index
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

"""
    devices()

List the devices available on your system.
Devices will be shown with their internal name, and maximum input and output channels.
"""
function devices()
    # need to use 0 indexing for C
    map(get_device, 0:(handle_status(Pa_GetDeviceCount()) - 1))
end

# we can handle reading and writing from buffers in a similar way
function read_or_write(a_function, buffer, use_frames = buffer.frames_per_buffer; acquire_lock = true)
    pointer_to = buffer.pointer_to
    data = buffer.data
    handle_status(
        if acquire_lock 
            # because we're calling Pa_ReadStream and Pa_WriteStream from separate threads,
            # we put a lock around these calls
            lock(
                let a_function = a_function,
                    pointer_to = pointer_to,
                    data = data,
                    use_frames = use_frames
                    () -> a_function(pointer_to, data, use_frames)
                end,
                buffer.stream_lock,
            )
        else
            a_function(pointer_to, data, use_frames)
        end;
        warn_xruns = buffer.warn_xruns,
    )
end

"""
    abstract type PortAudio.Scribe end

A scribe must implement the following:

  - A method for [`PortAudio.get_input_type`](@ref)
  - A method for [`PortAudio.get_output_type`](@ref)
  - A method to call itself on two arguments: a [`PortAudio.Buffer`](@ref) and an input of the input type.
    This method must return an output of the output type.
    This method should make use of [`PortAudio.read_buffer!`](@ref) and [`PortAudio.write_buffer`](@ref).
"""
abstract type Scribe end

abstract type SampledSignalsScribe <: Scribe end

"""
    struct PortAudio.SampledSignalsReader

A [`PortAudio.Scribe`](@ref) that will use the `SampledSignals` package to manage reading data from PortAudio.
"""
struct SampledSignalsReader <: SampledSignalsScribe end

"""
    struct PortAudio.SampledSignalsReader

A [`PortAudio.Scribe`](@ref) that will use the `SampledSignals` package to manage writing data to PortAudio.
"""
struct SampledSignalsWriter <: SampledSignalsScribe end

"""
    PortAudio.get_input_type(scribe::PortAudio.Scribe, Sample)

Get the input type of a [`PortAudio.Scribe`](@ref) for samples of type `Sample`.
"""
function get_input_type(::SampledSignalsScribe, Sample)
    # SampledSignals input_channel will be a triple of the last 3 arguments to unsafe_read/write
    # we will already have access to the stream itself
    Tuple{Array{Sample, 2}, Int, Int}
end

"""
    PortAudio.get_input_type(scribe::PortAudio.Scribe, Sample)

Get the output type of a [`PortAudio.Scribe`](@ref) for samples of type `Sample`.
"""
function get_output_type(::SampledSignalsScribe, Sample)
    # output is the number of frames read/written
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
                frames_per_buffer,
                julia_buffer,
                (already + 1):(already + frames_per_buffer)
            )
        end,
        # start at the already, keep going until there is less than a chunk left
        already:frames_per_buffer:(even - frames_per_buffer),
        # each time we loop, add chunk frames to already
        # after the last loop, we'll reach "even"
    )
    # now we just have to read/write what's left
    if left > 0
        partial_function(buffer, left, julia_buffer, (even + 1):goal)
    end
    frame_count
end

# the full version doesn't have to make a view, but the partial version does
function full_write!(buffer, count, julia_buffer, julia_range)
    @inbounds transpose!(buffer.data, view(julia_buffer, julia_range, :))
    write_buffer(buffer, count)
end

function partial_write!(buffer, count, julia_buffer, julia_range)
    @inbounds transpose!(view(buffer.data, :, 1:count), view(julia_buffer, julia_range, :))
    write_buffer(buffer, count)
end

function (writer::SampledSignalsWriter)(buffer, arguments)
    split_up(buffer, arguments..., full_write!, partial_write!)
end

# similar to above
function full_read!(buffer, count, julia_buffer, julia_range)
    read_buffer!(buffer, count)
    @inbounds transpose!(view(julia_buffer, julia_range, :), buffer.data)
end

function partial_read!(buffer, count, julia_buffer, julia_range)
    read_buffer!(buffer, count)
    @inbounds transpose!(view(julia_buffer, julia_range, :), view(buffer.data, :, 1:count))
end

function (reader::SampledSignalsReader)(buffer, arguments)
    split_up(buffer, arguments..., full_read!, partial_read!)
end

"""
    struct PortAudio.Buffer{Sample}

A `PortAudio.Buffer` contains everything you might need to read or write data from or to PortAudio.
The `data` field contains the raw data in the buffer.
Use [`PortAudio.write_buffer`](@ref) to write data to PortAudio, and [`PortAudio.read_buffer!`](@ref) to read data from PortAudio.
"""
struct Buffer{Sample}
    stream_lock::ReentrantLock
    pointer_to::Ptr{PaStream}
    data::Array{Sample, 2}
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

"""
    PortAudio.write_buffer(buffer, use_frames = buffer.frames_per_buffer; acquire_lock = true)

Write a number of frames (`use_frames`) from a [`PortAudio.Buffer`](@ref) to PortAudio.

Set `acquire_lock = false` to skip acquiring the lock.
"""
function write_buffer(buffer::Buffer, use_frames = buffer.frames_per_buffer; acquire_lock = true)
    read_or_write(Pa_WriteStream, buffer, use_frames; acquire_lock = acquire_lock)
end

"""
    PortAudio.read_buffer!(buffer::Buffer, use_frames = buffer.frames_per_buffer; acquire_lock = true)

Read a number of frames (`use_frames`) from PortAudio to a [`PortAudio.Buffer`](@ref).

Set `acquire_lock = false` to skip acquiring the acquire_lock.
"""
function read_buffer!(buffer, use_frames = buffer.frames_per_buffer; acquire_lock = true)
    read_or_write(Pa_ReadStream, buffer, use_frames; acquire_lock = acquire_lock)
end

"""
    Messenger{Sample, Scribe, Input, Output}

A `struct` with entries
* `device_name::String`
* `buffer::Buffer{Sample}`
* `scribe::Scribe`
* `input_channel::Channel{Input}`
* `output_channel::Channel{Output}`
The messenger will send tasks to the scribe;
the scribe will read/write from the buffer.
"""
struct Messenger{Sample, Scribe, Input, Output}
    device_name::String
    buffer::Buffer{Sample}
    scribe::Scribe
    input_channel::Channel{Input}
    output_channel::Channel{Output}
end

eltype(::Type{Messenger{Sample}}) where {Sample} = Sample
name(messenger::Messenger) = messenger.device_name
nchannels(messenger::Messenger) = nchannels(messenger.buffer)

# the scribe will be running on a separate thread in the background
# alternating transposing and
# waiting to pass inputs and outputs back and forth to PortAudio
function send(messenger)
    buffer = messenger.buffer
    scribe = messenger.scribe
    input_channel = messenger.input_channel
    output_channel = messenger.output_channel
    for input in input_channel
        put!(output_channel, scribe(buffer, input))
    end
end

# convenience method
has_channels(something) = nchannels(something) > 0

# create the messenger, and start the scribe on a separate task
function messenger_task(
    device_name,
    buffer::Buffer{Sample},
    scribe::Scribe
) where {Sample, Scribe}
    Input = get_input_type(scribe, Sample)
    Output = get_output_type(scribe, Sample)
    input_channel = Channel{Input}(0)
    output_channel = Channel{Output}(0)
    # unbuffered channels so putting and taking will block till everyone's ready
    messenger = Messenger{Sample, Scribe, Input, Output}(
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
    task = Task(let messenger = messenger
        # xruns will return an error code and send a duplicate warning to stderr
        # since we handle the error codes, we don't need the duplicate warnings
        # so we could send them to a debug log
        # but that causes problems when done from multiple threads
        () -> send(messenger)
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
    messenger, task
end

function fetch_messenger(messenger, task)
    if has_channels(messenger)
        # this will shut down the channels, which will shut down the thread
        close(messenger.input_channel)
        # wait for tasks to finish to make sure any errors get caught
        wait(task)
        # output channel will close because it is bound to the task
    else
        ""
    end
end

#
# PortAudioStream
#

struct PortAudioStream{SinkMessenger, SourceMessenger}
    sample_rate::Float64
    # pointer to the c object
    pointer_to::Ptr{PaStream}
    sink_messenger::SinkMessenger
    sink_task::Task
    source_messenger::SourceMessenger
    source_task::Task
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

function fill_max_channels(kind, device, bounds, channels; adjust_channels = false)
    max_channels = bounds.max_channels
    if channels === maximum
        max_channels
    elseif channels > max_channels
        if adjust_channels
            max_channels
        else
            throw(
                DomainError(
                    channels,
                    "$channels exceeds maximum $kind channels for $(name(device))",
                ),
            )
        end
    else
        channels
    end
end

function combine_default_sample_rates(
    input_device,
    input_sample_rate,
    output_device,
    output_sample_rate,
)
    if input_sample_rate != output_sample_rate
        throw(
            ArgumentError("""
Default sample rate $input_sample_rate for input \"$(name(input_device))\" disagrees with
default sample rate $output_sample_rate for output \"$(name(output_device))\".
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

Audio devices can either be `PortAudioDevice` instances as returned by [`devices`](@ref), or strings with the device name as reported by the operating system.
Set `input_channels` to `0` for an output only stream; set `output_channels` to `0` for an input only steam.
If you pass the function `maximum` instead of a number of channels, use the maximum channels allowed by the corresponding device.
If a single `duplex_device` is given, it will be used for both input and output.
If no devices are given, the system default devices will be used.

The `PortAudioStream` type supports all the stream and buffer features defined [SampledSignals.jl](https://github.com/JuliaAudio/SampledSignals.jl) by default.
For example, if you load SampledSignals with `using SampledSignals` you can read 5 seconds to a buffer with `buf = read(stream, 5s)`, regardless of the sample rate of the device.
`write(stream, stream)` will set up a loopback that will read from the input and play it back on the output.

Options:

  - `adjust_channels = false`: If set to `true`, if either `input_channels` or `output_channels` exceeds the corresponding device maximum, adjust down to the maximum.
  - `call_back = C_NULL`: The PortAudio call-back function.
    Currently, passing anything except `C_NULL` is unsupported.
  - `eltype = Float32`: Sample type of the audio stream
  - `flags = PortAudio.paNoFlag`: PortAudio flags
  - `frames_per_buffer = 128`: the number of frames per buffer
  - `input_info = C_NULL`: host API specific stream info for the input device.
    Currently, passing anything except `C_NULL` is unsupported.
  - `latency = nothing`: Requested latency. Stream could underrun when too low, consider using the defaults.  If left as `nothing`, use the defaults below:
    - For input/output only streams, use the corresponding device's default high latency.
    - For duplex streams, use the max of the default high latency of the input and output devices.
  - `output_info = C_NULL`: host API specific stream info for the output device.
    Currently, passing anything except `C_NULL` is unsupported.
  - `reader = PortAudio.SampledSignalsReader()`: the scribe that will read input.
    Defaults to a [`PortAudio.SampledSignalsReader`](@ref).
    Users can pass custom scribes; see [`PortAudio.Scribe`](@ref).
  - `samplerate = nothing`: Sample rate. If left as `nothing`, use the defaults below:
    - For input/output only streams, use the corresponding device's default sample rate.
    - For duplex streams, use the default sample rate if the default sample rates for the input and output devices match, otherwise throw an error.
  - `warn_xruns = true`: Display a warning if there is a stream overrun or underrun, which often happens when Julia is compiling, or with a particularly large GC run.
    Only affects duplex streams.
  - `writer = PortAudio.SampledSignalsWriter()`: the scribe that will write output.
    Defaults to a [`PortAudio.SampledSignalsReader`](@ref).
    Users can pass custom scribes; see [`PortAudio.Scribe`](@ref).

## Examples:

Set up an audio pass-through from microphone to speaker

```julia
julia> using PortAudio, SampledSignals

julia> stream = PortAudioStream(2, 2; warn_xruns = false);

julia> try
            # cancel with Ctrl-C
            write(stream, stream, 2s)
        finally
            close(stream)
        end
```

Use `do` syntax to auto-close the stream

```julia
julia> using PortAudio, SampledSignals

julia> PortAudioStream(2, 2; warn_xruns = false) do stream
            write(stream, stream, 2s)
        end
```

Open devices by name

```julia
using PortAudio, SampledSignals
PortAudioStream("Built-in Microph", "Built-in Output"; warn_xruns = false) do stream
    write(stream, stream, 2s)
end
2 s
```

Record 10 seconds of audio and save to an ogg file

```julia
julia> using PortAudio, SampledSignals, LibSndFile

julia> PortAudioStream(2, 0; warn_xruns = false) do stream
            buf = read(stream, 10s)
            save(joinpath(tempname(), ".ogg"), buf)
        end
2 s
```
"""
function PortAudioStream(
    input_device::PortAudioDevice,
    output_device::PortAudioDevice,
    input_channels = 2,
    output_channels = 2;
    eltype = Float32,
    adjust_channels = false,
    call_back = C_NULL,
    flags = paNoFlag,
    frames_per_buffer = 128,
    input_info = C_NULL,
    latency = nothing,
    output_info = C_NULL,
    reader = SampledSignalsReader(),
    samplerate = nothing,
    stream_lock = ReentrantLock(),
    user_data = C_NULL,
    warn_xruns = true,
    writer = SampledSignalsWriter(),   
)
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
    if input_channels_filled > 0
        if output_channels_filled > 0
            if latency === nothing
                latency = max(
                    input_device.input_bounds.high_latency,
                    output_device.output_bounds.high_latency,
                )
            end
            samplerate = if samplerate === nothing
                combine_default_sample_rates(
                    input_device,
                    input_device.default_sample_rate,
                    output_device,
                    output_device.default_sample_rate,
                )
            else
                float(samplerate)
            end
        else
            if latency === nothing
                latency = input_device.input_bounds.high_latency
            end
            samplerate = if samplerate === nothing
                input_device.default_sample_rate
            else
                float(samplerate)
            end
        end
    else
        if output_channels_filled > 0
            if latency === nothing
                latency = output_device.output_bounds.high_latency
            end
            samplerate = if samplerate === nothing
                    output_device.default_sample_rate
                else
                    float(samplerate)
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
                Sample = eltype,
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
        # we need to keep track of the tasks so we can wait for them to finish and catch errors
        messenger_task(
            output_device.name,
            Buffer(
                stream_lock,
                pointer_to,
                output_channels_filled;
                Sample = eltype,
                frames_per_buffer = frames_per_buffer,
                warn_xruns = warn_xruns,
            ),
            writer,
        )...,
        messenger_task(
            input_device.name,
            Buffer(
                stream_lock,
                pointer_to,
                input_channels_filled;
                Sample = eltype,
                frames_per_buffer = frames_per_buffer,
                warn_xruns = warn_xruns,
            ),
            reader,
        )...,
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
    fetch_messenger(stream.source_messenger, stream.source_task)
    fetch_messenger(stream.sink_messenger, stream.sink_task)
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

function eltype(
    ::Type{<:PortAudioStream{<:Messenger{Sample}, <:Messenger{Sample}}},
) where {Sample}
    Sample
end

# these defaults will error for non-SampledSignals scribes
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
    print(io, "  Samplerate: ", round(Int, samplerate(stream)), "Hz")
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
        <:Messenger{<:Any, <:SampledSignalsWriter},
        <:Messenger{<:Any, <:SampledSignalsReader},
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
    nchannels(source_or_sink.stream.source_messenger)
end
function nchannels(source_or_sink::PortAudioSink)
    nchannels(source_or_sink.stream.sink_messenger)
end
function samplerate(source_or_sink::Union{PortAudioSink, PortAudioSource})
    samplerate(source_or_sink.stream)
end
function eltype(
    ::Type{
        <:Union{
            <:PortAudioSink{<:Messenger{Sample}, <:Messenger{Sample}},
            <:PortAudioSource{<:Messenger{Sample}, <:Messenger{Sample}},
        },
    },
) where {Sample}
    Sample
end
function isopen(source_or_sink::Union{PortAudioSink, PortAudioSource})
    isopen(source_or_sink.stream)
end
name(source_or_sink::PortAudioSink) = name(source_or_sink.stream.sink_messenger)
name(source_or_sink::PortAudioSource) = name(source_or_sink.stream.source_messenger)

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
# so we just need to pass inputs in and take outputs out
# SampledSignals can take care of this feeding for us
function exchange(messenger, arguments...)
    put!(messenger.input_channel, arguments)
    take!(messenger.output_channel)
end

as_matrix(matrix::Matrix) = matrix
as_matrix(vector::Vector) = reshape(vector, length(vector), 1)

# these will only work with SampledSignals scribes
function unsafe_write(
    sink::PortAudioSink{<:Messenger{<:Any, <:SampledSignalsWriter}},
    julia_buffer::Array,
    already,
    frame_count,
)
    exchange(sink.stream.sink_messenger, as_matrix(julia_buffer), already, frame_count)
end

function unsafe_read!(
    source::PortAudioSource{<:Any, <:Messenger{<:Any, <:SampledSignalsReader}},
    julia_buffer::Array,
    already,
    frame_count,
)
    exchange(source.stream.source_messenger, as_matrix(julia_buffer), already, frame_count)
end

include("precompile.jl")

end # module PortAudio
