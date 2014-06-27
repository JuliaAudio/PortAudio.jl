using Base.Test
using AudioIO
import AudioIO.AudioBuf

const TEST_SAMPLERATE = 44100
const TEST_BUF_SIZE = 1024

type TestAudioStream <: AudioIO.AudioStream
    root::AudioIO.AudioMixer
    info::AudioIO.DeviceInfo

    function TestAudioStream()
        root = AudioMixer()
        new(root, AudioIO.DeviceInfo(TEST_SAMPLERATE, TEST_BUF_SIZE))
    end
end

# render the stream and return the next block of audio. This is used in testing
# to simulate the audio callback that's normally called by the device.
function process(stream::TestAudioStream)
    out_array = zeros(AudioIO.AudioSample, stream.info.buf_size)
    in_array = zeros(AudioIO.AudioSample, stream.info.buf_size)
    rendered = AudioIO.render(stream.root, in_array, stream.info)
    out_array[1:length(rendered)] = rendered
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
@test process(test_stream) == convert(AudioBuf, f64[1:TEST_BUF_SIZE])

info("Testing Playing Int8(Signed) arrays...")
i8 = Int8[-127:127]
test_stream = TestAudioStream()
player = play(i8, test_stream)
@test_approx_eq(process(test_stream)[1:255],
                   convert(AudioBuf, linspace(-1.0, 1.0, 255)))

info("Testing Playing Uint8(Unsigned) arrays...")
# for unsigned 8-bit audio silence is represented as 128, so the symmetric range
# is 1-255
ui8 = Uint8[1:255]
test_stream = TestAudioStream()
player = play(ui8, test_stream)
@test_approx_eq(process(test_stream)[1:255],
                   convert(AudioBuf, linspace(-1.0, 1.0, 255)))

info("Testing AudioNode Stopping...")
test_stream = TestAudioStream()
node = SinOsc(440)
play(node, test_stream)
process(test_stream)
stop(node)
@test process(test_stream) == zeros(AudioIO.AudioSample, TEST_BUF_SIZE)

info("Testing wav file write/read")

fname = "test/sinwave.wav"

samplerate = 44100
freq = 440
t = [0 : 2 * samplerate - 1] / samplerate
phase = 2 * pi * freq * t
reference = int16((2 ^ 15 - 1) * sin(phase))

af_open(fname, "w") do f
    write(f, reference)
end

af_open(fname) do f
    @test f.sfinfo.channels == 1
    @test f.sfinfo.frames == 2 * samplerate
    actual = read(f, 2 * samplerate)
    @test_approx_eq(reference, actual)
end

info("Testing Audio Device Listing...")
# there aren't any devices on the Travis machine so just test that this doesn't crash
get_audio_devices()
