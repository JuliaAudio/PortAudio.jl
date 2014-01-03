export SinOsc, AudioMixer, ArrayPlayer, AudioInput

#### SinOsc ####

# Generates a sin tone at the given frequency

type SinOsc <: AudioNode
    active::Bool
    freq::Real
    phase::FloatingPoint

    function SinOsc(freq::Real)
        new(true, freq, 0.0)
    end
end

function render(node::SinOsc, device_input::AudioBuf, info::DeviceInfo)
    phase = AudioSample[1:info.buf_size] * 2pi * node.freq / info.sample_rate
    phase += node.phase
    node.phase = phase[end]
    return sin(phase), node.active
end

#### AudioMixer ####

# Mixes a set of inputs equally

type AudioMixer <: AudioNode
    active::Bool
    mix_inputs::Array{AudioNode}

    function AudioMixer{T <: AudioNode}(mix_inputs::Array{T})
        new(true, mix_inputs)
    end

    function AudioMixer()
        new(true, AudioNode[])
    end
end

function render(node::AudioMixer, device_input::AudioBuf, info::DeviceInfo)
    # TODO: we may want to pre-allocate this buffer and share between render
    # calls
    mix_buffer = zeros(AudioSample, info.buf_size)
    for in_node in node.mix_inputs
        in_buffer, active = render(in_node, device_input, info)
        mix_buffer += in_buffer
    end
    return mix_buffer, node.active
end

#### Array Player ####

# Plays a AudioBuf by rendering it out piece-by-piece

type ArrayPlayer <: AudioNode
    active::Bool
    arr::AudioBuf
    arr_index::Int

    function ArrayPlayer(arr::AudioBuf)
        new(true, arr, 1)
    end
end

function render(node::ArrayPlayer, device_input::AudioBuf, info::DeviceInfo)
    # TODO: this should remove itself from the render tree when playback is
    # complete
    i = node.arr_index
    range_end = min(i + info.buf_size-1, length(node.arr))
    output = node.arr[i:range_end]
    if length(output) < info.buf_size
        # we're finished with the array, pad with zeros and clear our active
        # flag
        output = vcat(output, zeros(AudioSample, info.buf_size - length(output)))
        node.active = false
    end
    node.arr_index = range_end + 1
    return output, node.active
end

#### AudioInput ####

# Renders incoming audio input from the hardware

type AudioInput <: AudioNode
    channel::Int
end

function render(node::AudioInput, device_input::AudioBuf, info::DeviceInfo)
    @assert size(device_input, 1) == info.buf_size
    return device_input[:, node.channel], true
end
