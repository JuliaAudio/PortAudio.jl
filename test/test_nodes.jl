module TestAudioIONodes

using FactCheck
using AudioIO
import AudioIO: AudioSample, AudioBuf, AudioRenderer, AudioNode
import AudioIO: DeviceInfo, render

include("testhelpers.jl")

# A TestNode just renders out 1:buf_size each frame
type TestRenderer <: AudioRenderer
    buf::AudioBuf
    TestRenderer(buf_size::Integer) = new(AudioSample[1:buf_size])
end

typealias TestNode AudioNode{TestRenderer}
TestNode(buf_size) = TestNode(TestRenderer(buf_size))

function render(node::TestRenderer,
                device_input::AudioBuf,
                info::DeviceInfo)
    return node.buf
end

test_info = DeviceInfo(44100, 512)
dev_input = zeros(AudioSample, test_info.buf_size)

facts("Validating TestNode allocation") do
    # first validate that the TestNode doesn't allocate so it doesn't mess up our
    # other tests
    test = TestNode(test_info.buf_size)
    # JIT
    render(test, dev_input, test_info)
    @fact (@allocated render(test, dev_input, test_info)) => 16
end

#### AudioMixer Tests ####

# TODO: there should be a setup/teardown mechanism and some way to isolate
# tests

facts("AudioMixer") do
    context("0 Input Mixer") do
        mix = AudioMixer()
        render_output = render(mix, dev_input, test_info)
        @fact render_output => AudioSample[]
        @fact (@allocated render(mix, dev_input, test_info)) => 48
    end

    context("1 Input Mixer") do
        testnode = TestNode(test_info.buf_size)
        mix = AudioMixer([testnode])
        render_output = render(mix, dev_input, test_info)
        @fact render_output => AudioSample[1:test_info.buf_size]
        @fact (@allocated render(mix, dev_input, test_info)) => 64
    end

    context("2 Input Mixer") do
        test1 = TestNode(test_info.buf_size)
        test2 = TestNode(test_info.buf_size)
        mix = AudioMixer([test1, test2])
        render_output = render(mix, dev_input, test_info)
        # make sure the two inputs are being added together
        @fact render_output => 2 * AudioSample[1:test_info.buf_size]
        @fact (@allocated render(mix, dev_input, test_info)) => 96
        # now we'll stop one of the inputs and make sure it gets removed
        stop(test1)
        render_output = render(mix, dev_input, test_info)
        # make sure the two inputs are being added together
        @fact render_output => AudioSample[1:test_info.buf_size]

        stop(mix)
        render_output = render(mix, dev_input, test_info)
        @fact render_output => AudioSample[]
    end
end

MSE_THRESH = 1e-7

facts("SinOSC") do
    freq = 440
    # note that this range includes the end, which is why there are
    # sample_rate+1 samples
    t = linspace(0, 1, int(test_info.sample_rate+1))
    test_vect = convert(AudioBuf, sin(2pi * t * freq))
    context("Fixed Frequency") do
        osc = SinOsc(freq)
        render_output = render(osc, dev_input, test_info)
        @fact mse(render_output, test_vect[1:test_info.buf_size]) =>
                lessthan(MSE_THRESH)
        render_output = render(osc, dev_input, test_info)
        @fact mse(render_output,
                test_vect[test_info.buf_size+1:2*test_info.buf_size]) =>
                lessthan(MSE_THRESH)
        @fact (@allocated render(osc, dev_input, test_info)) => 64
        stop(osc)
        render_output = render(osc, dev_input, test_info)
        @fact render_output => AudioSample[]
    end

    context("Testing SinOsc with signal input") do
        t = linspace(0, 1, int(test_info.sample_rate+1))
        f = 440 .- t .* (440-110)
        dt = 1 / test_info.sample_rate
        # NOTE - this treats the phase as constant at each sample, which isn't strictly
        # true. Unfortunately doing this correctly requires knowing more about the
        # modulating signal and doing the real integral
        phase = cumsum(2pi * dt .* f)
        unshift!(phase, 0)
        expected = convert(AudioBuf, sin(phase))

        freq = LinRamp(440, 110, 1)
        osc = SinOsc(freq)
        render_output = render(osc, dev_input, test_info)
        @fact mse(render_output, expected[1:test_info.buf_size]) =>
                lessthan(MSE_THRESH)
        render_output = render(osc, dev_input, test_info)
        @fact mse(render_output,
                expected[test_info.buf_size+1:2*test_info.buf_size]) =>
                lessthan(MSE_THRESH)
        # give a bigger budget here because we're rendering 2 nodes
        @fact (@allocated render(osc, dev_input, test_info)) => 160
    end
end

facts("AudioInput") do
    node = AudioInput()
    test_data = rand(AudioSample, test_info.buf_size)
    render_output = render(node, test_data, test_info)
    @fact render_output => test_data
end

facts("ArrayPlayer") do
    context("playing long sample") do
        v = rand(AudioSample, 44100)
        player = ArrayPlayer(v)
        render_output = render(player, dev_input, test_info)
        @fact render_output => v[1:test_info.buf_size]
        render_output = render(player, dev_input, test_info)
        @fact render_output => v[(test_info.buf_size + 1) : (2*test_info.buf_size)]
        @fact (@allocated render(player, dev_input, test_info)) => 192
        stop(player)
        render_output = render(player, dev_input, test_info)
        @fact render_output => AudioSample[]
    end

    context("testing end of vector") do
        # give a vector just a bit larger than 1 buffer size
        v = rand(AudioSample, test_info.buf_size + 1)
        player = ArrayPlayer(v)
        render(player, dev_input, test_info)
        render_output = render(player, dev_input, test_info)
        @fact render_output => v[test_info.buf_size+1:end]
    end
end

facts("Gain") do
    context("Constant Gain") do
        gained = TestNode(test_info.buf_size) * 0.75
        render_output = render(gained, dev_input, test_info)
        @fact render_output => 0.75 * AudioSample[1:test_info.buf_size]
        @fact (@allocated render(gained, dev_input, test_info)) => 32
    end
    context("Gain by a Signal") do
        gained = TestNode(test_info.buf_size) * TestNode(test_info.buf_size)
        render_output = render(gained, dev_input, test_info)
        @fact render_output => AudioSample[1:test_info.buf_size] .* AudioSample[1:test_info.buf_size]
        @fact (@allocated render(gained, dev_input, test_info)) => 48
    end
end

facts("LinRamp") do
    ramp = LinRamp(0.25, 0.80, 1)
    expected = convert(AudioBuf, linspace(0.25, 0.80, int(test_info.sample_rate+1)))
    render_output = render(ramp, dev_input, test_info)
    @fact mse(render_output, expected[1:test_info.buf_size]) =>
            lessthan(MSE_THRESH)
    render_output = render(ramp, dev_input, test_info)
    @fact mse(render_output,
            expected[(test_info.buf_size+1):(2*test_info.buf_size)]) =>
            lessthan(MSE_THRESH)
    @fact (@allocated render(ramp, dev_input, test_info)) => 64
end

facts("Offset") do
    offs = TestNode(test_info.buf_size) + 0.5
    render_output = render(offs, dev_input, test_info)
    @fact render_output => 0.5 + AudioSample[1:test_info.buf_size]
    @fact (@allocated render(offs, dev_input, test_info)) => 32
end

end # module TestAudioIONodes
