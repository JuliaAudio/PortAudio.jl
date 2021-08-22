# plot a real-time spectrogram. This example is adapted from the GR example
# at http://gr-framework.org/examples/audio_ex.html

module SpectrumExample

using GR, PortAudio, SampledSignals, FFTW

const N = 1024
const stream = PortAudioStream(1, 0)
const buf = read(stream, N)
const fmin = 0Hz
const fmax = 10000Hz
const fs = Float32[float(f+(fmin/oneunit(fmin)) for f in domain(fft(buf)[fmin..fmax])]

while true
    read!(stream, buf)
    plot(fs, abs.(fft(buf)[fmin..fmax]), xlim = (fs[1], fs[end]), ylim = (0, 100))
end

end
