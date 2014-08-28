module AudioIO

# export the basic API
export play, stop, get_audio_devices

# default stream used when none is given
_stream = nothing

################## Types ####################

typealias AudioSample Float32
# A frame of audio, possibly multi-channel
typealias AudioBuf Array{AudioSample}

# used as a type parameter for AudioNodes. Subtypes handle the actual DSP for
# each node
abstract AudioRenderer

# A stream of audio (for instance that writes to hardware). All AudioStream
# subtypes should have a root and info field
abstract AudioStream
samplerate(str::AudioStream) = str.info.sample_rate
bufsize(str::AudioStream) = str.info.buf_size

# An audio interface is usually a physical sound card, but could
# be anything you'd want to connect a stream to
abstract AudioInterface

# Info about the hardware device
type DeviceInfo
    sample_rate::Float32
    buf_size::Integer
end

type AudioNode{T<:AudioRenderer}
    active::Bool
    end_cond::Condition
    renderer::T

    AudioNode(renderer::AudioRenderer) = new(true, Condition(), renderer)
    AudioNode(args...) = AudioNode{T}(T(args...))
end

function render(node::AudioNode, input::AudioBuf, info::DeviceInfo)
    # TODO: not sure if the compiler will infer that render() always returns an
    # AudioBuf. Might need to help it
    if node.active
        result = render(node.renderer, input, info)
        if length(result) < info.buf_size
            node.active = false
            notify(node.end_cond)
        end
        return result
    else
        return AudioSample[]
    end
end

# Get binary dependencies loaded from BinDeps
include( "../deps/deps.jl")
include("nodes.jl")
include("portaudio.jl")
include("sndfile.jl")
include("operators.jl")

############ Exported Functions #############

# Play an AudioNode by adding it as an input to the root mixer node
function play(node::AudioNode, stream::AudioStream)
    push!(stream.root, node)
    return node
end

# If the stream is not given, use the default global PortAudio stream
function play(node::AudioNode)
    global _stream
    if _stream == nothing
        _stream = PortAudioStream()
    end
    play(node, _stream)
end

function stop(node::AudioNode)
    node.active = false
    notify(node.end_cond)
end

function Base.wait(node::AudioNode)
    if node.active
        wait(node.end_cond)
    end
end

function get_audio_devices()
    return get_portaudio_devices()
end

end # module AudioIO
