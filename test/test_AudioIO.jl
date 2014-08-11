module TestAudioIO

using FactCheck
using AudioIO
import AudioIO.AudioBuf

const TEST_SAMPLERATE = 44100
const TEST_BUF_SIZE = 1024

include("testhelpers.jl")


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

facts("Array playback") do
    # data shared between tests, for convenience
    t = linspace(0, 2, 2 * 44100)
    phase = 2pi * 100 * t

    ## Test Float32 arrays, this is currently the native audio playback format
    context("Playing Float32 arrays") do
        f32 = convert(Array{Float32}, sin(phase))
        test_stream = TestAudioStream()
        player = play(f32, test_stream)
        @fact process(test_stream) => f32[1:TEST_BUF_SIZE]
    end

    context("Playing Float64 arrays") do
        f64 = convert(Array{Float64}, sin(phase))
        test_stream = TestAudioStream()
        player = play(f64, test_stream)
        @fact process(test_stream) => convert(AudioBuf, f64[1:TEST_BUF_SIZE])
    end

    context("Playing Int8(Signed) arrays") do
        i8 = Int8[-127:127]
        test_stream = TestAudioStream()
        player = play(i8, test_stream)
        @fact process(test_stream)[1:255] =>
                mse(convert(AudioBuf, linspace(-1.0, 1.0, 255)))
    end

    context("Playing Uint8(Unsigned) arrays") do
        # for unsigned 8-bit audio silence is represented as 128, so the symmetric range
        # is 1-255
        ui8 = Uint8[1:255]
        test_stream = TestAudioStream()
        player = play(ui8, test_stream)
        @fact process(test_stream)[1:255] =>
                mse(convert(AudioBuf, linspace(-1.0, 1.0, 255)))
   end
end

facts("AudioNode Stopping") do
    test_stream = TestAudioStream()
    node = SinOsc(440)
    play(node, test_stream)
    process(test_stream)
    stop(node)
    @fact process(test_stream) => zeros(AudioIO.AudioSample, TEST_BUF_SIZE)
end

facts("Audio Device Listing") do
    # there aren't any devices on the Travis machine so just test that this doesn't crash
    @fact get_audio_devices() => issubtype(Array)
end

end # module TestAudioIO
