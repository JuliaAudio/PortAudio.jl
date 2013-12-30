using Base.Test
using PortAudio

const TEST_SAMPLERATE = 44100
const TEST_BUF_SIZE = 1024

type TestAudioStream <: PortAudio.AudioStream
    mixer::AudioMixer
    info::PortAudio.DeviceInfo

    function TestAudioStream()
        mixer = AudioMixer()
        new(mixer, PortAudio.DeviceInfo(TEST_SAMPLERATE, TEST_BUF_SIZE))
    end
end

# render the stream and return the next block of audio. This is used in testing
# to simulate the audio callback that's normally called by the device.
function process(stream::TestAudioStream)
    in_array = zeros(PortAudio.AudioSample, stream.info.buf_size)
    return PortAudio.render(stream.mixer, in_array, stream.info)
end


#### Test playing back various vector types ####

# data shared between tests, for convenience
t = linspace(0, 2, 2 * 44100)
phase = 2pi * 100 * t

## Test Float32 arrays, this is currently the native audio playback format
info("Testing Playing Float32 arrays...")
f32 = convert(Array{Float32}, sin(phase))
test_stream = TestAudioStream()
player = play(f32, test_stream)
@test process(test_stream) == f32[1:TEST_BUF_SIZE]
#stop(player)
#@test process(test_stream) == zeros(PortAudio.AudioSample, TEST_BUF_SIZE)


info("Testing Playing Float64 arrays...")
f64 = convert(Array{Float64}, sin(phase))
test_stream = TestAudioStream()
player = play(f64, test_stream)
@test process(test_stream) == convert(PortAudio.AudioBuf, f64[1:TEST_BUF_SIZE])

info("Testing Playing Int8(Signed) arrays...")
i8 = Int8[-127:127]
test_stream = TestAudioStream()
player = play(i8, test_stream)
@test_approx_eq(process(test_stream)[1:255],
                   convert(PortAudio.AudioBuf, linspace(-1.0, 1.0, 255)))

info("Testing Playing Uint8(Unsigned) arrays...")
# for unsigned 8-bit audio silence is represented as 128, so the symmetric range
# is 1-255
ui8 = Uint8[1:255]
test_stream = TestAudioStream()
player = play(ui8, test_stream)
@test_approx_eq(process(test_stream)[1:255],
                   convert(PortAudio.AudioBuf, linspace(-1.0, 1.0, 255)))


#info("Testing AudioNode Stopping...")
#test_stream = TestAudioStream()
#node = SinOsc(440)
#play(node, test_stream)
#process(test_stream)
#stop(node)
#@test process(test_stream) == zeros(PortAudio.AudioSample, TEST_BUF_SIZE)
