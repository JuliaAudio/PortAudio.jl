PortAudio.jl
============

PortAudio.jl is a wrapper for [libportaudio](http://www.portaudio.com/), which gives cross-platform access to audio devices. It is compatible with the types defined in [SampleTypes.jl](https://github.com/JuliaAudio/SampleTypes.jl), so it provides `PortAudioSink` and `PortAudioSource` types, which can be read from and written to.

## Opening a source or sink

The easiest way to open a source or sink is with the default `PortAudioSource()` and `PortAudioSink()` constructors, which will open a 2-channel stream to your system's default devices. The constructors also take a variety of positional arguments:

```julia
PortAudioSink(eltype=Float32, sr=48000Hz, channels=2, bufsize=4096)
```

You can open a specific device by adding it as the first argument, either as a `PortAudioDevice` instance or by name.

```julia
PortAudioSink(device::PortAudioDevice, args...)
PortAudioSink(devname::AbstractString, args...)
```

You can get a list of your system's devices with the `PortAudio.devices()` function:

```julia
julia> PortAudio.devices()
6-element Array{PortAudio.PortAudioDevice,1}:
 PortAudio.PortAudioDevice("AirPlay","Core Audio",0,2,0)
 PortAudio.PortAudioDevice("Built-in Microph","Core Audio",2,0,1)
 PortAudio.PortAudioDevice("Built-in Output","Core Audio",0,2,2)
 PortAudio.PortAudioDevice("JackRouter","Core Audio",2,2,3)
 PortAudio.PortAudioDevice("After Effects 13.5","Core Audio",0,0,4)
 PortAudio.PortAudioDevice("Built-In Aggregate","Core Audio",2,2,5)
```

## Reading and Writing

`PortAudioSource` and `PortAudioSink` are subtypes of `SampleSource` and `SampleSink`, respectively (from [SampleTypes.jl](https://github.com/JuliaAudio/SampleTypes.jl)). This means they support all the stream and buffer features defined there. For example, if you load SampleTypes with `using SampleTypes` you can read 5 seconds to a buffer with `buf = read(source, 5s)`, regardless of the sample rate of the device.

## Examples

### Set up an audio pass-through from microphone to speaker

```julia
source = PortAudioSource()
sink = PortAudioSink()
write(sink, source)
```

### Open your built-in microphone and speaker by name
```julia
source = PortAudioSource("Built-in Microph")
sink = PortAudioSink("Built-in Output")
write(sink, source)
```

### Record 10 seconds of audio and save to an ogg file

```julia
julia> using PortAudio, FileIO, SampleTypes, LibSndFile

julia> source = PortAudioSource("Built-in Microph")
PortAudio.PortAudioSource{Float32,SIUnits.SIQuantity{Int64,0,0,-1,0,0,0,0,0,0}}("Built-in Microph")
2 channels sampled at 48000 s⁻¹

julia> buf = read(source, 10s)
480000-frame, 2-channel SampleBuf{Float32, 2, SIUnits.SIQuantity{Int64,0,0,-1,0,0,0,0,0,0}}
10.0 s at 48000 s⁻¹
▁▄▂▃▅▃▂▄▃▂▂▁▁▂▂▁▁▄▃▁▁▄▂▁▁▁▄▃▁▁▃▃▁▁▁▁▁▁▁▁▄▄▄▄▄▂▂▂▁▃▃▁▃▄▂▁▁▁▁▃▃▂▁▁▁▁▁▁▃▃▂▂▁▃▃▃▁▁▁▁
▁▄▂▃▅▃▂▄▃▂▂▁▁▂▂▁▁▄▃▁▁▄▂▁▁▁▄▃▁▁▃▃▁▁▁▁▁▁▁▁▄▄▄▄▄▂▂▂▁▃▃▁▃▄▂▁▁▁▁▃▃▂▁▁▁▁▁▁▃▃▂▂▁▃▃▃▁▁▁▁

julia> save(joinpath(homedir(), "Desktop", "myvoice.ogg"), buf)
```
