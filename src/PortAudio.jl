module PortAudio

using alsa_plugins_jll: alsa_plugins_jll
using libportaudio_jll: libportaudio
using Suppressor: @capture_err

export devices, is_stopped, PortAudioStream, start, stop

include("libportaudio.jl")

using .LibPortAudio:
    paAbort,
    Pa_CloseStream,
    paComplete,
    paContinue,
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
    Pa_GetVersion,
    Pa_GetVersionText,
    Pa_Initialize,
    paInputOverflowed,
    Pa_IsStreamStopped,
    paNoDevice,
    paNoFlag,
    Pa_OpenStream,
    paOutputUnderflowed,
    PaSampleFormat,
    Pa_StartStream,
    PaStream,
    PaStreamCallbackFlags,
    PaStreamCallbackResult,
    PaStreamCallbackTimeInfo,
    PaStreamParameters,
    Pa_Terminate

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

function Base.showerror(io::IO, exception::PortAudioException)
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
function Base.show(io::IO, device::PortAudioDevice)
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

function get_device(device::PortAudioDevice)
    device
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

struct PortAudioStream{Sample}
    sample_rate::Float64
    pointer_to::Ptr{PaStream}
    input_channels_filled::Int
    output_channels_filled::Int
    frames_per_buffer::Int
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
"""),
        )
    end
    input_sample_rate
end

function fill_one_device(device, bounds, latency, samplerate)
    return (if latency === nothing
        bounds.high_latency
    else
        latency
    end, if samplerate === nothing
        device.default_sample_rate
    else
        float(samplerate)
    end)
end

mutable struct CallbackWrapper{Sample, AFunction}
    const a_function::AFunction
    const input_channels::Int
    const output_channels::Int
    frames_already::Int
end

function CallbackWrapper{Sample}(
    a_function::AFunction,
    input_channels,
    output_channels,
    frames_already = 0,
) where {Sample, AFunction}
    CallbackWrapper{Sample, AFunction}(
        a_function,
        input_channels,
        output_channels,
        frames_already,
    )
end

Base.eltype(::Type{<:CallbackWrapper{Sample}}) where {Sample} = Sample

function unwrap_buffer_pointer(pointer, channels, frames_per_buffer)
    unsafe_wrap(Array, pointer, (channels, frames_per_buffer))
end

function inner_run_callback(
    callback_wrapper,
    input_buffer_pointer,
    output_buffer_pointer,
    frames_per_buffer,
    frames_already,
)
    callback_wrapper.a_function(
        unwrap_buffer_pointer(
            input_buffer_pointer,
            callback_wrapper.input_channels,
            frames_per_buffer,
        ),
        unwrap_buffer_pointer(
            output_buffer_pointer,
            callback_wrapper.output_channels,
            frames_per_buffer,
        ),
        frames_per_buffer,
        frames_already,
    )
end

function inner_run_callback(
    callback_wrapper,
    ::Ptr{Nothing},
    output_buffer_pointer,
    frames_per_buffer,
    frames_already,
)
    callback_wrapper.a_function(
        nothing,
        unwrap_buffer_pointer(
            output_buffer_pointer,
            callback_wrapper.output_channels,
            frames_per_buffer,
        ),
        frames_per_buffer,
        frames_already,
    )
end

function inner_run_callback(
    callback_wrapper,
    input_buffer_pointer,
    ::Ptr{Nothing},
    frames_per_buffer,
    frames_already,
)
    callback_wrapper.a_function(
        unwrap_buffer_pointer(
            input_buffer_pointer,
            callback_wrapper.input_channels,
            frames_per_buffer,
        ),
        nothing,
        frames_per_buffer,
        frames_already,
    )
end

function inner_run_callback(_, ::Ptr{Nothing}, ::Ptr{Nothing}, __, ___)
    throw(ArgumentError("Neither input nor output buffer"))
end

function run_callback(
    input_buffer_pointer,
    output_buffer_pointer,
    unsigned_frames_per_buffer,
    _, # time_info_pointer TODO: give to users?
    __, # status_flags TODO: give to users?
    callback_wrapper_pointer,
)
    try
        callback_wrapper = unsafe_pointer_to_objref(callback_wrapper_pointer)
        frames_already = callback_wrapper.frames_already
        frames_per_buffer = Int(unsigned_frames_per_buffer)
        written = inner_run_callback(
            callback_wrapper,
            input_buffer_pointer,
            output_buffer_pointer,
            frames_per_buffer,
            frames_already,
        )
        callback_wrapper.frames_already = frames_already + written
        if written < frames_per_buffer
            paComplete
        else
            paContinue
        end
    catch an_error
        @info Base.showerror(stdout, an_error, Base.catch_backtrace())
        paAbort
    end
end

function callback_cfunction(
    ::Callback,
    ::Type{Sample},
    ::Type{Input},
    ::Type{Output},
) where {Callback, Sample, Input, Output}
    @cfunction(
        run_callback,
        PaStreamCallbackResult, # returns
        (
            Ptr{Input}, # input buffer pointer
            Ptr{Output}, # output buffer pointer
            Culong, # unsigned_frames_per_buffer
            Ptr{PaStreamCallbackTimeInfo}, # time info pointer
            PaStreamCallbackFlags, # status flags
            Ptr{CallbackWrapper{Callback, Sample}}, # user data, that is, the "true callback"
        )
    )
end

function PortAudioStream(
    callback;
    input_device = get_default_input_index(),
    output_device = get_default_output_index(),
    input_channels = 2,
    output_channels = 2,
    eltype = Float32,
    adjust_channels = false,
    flags = paNoFlag,
    frames_per_buffer = 128,
    input_info = C_NULL,
    latency = nothing,
    output_info = C_NULL,
    samplerate = nothing,
)
    input_device = get_device(input_device)
    output_device = get_device(output_device)
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
            latency, samplerate = fill_one_device(
                input_device,
                input_device.input_bounds,
                latency,
                samplerate,
            )
        end
    else
        if output_channels_filled > 0
            latency, samplerate = fill_one_device(
                output_device,
                output_device.output_bounds,
                latency,
                samplerate,
            )
        else
            throw(ArgumentError("Input or output must have at least 1 channel"))
        end
    end
    # we need a mutable pointer so portaudio can set it for us
    mutable_pointer = Ref{Ptr{PaStream}}(0)
    callback_wrapper = CallbackWrapper{eltype}(callback, input_channels, output_channels)

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
            callback_cfunction(
                callback,
                eltype,
                if input_channels_filled > 0
                    eltype
                else
                    Nothing
                end,
                if output_channels_filled > 0
                    eltype
                else
                    Nothing
                end,
            ),
            Ref(callback_wrapper),
        ),
    )
    pointer_to = mutable_pointer[]
    PortAudioStream{eltype}(
        samplerate,
        pointer_to,
        input_channels_filled,
        output_channels_filled,
        frames_per_buffer,
    )
end

function start(stream::PortAudioStream)
    handle_status(Pa_StartStream(stream.pointer_to))
end

function stop(stream::PortAudioStream)
    handle_status(Pa_StopStream(stream.pointer_to))
end

function is_stopped(stream::PortAudioStream)
    result = handle_status(Pa_IsStreamStopped(stream.pointer_to))
    if result == 1
        true
    elseif result == 0
        false
    else
        error("Unexpected result $result")
    end
end

function Base.close(stream::PortAudioStream)
    handle_status(Pa_CloseStream(stream.pointer_to))
end

end # module PortAudio
