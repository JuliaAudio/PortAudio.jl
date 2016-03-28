# plot a real-time spectrogram. This example is adapted from the GR example
# at http://gr-framework.org/examples/audio_ex.html

module SpectrumExample

using GR, PortAudio, SampleTypes

const N = 1024
const stream = PortAudioStream(1, 1, bufsize=N)
const buf = read(stream, N)
const fmin = 0Hz
const fmax = 10000Hz
const fs = Float32[float(f) for f in domain(fft(buf)[fmin..fmax])]

setwindow(fs[1], fs[end], 0, 100)
setviewport(0.05, 0.95, 0.05, 0.95)
setlinecolorind(218)
setfillintstyle(1)
setfillcolorind(208)
setscale(GR.OPTION_X_LOG)

while true
    read!(stream, buf)
    clearws()
    fillrect(fs[1], fs[end], 0, 100)
    polyline(fs, abs(fft(buf)[fmin..fmax]))
    updatews()
end

end
