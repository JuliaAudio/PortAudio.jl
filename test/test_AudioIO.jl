using Base.Test
using AudioIO

const TEST_SAMPLERATE = 44100
const TEST_BUF_SIZE = 1024

type TestAudioStream <: AudioIO.AudioStream
    mixer::AudioMixer
    info::AudioIO.DeviceInfo

    function TestAudioStream()
        mixer = AudioMixer()
        new(mixer, AudioIO.DeviceInfo(TEST_SAMPLERATE, TEST_BUF_SIZE))
    end
end

# render the stream and return the next block of audio. This is used in testing
# to simulate the audio callback that's normally called by the device.
function process(stream::TestAudioStream)
    in_array = zeros(AudioIO.AudioSample, stream.info.buf_size)
    out_array, _ = AudioIO.render(stream.mixer, in_array, stream.info)
    return out_array
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


info("Testing Playing Float64 arrays...")
f64 = convert(Array{Float64}, sin(phase))
test_stream = TestAudioStream()
player = play(f64, test_stream)
@test process(test_stream) == convert(AudioIO.AudioBuf, f64[1:TEST_BUF_SIZE])

info("Testing Playing Int8(Signed) arrays...")
i8 = Int8[-127:127]
test_stream = TestAudioStream()
player = play(i8, test_stream)
@test_approx_eq(process(test_stream)[1:255],
                   convert(AudioIO.AudioBuf, linspace(-1.0, 1.0, 255)))

info("Testing Playing Uint8(Unsigned) arrays...")
# for unsigned 8-bit audio silence is represented as 128, so the symmetric range
# is 1-255
ui8 = Uint8[1:255]
test_stream = TestAudioStream()
player = play(ui8, test_stream)
@test_approx_eq(process(test_stream)[1:255],
                   convert(AudioIO.AudioBuf, linspace(-1.0, 1.0, 255)))


info("Testing AudioNode Stopping...")
test_stream = TestAudioStream()
node = SinOsc(440)
@test !node.active
play(node, test_stream)
@test node.active
process(test_stream)
stop(node)
@test !node.active
# give the render task a chance to clean up
process(test_stream)
@test process(test_stream) == zeros(AudioIO.AudioSample, TEST_BUF_SIZE)

info("Testing libsndfile read")
samplerate = 44100
freq = 440
t = linspace(0, 2, 2 * samplerate)
phase = 2 * pi * freq * t
reference = int16((2 ^ 15 - 1) * sin(phase))

f = af_open("test/sinwave.flac")
@test f.sfinfo.channels == 1
@test f.sfinfo.frames == 2 * samplerate
actual = readFrames(f, 2 * samplerate)
@test_approx_eq(reference, actual)
