using Makie
using PortAudio
using DSP

"""
Slide the values in the given matrix to the right by 1.
The rightmosts column is discarded and the leftmost column is
left alone.
"""
function shift1!(buf::AbstractMatrix)
    for col in size(buf,2):-1:2
        @. buf[:, col] = buf[:, col-1]
    end
end

"""
takes a block of audio, FFT it, and write it to the beginning of the buffer
"""
function processbuf!(readbuf, win, dispbuf, fftbuf, fftplan)
    readbuf .*= win
    A_mul_B!(fftbuf, fftplan, readbuf)
    shift1!(dispbuf)
    @. dispbuf[end:-1:1,1] = log(clamp(abs(fftbuf[1:D]), 0.0001, Inf))
end

function processblock!(src, buf, win, dispbufs, fftbuf, fftplan)
    read!(src, buf)
    for dispbuf in dispbufs
        processbuf!(buf, win, dispbuf, fftbuf, fftplan)
    end
end

N = 1024 # size of audio read
N2 = N÷2+1 # size of rfft output
D = 200 # number of bins to display
M = 200 # amount of history to keep
src = PortAudioStream(1, 2, blocksize=N)
buf = Array{Float32}(N) # buffer for reading
fftplan = plan_rfft(buf; flags=FFTW.EXHAUSTIVE)
fftbuf = Array{Complex{Float32}}(N2) # destination buf for FFT
dispbufs = [zeros(Float32, D, M) for i in 1:5, j in 1:5] # STFT bufs
win = gaussian(N, 0.125)

scene = Scene(resolution=(1000,1000))

#pre-fill the display buffer so we can do a reasonable colormap
for _ in 1:M
    processblock!(src, buf, win, dispbufs, fftbuf, fftplan)
end

heatmaps = map(enumerate(IndexCartesian(), dispbufs)) do ibuf
    i = ibuf[1]
    buf = ibuf[2]

    # some function of the 2D index and the value
    heatmap(buf, offset=(i[2]*size(buf, 2), i[1]*size(buf, 1)))
end

center!(scene)

while isopen(scene[:screen])
    processblock!(src, buf, dispbufs, fftbuf, fftplan)
    for (hm, db) in zip(heatmaps, dispbufs)
        hm[:heatmap] = db
    end
    render_frame(scene)
end
