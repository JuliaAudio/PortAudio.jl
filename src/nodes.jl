#### NullNode ####

type NullRenderer <: AudioRenderer end
typealias NullNode AudioNode{NullRenderer}
NullNode() = NullNode(NullRenderer())
export NullNode

function render(node::NullRenderer, device_input::AudioBuf, info::DeviceInfo)
    # TODO: preallocate buffer
    return zeros(info.buf_size)
end

#### SinOsc ####

# Generates a sin tone at the given frequency

type SinOscRenderer{T<:Union(Float32, AudioNode)} <: AudioRenderer
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
end

typealias AudioMixer AudioNode{MixRenderer}
AudioMixer{T<:AudioNode}(inputs::Vector{T}) = AudioMixer(MixRenderer(inputs))
AudioMixer() = AudioMixer(AudioNode[])
export AudioMixer

function render(node::MixRenderer, device_input::AudioBuf, info::DeviceInfo)
    # TODO: we probably want to pre-allocate this buffer and share between
    # render calls. Unfortunately we don't know the right size when the object
    # is created, so maybe we check the size on every render call and only
    # re-allocate when the size changes? I suppose that's got to be cheaper
    # than the GC and allocation every frame

    mix_buffer = zeros(AudioSample, info.buf_size)
    n_inputs = length(node.inputs)
    i = 1
    max_samples = 0
    while i <= n_inputs
        rendered = render(node.inputs[i], device_input, info)::AudioBuf
        nsamples = length(rendered)
        max_samples = max(max_samples, nsamples)
        mix_buffer[1:nsamples] .+= rendered
        if nsamples < info.buf_size
            deleteat!(node.inputs, i)
            n_inputs -= 1
        else
            i += 1
        end
    end
    return mix_buffer[1:max_samples]
end

Base.push!(mixer::AudioMixer, node::AudioNode) = push!(mixer.renderer.inputs, node)

#### Gain ####
type GainRenderer <: AudioRenderer
    in_node::AudioNode
    gain::Float32
end

function render(node::GainRenderer, device_input::AudioBuf, info::DeviceInfo)
    input = render(node.in_node, device_input, info)
    return input .* node.gain
end

typealias Gain AudioNode{GainRenderer}
Gain(in_node::AudioNode, gain::Real) = Gain(GainRenderer(in_node, gain))
export Gain


#### Array Player ####

# Plays a AudioBuf by rendering it out piece-by-piece

type ArrayRenderer <: AudioRenderer
    arr::AudioBuf
    arr_index::Int
    buf::AudioBuf

    ArrayRenderer(arr::AudioBuf) = new(arr, 1, AudioSample[])
end

typealias ArrayPlayer AudioNode{ArrayRenderer}
ArrayPlayer(arr::AudioBuf) = ArrayPlayer(ArrayRenderer(arr))
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
    arr = (arr .- zero) / range
    play(arr, args...)
end

#### Noise ####

type WhiteNoiseRenderer <: AudioRenderer end
typealias WhiteNoise AudioNode{WhiteNoiseRenderer}
WhiteNoise() = WhiteNoise(WhiteNoiseRenderer())
export WhiteNoise

function render(node::WhiteNoiseRenderer, device_input::AudioBuf, info::DeviceInfo)
    return rand(AudioSample, info.buf_size) .* 2 .- 1
end


#### AudioInput ####

# Renders incoming audio input from the hardware

type InputRenderer <: AudioRenderer
    channel::Int
end

function render(node::InputRenderer, device_input::AudioBuf, info::DeviceInfo)
    @assert size(device_input, 1) == info.buf_size
    return device_input[:, node.channel]
end

typealias AudioInput AudioNode{InputRenderer}
AudioInput(channel::Int) = AudioInput(InputRenderer(channel))
export AudioInput

#### Ramp ####

type LinRampRenderer <: AudioRenderer
    start::AudioSample
    finish::AudioSample
    dur::Float32
    buf::AudioBuf

    LinRampRenderer(start, finish, dur) = new(start, finish, dur, AudioSample[])
end

typealias LinRamp AudioNode{LinRampRenderer}
function LinRamp(start::Real, finish::Real, dur::Real)
    LinRamp(LinRampRenderer(start, finish, dur))
end
export LinRamp


function render(node::LinRampRenderer, device_input::AudioBuf, info::DeviceInfo)
    ramp_samples = int(node.dur * info.sample_rate)
    block_samples = min(ramp_samples, info.buf_size)
    if length(node.buf) != block_samples
        resize!(node.buf, block_samples)
    end

    out_block = node.buf
    i::Int = 1
    val::AudioSample = node.start
    inc::AudioSample = (node.finish - node.start) / ramp_samples
    while i <= block_samples
        out_block[i] = val
        i += 1
        val += inc
    end
    node.dur -= block_samples / info.sample_rate
    node.start = val

    return out_block
end

