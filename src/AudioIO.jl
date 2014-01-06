module AudioIO

# export the basic API
export play, stop

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
    node.active = true
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

# Allow users to play a raw array by wrapping it in an ArrayPlayer
function play(arr::AudioBuf, args...)
    player = ArrayPlayer(arr)
    play(player, args...)
end

# If the array is the wrong floating type, convert it
function play{T <: FloatingPoint}(arr::Array{T}, args...)
    arr = convert(AudioBuf, arr)
    play(arr, args...)
end

# If the array is an integer type, scale to [-1, 1] floating point

# integer audio can be slightly (by 1) more negative than positive,
# so we just scale so that +/- typemax(T) becomes +/- 1
function play{T <: Signed}(arr::Array{T}, args...)
    arr = arr / typemax(T)
    play(arr, args...)
end

function play{T <: Unsigned}(arr::Array{T}, args...)
    zero = (typemax(T) + 1) / 2
    range = floor(typemax(T) / 2)
    arr = (arr - zero) / range
    play(arr, args...)
end

function stop(node::AudioNode)
    node.active = false
    return node
end

end # module AudioIO
