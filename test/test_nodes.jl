using Base.Test
using AudioIO

test_info = AudioIO.DeviceInfo(44100, 512)
dev_input = zeros(AudioIO.AudioSample, test_info.buf_size)

# A TestNode just renders out 1:buf_size each frame
type TestNode <: AudioIO.AudioNode
end

function AudioIO.render(node::TestNode,
                device_input::AudioIO.AudioBuf,
                info::AudioIO.DeviceInfo)
    return AudioIO.AudioSample[1:info.buf_size]
end

#### AudioMixer Tests ####

# TODO: there should be a setup/teardown mechanism and some way to isolate
# tests

info("Testing AudioMixer...")
mix = AudioMixer()
@test mix.mix_inputs == AudioIO.AudioNode[]
@test AudioIO.render(mix, dev_input, test_info) == zeros(AudioIO.AudioSample, test_info.buf_size)

testnode = TestNode()
mix = AudioMixer([testnode])
@test mix.mix_inputs == AudioIO.AudioNode[testnode]
@test AudioIO.render(mix, dev_input, test_info) == AudioIO.AudioSample[1:test_info.buf_size]

test1 = TestNode()
test2 = TestNode()
mix = AudioMixer([test1, test2])
@test AudioIO.render(mix, dev_input, test_info) == 2 * AudioIO.AudioSample[1:test_info.buf_size]

info("Testing SinOSC...")
freq = 440
t = linspace(1 / test_info.sample_rate,
             test_info.buf_size / test_info.sample_rate,
             test_info.buf_size)
test_vect = convert(AudioIO.AudioBuf, sin(2pi * t * freq))
osc = SinOsc(freq)
rendered = AudioIO.render(osc, dev_input, test_info)
@test_approx_eq(rendered, test_vect)
