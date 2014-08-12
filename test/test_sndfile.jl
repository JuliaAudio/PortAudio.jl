module TestSndfile

include("testhelpers.jl")

using AudioIO
using FactCheck
import AudioIO: DeviceInfo, render, AudioSample, AudioBuf

facts("WAV file write/read") do
    fname = Pkg.dir("AudioIO", "test", "sinwave.wav")

    samplerate = 44100
    freq = 440
    t = [0 : 2 * samplerate - 1] / samplerate
    phase = 2 * pi * freq * t
    reference = int16((2 ^ 15 - 1) * sin(phase))

    AudioIO.open(fname, "w") do f
        write(f, reference)
    end

    # test basic reading
    AudioIO.open(fname) do f
        @fact f.sfinfo.channels => 1
        @fact f.sfinfo.frames => 2 * samplerate
        actual = read(f)
        @fact length(reference) => length(actual)
        @fact reference => actual[:, 1]
    end

    # test seeking

    # test rendering as an AudioNode
    AudioIO.open(fname) do f
        # pretend we have a stream at the same rate as the file
        bufsize = 1024
        input = zeros(AudioSample, bufsize)
        test_info = DeviceInfo(samplerate, bufsize)
        node = FilePlayer(f)
        # convert to floating point because that's what AudioIO uses natively
        expected = convert(AudioBuf, reference ./ (2^15))
        buf = render(node, input, test_info)
        @fact expected[1:bufsize] => buf[1:bufsize]
        buf = render(node, input, test_info)
        @fact expected[bufsize+1:2*bufsize] => buf[1:bufsize]
    end
end

facts("Stereo file reading") do
    fname = Pkg.dir("AudioIO", "test", "440left_880right.wav")
    samplerate = 44100
    t = [0 : 2 * samplerate - 1] / samplerate
    expected = int16((2^15-1) * hcat(sin(2pi*t*440), sin(2pi*t*880)))

    AudioIO.open(fname) do f
        buf = read(f)
        @fact buf => mse(expected, 5)
    end
end

# note - currently AudioIO just mixes down to Mono. soon we'll support this
# new-fangled stereo sound stuff
#facts("Stereo file rendering") do
#    fname = Pkg.dir("AudioIO", "test", "440left_880right.wav")
#    samplerate = 44100
#    bufsize = 1024
#    input = zeros(AudioSample, bufsize)
#    test_info = DeviceInfo(samplerate, bufsize)
#    t = [0 : 2 * samplerate - 1] / samplerate
#    expected = convert(AudioBuf, 0.5 * (sin(2pi*t*440) + sin(2pi*t*880)))
#
#    AudioIO.open(fname) do f
#        node = FilePlayer(f)
#        buf = render(node, input, test_info)
#        print(size(buf))
#        @fact expected[1:bufsize] => buf[1:bufsize]
#        buf = render(node, input, test_info)
#        @fact expected[bufsize+1:2*bufsize] => buf[1:bufsize]
#    end
#end

end # module TestSndfile
