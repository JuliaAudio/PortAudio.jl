using Makie, GeometryTypes
using PortAudio

N = 1024 # size of audio read
N2 = N÷2+1 # size of rfft output
D = 200 # number of bins to display
M = 100 # number of lines to draw
S = 0.5 # motion speed of lines
src = PortAudioStream(1, 2, blocksize=N)
buf = Array{Float32}(N)
fftbuf = Array{Complex{Float32}}(N2)
magbuf = Array{Float32}(N2)
fftplan = plan_rfft(buf; flags=FFTW.EXHAUSTIVE)

scene = Scene(resolution=(500,500))
ax = axis(0:0.1:1, 0:0.1:1, 0:0.1:0.5)
center!(scene)

ls = map(1:M) do _
    yoffset = to_node(to_value(scene[:time]))
    offset = lift_node(scene[:time], yoffset) do t, yoff
        Point3f0(0.0f0, (t-yoff)*S, 0.0f0)
    end
    l = lines(linspace(0,1,D), 0.0f0, zeros(Float32, D),
        offset=offset, color=(:black, 0.1))
    (yoffset, l)
end

while isopen(scene[:screen])
    for (yoffset, line) in ls
        isopen(scene[:screen]) || break
        read!(src, buf)
        A_mul_B!(fftbuf, fftplan, buf)
        @. magbuf = log(clamp(abs(fftbuf), 0.0001, Inf))/10+0.5
        line[:z] = magbuf[1:D]
        push!(yoffset, to_value(scene[:time]))
    end
end
