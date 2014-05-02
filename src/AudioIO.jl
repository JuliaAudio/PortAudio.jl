module AudioIO

# export the basic API
export play, stop, get_audio_devices

# default stream used when none is given
_stream = nothing

################## Types ####################

typealias AudioSample Float32
# A frame of audio, possibly multi-channel
typealias AudioBuf Array{AudioSample}

# A node in the render tree
abstract AudioNode

# A stream of audio (for instance that writes to hardware)
# All AudioStream subtypes should have a mixer and info field
abstract AudioStream

# Info about the hardware device
type DeviceInfo
    sample_rate::Integer
    buf_size::Integer
end

include("nodes.jl")
include("portaudio.jl")
include("sndfile.jl")

############ Exported Functions #############

# Play an AudioNode by adding it as an input to the root mixer node
function play(node::AudioNode, stream::AudioStream)
    activate(node)
    add_input(stream.mixer, node)
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
    deactivate(node)
    node
end

function activate(node::AudioNode)
    node.active = true
end

function deactivate(node::AudioNode)
    node.active = false
    notify(node.deactivate_cond)
end

function is_active(node::AudioNode)
    node.active
end

function Base.wait(node::AudioNode)
    if is_active(node)
        wait(node.deactivate_cond)
    end
end

function get_audio_devices()
    return get_portaudio_devices()
end

end # module AudioIO
