PortAudio.jl
============

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaAudio.github.io/PortAudio.jl/dev)
[![Tests](https://github.com/JuliaAudio/PortAudio.jl/actions/workflows/Tests.yml/badge.svg)](https://github.com/JuliaAudio/PortAudio.jl/actions/workflows/Tests.yml)
[![codecov](https://codecov.io/gh/JuliaAudio/PortAudio.jl/branch/master/graph/badge.svg?token=mgDAi8ulPY)](https://codecov.io/gh/JuliaAudio/PortAudio.jl)

PortAudio.jl is a wrapper for [libportaudio](http://www.portaudio.com/), which gives cross-platform access to audio devices. 
It provides a `PortAudioStream` type, which can be read from and written to.

## Debugging

If you are experiencing issues and wish to view detailed logging and debug information, set

```
ENV["JULIA_DEBUG"] = :PortAudio
```

before using the package.
