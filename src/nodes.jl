#### NullNode ####

type NullRenderer <: AudioRenderer end
typealias NullNode AudioNode{NullRenderer}
export NullNode

function render(node::NullRenderer, device_input::AudioBuf, info::DeviceInfo)
    # TODO: preallocate buffer
    return zeros(info.buf_size)
end

#### SinOsc ####

# Generates a sin tone at the given frequency

@compat type SinOscRenderer{T<:Union{Float32, AudioNode}} <: AudioRenderer
    freq::T
    phase::Float32
    buf::AudioBuf

    function SinOscRenderer(freq)
        new(freq, 0.0, AudioSample[])
    end
end

typealias SinOsc AudioNode{SinOscRenderer}
SinOsc(freq::Real) = SinOsc(SinOscRenderer{Float32}(freq))
SinOsc(freq::AudioNode) = SinOsc(SinOscRenderer{AudioNode}(freq))
SinOsc() = SinOsc(440)
export SinOsc

function render(node::SinOscRenderer{Float32}, device_input::AudioBuf,
        info::DeviceInfo)
    if length(node.buf) != info.buf_size
        resize!(node.buf, info.buf_size)
    end
    outbuf = node.buf
    phase = node.phase
    freq = node.freq
    # make sure these are Float32s so that we don't allocate doing conversions
    # in the tight loop
    pi2::Float32 = 2pi
    phase_inc::Float32 = 2pi * freq / info.sample_rate
    i::Int = 1
    while i <= info.buf_size
        outbuf[i] = sin(phase)
        phase = (phase + phase_inc) % pi2
        i += 1
    end
    node.phase = phase
    return outbuf
end

function render(node::SinOscRenderer{AudioNode}, device_input::AudioBuf,
        info::DeviceInfo)
    freq = render(node.freq, device_input, info)::AudioBuf
    block_size = min(length(freq), info.buf_size)
    if(length(node.buf) != block_size)
        resize!(node.buf, block_size)
    end
    outbuf = node.buf

    phase::Float32 = node.phase
    pi2::Float32 = 2pi
    phase_step::Float32 = 2pi/(info.sample_rate)
    i::Int = 1
    while i <= block_size
        outbuf[i] = sin(phase)
        phase = (phase + phase_step*freq[i]) % pi2
        i += 1
    end
    node.phase = phase
    return outbuf
end

#### AudioMixer ####

# Mixes a set of inputs equally

type MixRenderer <: AudioRenderer
    inputs::Vector{AudioNode}
    buf::AudioBuf

    MixRenderer(inputs) = new(inputs, AudioSample[])
    MixRenderer() = MixRenderer(AudioNode[])
end

typealias AudioMixer AudioNode{MixRenderer}
export AudioMixer

function render(node::MixRenderer, device_input::AudioBuf, info::DeviceInfo)
    if length(node.buf) != info.buf_size
        resize!(node.buf, info.buf_size)
    end
    mix_buffer = node.buf
    n_inputs = length(node.inputs)
    i = 1
    max_samples = 0
    fill!(mix_buffer, 0)
    while i <= n_inputs
        rendered = render(node.inputs[i], device_input, info)::AudioBuf
        nsamples = length(rendered)
        max_samples = max(max_samples, nsamples)
        j::Int = 1
        while j <= nsamples
            mix_buffer[j] += rendered[j]
            j += 1
        end
        if nsamples < info.buf_size
            deleteat!(node.inputs, i)
            n_inputs -= 1
        else
            i += 1
        end
    end
    if max_samples < length(mix_buffer)
        return mix_buffer[1:max_samples]
    else
        # save the allocate and copy if we don't need to
        return mix_buffer
    end
end

Base.push!(mixer::AudioMixer, node::AudioNode) = push!(mixer.renderer.inputs, node)

#### Gain ####
@compat type GainRenderer{T<:Union{Float32, AudioNode}} <: AudioRenderer
    in1::AudioNode
    in2::T
    buf::AudioBuf

    GainRenderer(in1, in2) = new(in1, in2, AudioSample[])
end

function render(node::GainRenderer{Float32},
                device_input::AudioBuf,
                info::DeviceInfo)
    input = render(node.in1, device_input, info)::AudioBuf
    if length(node.buf) != length(input)
        resize!(node.buf, length(input))
    end
    i = 1
    while i <= length(input)
        node.buf[i] = input[i] * node.in2
        i += 1
    end
    return node.buf
end

function render(node::GainRenderer{AudioNode},
                device_input::AudioBuf,
                info::DeviceInfo)
    in1_data = render(node.in1, device_input, info)::AudioBuf
    in2_data = render(node.in2, device_input, info)::AudioBuf
    block_size = min(length(in1_data), length(in2_data))
    if length(node.buf) != block_size
        resize!(node.buf, block_size)
    end
    i = 1
    while i <= block_size
        node.buf[i] = in1_data[i] * in2_data[i]
        i += 1
    end
    return node.buf
end

