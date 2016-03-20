PortAudio.jl
============

[![Build Status](https://travis-ci.org/JuliaAudio/PortAudio.jl.svg?branch=master)](https://travis-ci.org/JuliaAudio/PortAudio.jl)
[![codecov.io] (http://codecov.io/github/JuliaAudio/PortAudio.jl/coverage.svg?branch=master)] (http://codecov.io/github/JuliaAudio/PortAudio.jl?branch=master)

PortAudio.jl is a wrapper for [libportaudio](http://www.portaudio.com/), which gives cross-platform access to audio devices. It is compatible with the types defined in [SampleTypes.jl](https://github.com/JuliaAudio/SampleTypes.jl), so it provides `PortAudioSink` and `PortAudioSource` types, which can be read from and written to.

## Examples

### Set up an audio pass-through from microphone to speaker

```julia
src = PortAudioSource()
sink = PortAudioSink()
write(sink, source)
end
```
