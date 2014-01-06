using Base.Test
using AudioIO

test_info = AudioIO.DeviceInfo(44100, 512)
dev_input = zeros(AudioIO.AudioSample, test_info.buf_size)

# A TestNode just renders out 1:buf_size each frame
type TestNode <: AudioIO.AudioNode
    active::Bool

    function TestNode()
        return new(false)
    end
end

function AudioIO.render(node::TestNode,
                device_input::AudioIO.AudioBuf,
                info::AudioIO.DeviceInfo)
    return AudioIO.AudioSample[1:info.buf_size], node.active
end

#### AudioMixer Tests ####

# TODO: there should be a setup/teardown mechanism and some way to isolate
# tests

info("Testing AudioMixer...")
mix = AudioMixer()
render_output, active = AudioIO.render(mix, dev_input, test_info)
@test render_output == zeros(AudioIO.AudioSample, test_info.buf_size)

testnode = TestNode()
mix = AudioMixer([testnode])
render_output, active = AudioIO.render(mix, dev_input, test_info)
@test render_output == AudioIO.AudioSample[1:test_info.buf_size]

test1 = TestNode()
test2 = TestNode()
mix = AudioMixer([test1, test2])
render_output, active = AudioIO.render(mix, dev_input, test_info)
# make sure the two inputs are being added together
@test render_output == 2 * AudioIO.AudioSample[1:test_info.buf_size]

# now we'll stop one of the inputs and make sure it gets removed
# TODO: this test should depend on the render output, not on the internals of
# the mixer
stop(test1)
AudioIO.render(mix, dev_input, test_info)
@test !in(test1, mix.mix_inputs)

stop(mix)
render_output, active = AudioIO.render(mix, dev_input, test_info)
@test !active

info("Testing SinOSC...")
freq = 440
t = linspace(1 / test_info.sample_rate,
             test_info.buf_size / test_info.sample_rate,
             test_info.buf_size)
test_vect = convert(AudioIO.AudioBuf, sin(2pi * t * freq))
osc = SinOsc(freq)
render_output, active = AudioIO.render(osc, dev_input, test_info)
@test_approx_eq(render_output, test_vect)
stop(osc)
render_output, active = AudioIO.render(osc, dev_input, test_info)
@test !active

info("Testing ArrayPlayer...")
v = rand(AudioIO.AudioSample, 44100)
player = ArrayPlayer(v)
player.active = true
render_output, active = AudioIO.render(player, dev_input, test_info)
@test render_output == v[1:test_info.buf_size]
@test active
render_output, active = AudioIO.render(player, dev_input, test_info)
@test render_output == v[(test_info.buf_size + 1) : (2*test_info.buf_size)]
@test active
stop(player)
render_output, active = AudioIO.render(player, dev_input, test_info)
@test !active

# give a vector just a bit larger than 1 buffer size
v = rand(AudioIO.AudioSample, test_info.buf_size + 1)
player = ArrayPlayer(v)
player.active = true
_, active = AudioIO.render(player, dev_input, test_info)
@test active
_, active = AudioIO.render(player, dev_input, test_info)
@test !active
