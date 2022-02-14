# plot a real-time spectrogram. This example is adapted from the GR example
# at http://gr-framework.org/examples/audio_ex.html

using GR, PortAudio, SampledSignals, FFTW

function plot_spectrogram(seconds;
    N = 1024, 
    fmin = 0Hz,
    fmax = 10000Hz
)
    PortAudioStream(1, 0) do stream
        done = false
        buf = read(stream, N)
        fs = Float32[float(f) for f in domain(fft(buf)[fmin..fmax])]
        @sync begin
            @async while !done
                read!(stream, buf)
                plot(fs, abs.(fft(buf)[fmin..fmax]), xlim = (fs[1], fs[end]), ylim = (0, 100))
            end
            sleep(seconds)
            done = true
        end
    end
end

plot_spectrogram(5)
