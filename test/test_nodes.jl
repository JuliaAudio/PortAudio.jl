using Base.Test
using PortAudio

test_info = PortAudio.DeviceInfo(44100, 512)
dev_input = zeros(PortAudio.AudioSample, test_info.buf_size)

# A TestNode just renders out 1:buf_size each frame
type TestNode <: PortAudio.AudioNode
end

function PortAudio.render(node::TestNode,
                device_input::PortAudio.AudioBuf,
                info::PortAudio.DeviceInfo)
    return PortAudio.AudioSample[1:info.buf_size]
end

#### AudioMixer Tests ####

# TODO: there should be a setup/teardown mechanism and some way to isolate
# tests

info("Testing AudioMixer...")
mix = AudioMixer()
@test mix.mix_inputs == PortAudio.AudioNode[]
@test PortAudio.render(mix, dev_input, test_info) == zeros(PortAudio.AudioSample, test_info.buf_size)

testnode = TestNode()
mix = AudioMixer([testnode])
@test mix.mix_inputs == PortAudio.AudioNode[testnode]
@test PortAudio.render(mix, dev_input, test_info) == PortAudio.AudioSample[1:test_info.buf_size]

test1 = TestNode()
test2 = TestNode()
mix = AudioMixer([test1, test2])
@test PortAudio.render(mix, dev_input, test_info) == 2 * PortAudio.AudioSample[1:test_info.buf_size]

info("Testing SinOSC...")
freq = 440
t = linspace(1 / test_info.sample_rate,
             test_info.buf_size / test_info.sample_rate,
             test_info.buf_size)
test_vect = convert(PortAudio.AudioBuf, sin(2pi * t * freq))
osc = SinOsc(freq)
rendered = PortAudio.render(osc, dev_input, test_info)
@test_approx_eq(rendered, test_vect)
