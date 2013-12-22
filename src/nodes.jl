#### SinOsc ####

# Generates a sin tone at the given frequency

type SinOsc <: AudioNode
    freq::Real
    phase::FloatingPoint

    function SinOsc(freq::Real)
        new(freq, 0.0)
    end
end

function render(node::SinOsc, device_input::AudioBuf, info::DeviceInfo)
    phase = AudioSample[1:info.buf_size] * 2pi * node.freq / info.sample_rate
    phase += node.phase
    node.phase = phase[end]
    return sin(phase)
end

#### AudioMixer ####

# Mixes a set of inputs equally

type AudioMixer <: AudioNode
    mix_inputs::Array{AudioNode}

    function AudioMixer{T <: AudioNode}(mix_inputs::Array{T})
        new(mix_inputs)
    end

    function AudioMixer()
        new(AudioNode[])
    end
end

function render(node::AudioMixer, device_input::AudioBuf, info::DeviceInfo)
    # TODO: we may want to pre-allocate this buffer and share between render
    # calls
    mix_buffer = zeros(AudioSample, info.buf_size)
    for in_node in node.mix_inputs
        mix_buffer += render(in_node, device_input, info)
    end
    return mix_buffer
end

#### Array Player ####

# Plays a AudioBuf by rendering it out piece-by-piece

type ArrayPlayer <: AudioNode
    arr::AudioBuf
    arr_index::Int

    function ArrayPlayer(arr::AudioBuf)
        new(arr, 1)
    end
end

function render(node::ArrayPlayer, device_input::AudioBuf, info::DeviceInfo)
    i = node.arr_index
    range_end = min(i + info.buf_size-1, length(node.arr))
    output = node.arr[i:range_end]
    if length(output) < info.buf_size
        output = vcat(output, zeros(AudioSample, info.buf_size - length(output)))
    end
    node.arr_index = range_end + 1
    return output
end

#### AudioInput ####

# Renders incoming audio input from the hardware

type AudioInput <: AudioNode
    channel::Int
end

function render(node::AudioInput, device_input::AudioBuf, info::DeviceInfo)
    @assert size(device_input, 1) == info.buf_size
    return device_input[:, node.channel]
end
