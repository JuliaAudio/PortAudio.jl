PortAudio.jl
============

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaAudio.github.io/PortAudio.jl/dev)
[![Tests](https://github.com/JuliaAudio/PortAudio.jl/actions/workflows/Tests.yml/badge.svg)](https://github.com/JuliaAudio/PortAudio.jl/actions/workflows/Tests.yml)
[![codecov](https://codecov.io/gh/JuliaAudio/PortAudio.jl/branch/master/graph/badge.svg?token=mgDAi8ulPY)](https://codecov.io/gh/JuliaAudio/PortAudio.jl)


PortAudio.jl is a wrapper for [libportaudio](http://www.portaudio.com/), which gives cross-platform access to audio devices. It is compatible with the types defined in [SampledSignals.jl](https://github.com/JuliaAudio/SampledSignals.jl). It provides a `PortAudioStream` type, which can be read from and written to.

## Opening a stream

The easiest way to open a source or sink is with the default `PortAudioStream()` constructor, 
which will open a 2-in, 2-out stream to your system's default device(s).
The constructor can also take the input and output channel counts as positional arguments,
or a variety of other keyword arguments.
If named keyword arguments `latency` or `samplerate` are unspecified, then PortAudio will use device defaults.

```julia
PortAudioStream(inchans=2, outchans=2; eltype=Float32, samplerate=48000, latency=0.1)
```

You can open a specific device by adding it as the first argument, either as a `PortAudioDevice` instance or by name. You can also give separate names or devices if you want different input and output devices

```julia
PortAudioStream(device::PortAudioDevice, args...; kwargs...)
PortAudioStream(devname::AbstractString, args...; kwargs...)
```

You can get a list of your system's devices with the `PortAudio.devices()` function:

```julia
julia> PortAudio.devices()
14-element Vector{PortAudio.PortAudioDevice}:
 "sof-hda-dsp: - (hw:0,0)" 2→2
 "sof-hda-dsp: - (hw:0,3)" 0→2
 "sof-hda-dsp: - (hw:0,4)" 0→2
 "sof-hda-dsp: - (hw:0,5)" 0→2
 ⋮
 "upmix" 8→8
 "vdownmix" 6→6
 "dmix" 0→2
 "default" 32→32
```

## Reading and Writing

The `PortAudioStream` type has `source` and `sink` fields which are of type `PortAudioSource <: SampleSource` and `PortAudioSink <: SampleSink`, respectively. are subtypes of `SampleSource` and `SampleSink`, respectively (from [SampledSignals.jl](https://github.com/JuliaAudio/SampledSignals.jl)). This means they support all the stream and buffer features defined there. For example, if you load SampledSignals with `using SampledSignals` you can read 5 seconds to a buffer with `buf = read(stream.source, 5s)`, regardless of the sample rate of the device.

PortAudio.jl also provides convenience wrappers around the `PortAudioStream` type so you can read and write to it directly, e.g. `write(stream, stream)` will set up a loopback that will read from the input and play it back on the output.

## Debugging

If you are experiencing issues and wish to view detailed logging and debug information, set

```
ENV["JULIA_DEBUG"] = :PortAudio
```

before using the package.

## Examples

### Set up an audio pass-through from microphone to speaker

```julia
stream = PortAudioStream(2, 2)
try
    # cancel with Ctrl-C
    write(stream, stream)
finally
    close(stream)
end
```

### Use `do` syntax to auto-close the stream
```julia
PortAudioStream(2, 2) do stream
    write(stream, stream)
end
```

### Open your built-in microphone and speaker by name
```julia
PortAudioStream("default", "default") do stream
    write(stream, stream)
end
```

### Record 10 seconds of audio and save to an ogg file

```julia
julia> import LibSndFile # must be in Manifest for FileIO.save to work

julia> using PortAudio: PortAudioStream

julia> using SampledSignals: s

julia> using FileIO: save

julia> stream = PortAudioStream(1, 0) # default input (e.g., built-in microphone)
PortAudioStream{Float32}
  Samplerate: 44100.0Hz
  2 channel source: "default"

julia> buf = read(stream, 10s)
480000-frame, 2-channel SampleBuf{Float32, 2, SIUnits.SIQuantity{Int64,0,0,-1,0,0,0,0,0,0}}
10.0 s at 48000 s⁻¹
▁▄▂▃▅▃▂▄▃▂▂▁▁▂▂▁▁▄▃▁▁▄▂▁▁▁▄▃▁▁▃▃▁▁▁▁▁▁▁▁▄▄▄▄▄▂▂▂▁▃▃▁▃▄▂▁▁▁▁▃▃▂▁▁▁▁▁▁▃▃▂▂▁▃▃▃▁▁▁▁
▁▄▂▃▅▃▂▄▃▂▂▁▁▂▂▁▁▄▃▁▁▄▂▁▁▁▄▃▁▁▃▃▁▁▁▁▁▁▁▁▄▄▄▄▄▂▂▂▁▃▃▁▃▄▂▁▁▁▁▃▃▂▁▁▁▁▁▁▃▃▂▂▁▃▃▃▁▁▁▁

julia> close(stream)

julia> save(joinpath(homedir(), "Desktop", "myvoice.ogg"), buf)
```

### Play an audio signal through the default sound output device

```julia
using PortAudio, SampledSignals
S = 8192 # sampling rate (samples / second)
x = cos.(2pi*(1:2S)*440/S) # A440 tone for 2 seconds
PortAudioStream(0, 2; samplerate=S) do stream
    write(stream, x)
end
```
