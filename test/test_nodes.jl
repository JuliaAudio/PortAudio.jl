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
    return AudioIO.AudioSample[1:info.buf_size], true
end

#### AudioMixer Tests ####

# TODO: there should be a setup/teardown mechanism and some way to isolate
# tests

info("Testing AudioMixer...")
mix = AudioMixer()
render_output, active = AudioIO.render(mix, dev_input, test_info)
@test mix.mix_inputs == AudioIO.AudioNode[]
@test render_output == zeros(AudioIO.AudioSample, test_info.buf_size)
@test active

testnode = TestNode()
mix = AudioMixer([testnode])
render_output, active = AudioIO.render(mix, dev_input, test_info)
@test mix.mix_inputs == AudioIO.AudioNode[testnode]
@test render_output == AudioIO.AudioSample[1:test_info.buf_size]
@test active

mix = AudioMixer([TestNode(), TestNode()])
render_output, active = AudioIO.render(mix, dev_input, test_info)
@test render_output == 2 * AudioIO.AudioSample[1:test_info.buf_size]
@test active

info("Testing SinOSC...")
freq = 440
t = linspace(1 / test_info.sample_rate,
             test_info.buf_size / test_info.sample_rate,
             test_info.buf_size)
test_vect = convert(AudioIO.AudioBuf, sin(2pi * t * freq))
osc = SinOsc(freq)
render_output, active = AudioIO.render(osc, dev_input, test_info)
@test_approx_eq(render_output, test_vect)
@test active
