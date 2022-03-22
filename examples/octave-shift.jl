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

using PortAudio: PortAudioStream
using SampledSignals: Hz, domain
using SampledSignals: (..) # see EllipsisNotation.jl and IntervalSets.jl
using FFTW: fft, ifft
using Plots: plot, gui, default; default(label="")


function pitch_halver(x) # decrease pitch by one octave via FFT
    N = length(x)
    mod(N,2) == 0 || throw("N must be multiple of 2")
    F = fft(x) # original spectrum
    Fnew = [F[1:N÷2]; zeros(N+1); F[(N÷2+2):N]]
    out = 2 * real(ifft(Fnew))[1:N]
    out.samplerate /= 2 # trick!
    return out
end


# Plot input and output signals and their spectra.
# Quantize the vertical axis limits to reduce plot jitter.
function plotter(buf, out, N, fmin, fmax, fs; quant::Number = 0.1)
    bmax = quant * ceil(maximum(abs, buf) / quant)
    xticks = [1, N]; ylims = (-1,1) .* bmax; yticks = (-1:1)*bmax
    p1 = plot(buf; xticks, ylims, yticks, title="input")
    p3 = plot(out; xticks, ylims, yticks, title="output")

    X = (2/N) * abs.(fft(buf)[fmin..fmax]) # spectrum
    Xmax = quant * ceil(maximum(X) / quant)
    xlims = (fs[1], fs[end]); ylims = (0, Xmax); yticks = [0,Xmax]
    p2 = plot(fs, X; xlims, ylims, yticks)

    Y = (2/N) * abs.(fft(out)[fmin..fmax])
    p4 = plot(fs, Y; xlims, ylims, yticks)

    plot(p1, p2, p3, p4)
end


"""
    octave_shift(seconds; N, ...)

Shift audio down by one octave.

# Input
* `seconds` : how long to run in seconds; defaults to 300 (5 minutes)

# Options
* `N` : buffer size; default 1024 samples
* `fmin`,`fmax` : range of frequencies to display; default 0Hz to 4000Hz
"""
function octave_shift(
    seconds::Number = 300;
    N::Int = 1024,
    fmin::Number = 0Hz,
    fmax::Number = 4000Hz,
    # undocumented options below here that are unlikely to be modified
    in_stream = PortAudioStream(1, 0), # default input device
    out_stream = PortAudioStream(0, 1), # default output device
    buf::AbstractArray = read(in_stream, N), # warm-up
    fs = Float32[float(f) for f in domain(fft(buf)[fmin..fmax])],
    Niters::Int = ceil(Int, seconds * in_stream.sample_rate / N),
)

    for _ in 1:Niters
        read!(in_stream, buf)
        out = pitch_halver(buf) # decrease pitch by one octave
        write(out_stream, out)
        plotter(buf, out, N, fmin, fmax, fs); gui()
    end
    nothing
end

octave_shift(5)
