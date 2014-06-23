using Base.Test
using AudioIO
import AudioIO.AudioSample
import AudioIO.AudioBuf
import AudioIO.AudioRenderer
import AudioIO.AudioNode
import AudioIO.DeviceInfo
import AudioIO.render

test_info = DeviceInfo(44100, 512)
dev_input = zeros(AudioSample, test_info.buf_size)

# A TestNode just renders out 1:buf_size each frame
type TestRenderer <: AudioRenderer end

typealias TestNode AudioNode{TestRenderer}
TestNode() = TestNode(TestRenderer())

function render(node::TestRenderer,
                device_input::AudioBuf,
                info::DeviceInfo)
    return AudioSample[1:info.buf_size]
end

#### AudioMixer Tests ####

# TODO: there should be a setup/teardown mechanism and some way to isolate
# tests

info("Testing AudioMixer...")
mix = AudioMixer()
render_output = render(mix, dev_input, test_info)
@test render_output == AudioSample[]

testnode = TestNode()
mix = AudioMixer([testnode])
render_output = render(mix, dev_input, test_info)
@test render_output == AudioSample[1:test_info.buf_size]

test1 = TestNode()
test2 = TestNode()
mix = AudioMixer([test1, test2])
render_output = render(mix, dev_input, test_info)
# make sure the two inputs are being added together
@test render_output == 2 * AudioSample[1:test_info.buf_size]

# now we'll stop one of the inputs and make sure it gets removed
stop(test1)
render_output = render(mix, dev_input, test_info)
# make sure the two inputs are being added together
@test render_output == AudioSample[1:test_info.buf_size]

stop(mix)
render_output = render(mix, dev_input, test_info)
@test render_output == AudioSample[]

info("Testing SinOSC...")
freq = 440
# note that this range includes the end, which is why there are sample_rate+1 samples
t = linspace(0, 1, test_info.sample_rate+1)
test_vect = convert(AudioBuf, sin(2pi * t * freq))
osc = SinOsc(freq)
render_output = render(osc, dev_input, test_info)
@test render_output == test_vect[1:test_info.buf_size]
render_output = render(osc, dev_input, test_info)
@test render_output == test_vect[test_info.buf_size+1:2*test_info.buf_size]
stop(osc)
render_output = render(osc, dev_input, test_info)
@test render_output == AudioSample[]

info("Testing ArrayPlayer...")
v = rand(AudioSample, 44100)
player = ArrayPlayer(v)
render_output = render(player, dev_input, test_info)
@test render_output == v[1:test_info.buf_size]
render_output = render(player, dev_input, test_info)
@test render_output == v[(test_info.buf_size + 1) : (2*test_info.buf_size)]
stop(player)
render_output = render(player, dev_input, test_info)
@test render_output == AudioSample[]

# give a vector just a bit larger than 1 buffer size
v = rand(AudioSample, test_info.buf_size + 1)
player = ArrayPlayer(v)
render(player, dev_input, test_info)
render_output = render(player, dev_input, test_info)
@test render_output == v[test_info.buf_size+1:end]

info("Testing Gain...")

gained = TestNode() * 0.75
render_output = render(gained, dev_input, test_info)
@test render_output == 0.75 * AudioSample[1:test_info.buf_size]
