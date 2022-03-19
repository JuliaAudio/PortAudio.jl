#=
This code illustrates real-time octave down shift
using a crude FFT-based method.
It also plots the input and output signals and their spectra.

This code uses the system defaults for the audio input and output devices.
If you use the built-in speakers and built-in microphone,
you will likely get undesirable audio feedback.

It works "best" if you play the audio output through headphones
so that the output does not feed back into the input.

The spectrum plotting came from the example in
https://github.com/JuliaAudio/PortAudio.jl/blob/master/examples
=#

using PortAudio, SampledSignals, FFTW
using Plots; default(label="")

function pitch_halver(x) # decrease pitch by one octave via FFT
    N = length(x)
    mod(N,2) == 0 || throw("N must be multiple of 2")
    F = fft(x) # original spectrum
    Fnew = [F[1:N÷2]; zeros(N+1); F[(N÷2+2):N]]
    out = 2 * real(ifft(Fnew))[1:N]
    out.samplerate /= 2 # trick!
    return out
end

const N = 1024 # buffer size
const in_stream = PortAudioStream(1, 0) # default input device
const out_stream = PortAudioStream(0, 1) # default output device
const buf = read(in_stream, N) # warm-up
const fmin = 0Hz
const fmax = 4000Hz
const fs = Float32[float(f) for f in domain(fft(buf)[fmin..fmax])]

while true
    read!(in_stream, buf)
    out = pitch_halver(buf) # decrease pitch by one octave
    write(out_stream, out)

    bmax = 0.1 * ceil(maximum(abs, buf) / 0.1)
    xticks = [1, N]; ylims = (-1,1) .* bmax; yticks = (-1:1)*bmax
    p1 = plot(buf; xticks, ylims, yticks, title="input")
    p3 = plot(out; xticks, ylims, yticks, title="output")

    X = abs.(fft(buf)[fmin..fmax]) # spectrum
    Xmax = 10 * ceil(maximum(X) / 10)
    xlims = (fs[1], fs[end]); ylims = (0, Xmax); yticks = [0,Xmax]
    p2 = plot(fs, X; xlims, ylims, yticks)

    Y = abs.(fft(out)[fmin..fmax])
    p4 = plot(fs, Y; xlims, ylims, yticks)

    plot(p1, p2, p3, p4); gui()
end
