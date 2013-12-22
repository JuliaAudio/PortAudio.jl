using Base.Test
using PortAudio

info = PortAudio.DeviceInfo(44100, 512)
dev_input = zeros(PortAudio.AudioSample, info.buf_size)

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

mix = AudioMixer()
@test mix.mix_inputs == PortAudio.AudioNode[]
@test PortAudio.render(mix, dev_input, info) == zeros(PortAudio.AudioSample, info.buf_size)

testnode = TestNode()
mix = AudioMixer([testnode])
@test mix.mix_inputs == PortAudio.AudioNode[testnode]
@test PortAudio.render(mix, dev_input, info) == PortAudio.AudioSample[1:info.buf_size]

test1 = TestNode()
test2 = TestNode()
mix = AudioMixer([test1, test2])
@test PortAudio.render(mix, dev_input, info) == 2 * PortAudio.AudioSample[1:info.buf_size]

