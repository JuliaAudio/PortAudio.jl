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

end # module TestSndfile