typealias Gain AudioNode{GainRenderer}
Gain(in1::AudioNode, in2::Real) = Gain(GainRenderer{Float32}(in1, in2))
Gain(in1::AudioNode, in2::AudioNode) = Gain(GainRenderer{AudioNode}(in1, in2))
export Gain

#### Offset ####
type OffsetRenderer <: AudioRenderer
    in_node::AudioNode
    offset::Float32
    buf::AudioBuf

    OffsetRenderer(in_node, offset) = new(in_node, offset, AudioSample[])
end

function render(node::OffsetRenderer, device_input::AudioBuf, info::DeviceInfo)
    input = render(node.in_node, device_input, info)::AudioBuf
    if length(node.buf) != length(input)
        resize!(node.buf, length(input))
    end
    i = 1
    while i <= length(input)
        node.buf[i] = input[i] + node.offset
        i += 1
    end
    return node.buf
end

typealias Offset AudioNode{OffsetRenderer}
export Offset


#### Array Player ####

# Plays a AudioBuf by rendering it out piece-by-piece

type ArrayRenderer <: AudioRenderer
    arr::AudioBuf
    arr_index::Int
    buf::AudioBuf

    ArrayRenderer(arr::AudioBuf) = new(arr, 1, AudioSample[])
end

typealias ArrayPlayer AudioNode{ArrayRenderer}
export ArrayPlayer

function render(node::ArrayRenderer, device_input::AudioBuf, info::DeviceInfo)
    range_end = min(node.arr_index + info.buf_size-1, length(node.arr))
    block_size = range_end - node.arr_index + 1
    if length(node.buf) != block_size
        resize!(node.buf, block_size)
    end
    copy!(node.buf, 1, node.arr, node.arr_index, block_size)
    node.arr_index = range_end + 1
    return node.buf
end

# Allow users to play a raw array by wrapping it in an ArrayPlayer
function play(arr::AudioBuf, args...)
    player = ArrayPlayer(arr)
    play(player, args...)
end

# If the array is the wrong floating type, convert it
function play{T <: AbstractFloat}(arr::Array{T}, args...)
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
    arr = (arr .- zero) / range
    play(arr, args...)
end

#### Noise ####

type WhiteNoiseRenderer <: AudioRenderer end
typealias WhiteNoise AudioNode{WhiteNoiseRenderer}
export WhiteNoise

function render(node::WhiteNoiseRenderer, device_input::AudioBuf, info::DeviceInfo)
    return rand(AudioSample, info.buf_size) .* 2 .- 1
end


#### AudioInput ####

# Renders incoming audio input from the hardware

type InputRenderer <: AudioRenderer
    channel::Int
    InputRenderer(channel::Integer) = new(channel)
    InputRenderer() = new(1)
end

function render(node::InputRenderer, device_input::AudioBuf, info::DeviceInfo)
    @assert size(device_input, 1) == info.buf_size
    return device_input[:, node.channel]
end

typealias AudioInput AudioNode{InputRenderer}
export AudioInput

#### LinRamp ####

type LinRampRenderer <: AudioRenderer
    key_samples::Array{AudioSample}
    key_durations::Array{Float32}

    duration::Float32
    buf::AudioBuf

    LinRampRenderer(start, finish, dur) = LinRampRenderer([start,finish], [dur])

    LinRampRenderer(key_samples, key_durations) =
        LinRampRenderer(
            [convert(AudioSample,s) for s in key_samples],
            [convert(Float32,d) for d in key_durations]
        )

    function LinRampRenderer(key_samples::Array{AudioSample}, key_durations::Array{Float32})
        @assert length(key_samples) == length(key_durations) + 1
        new(key_samples, key_durations, sum(key_durations), AudioSample[])
    end
end

typealias LinRamp AudioNode{LinRampRenderer}
export LinRamp

function render(node::LinRampRenderer, device_input::AudioBuf, info::DeviceInfo)
    # Resize buffer if (1) it's too small or (2) we've hit the end of the ramp
    ramp_samples::Int = round(Int, node.duration * info.sample_rate)
    block_samples = min(ramp_samples, info.buf_size)
    if length(node.buf) != block_samples
        resize!(node.buf, block_samples)
    end

    # Fill the buffer as long as there are more segments
    dt::Float32 = 1/info.sample_rate
    i::Int = 1
    while i <= length(node.buf) && length(node.key_samples) > 1

        # Fill as much of the buffer as we can with the current segment
        ds::Float32 = (node.key_samples[2] - node.key_samples[1]) / node.key_durations[1] / info.sample_rate
        while i <= length(node.buf)
            node.buf[i] = node.key_samples[1]
            node.key_samples[1] += ds
            node.key_durations[1] -= dt
            node.duration -= dt
            i += 1

            # Discard segment if we're finished
            if node.key_durations[1] <= 0
                if length(node.key_durations) > 1
                    node.key_durations[2] -= node.key_durations[1]
                end
                shift!(node.key_samples)
                shift!(node.key_durations)
                break
            end
        end
    end

    return node.buf
end
