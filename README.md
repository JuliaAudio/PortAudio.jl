AudioIO.jl
==========

[![Build Status](https://travis-ci.org/ssfrr/AudioIO.jl.png?branch=master)](https://travis-ci.org/ssfrr/AudioIO.jl)
[![Coverage Status](https://coveralls.io/repos/ssfrr/AudioIO.jl/badge.png?branch=master)](https://coveralls.io/r/ssfrr/AudioIO.jl?branch=master)

AudioIO interfaces to audio streams, including real-time recording, audio
processing, and playback through your sound card using PortAudio. It also
supports reading and writing audio files in a variety of formats. It is under
active development and the low-level API could change, but the basic
functionality (reading and writing files, the `play` function, etc.) should be
stable and usable by the general Julia community.

File I/O
--------

File I/O is handled by [libsndfile](http://www.mega-nerd.com/libsndfile/), so
we can support a wide variety of file and sample formats. Use the
`AudioIO.open` function to open a file. It has the same API as the built-in
Base.open, but returns an `AudioFile` type. Opening an audio file and reading
its contents into an array is as simple as:

```julia
f = AudioIO.open("data/never_gonna_give_you_up.wav")
data = read(f)
close(f)
```

Or to hand closing the file automatically (including in the case of unexpected
exceptions), we support the `do` block syntax:

```julia
data = AudioIO.open("data/never_gonna_let_you_down.wav") do f
    read(f)
end
```

By default the returned array will be in whatever format the original audio file is
(Float32, UInt16, etc.). We also support automatic conversion by supplying a type:

```julia
data = AudioIO.open("data/never_gonna_run_around.wav") do f
    read(f, Float32)
end
```

Basic Array Playback
--------------------

Arrays in various formats can be played through your soundcard. Currently the
native format that is delivered to the PortAudio backend is Float32 in the
range of [-1, 1]. Arrays in other sizes of float are converted. Arrays
in Signed or Unsigned Integer types are scaled so that the full range is
mapped to [-1, 1] floating point values.

To play a 1-second burst of noise:

```julia
julia> v = rand(44100) * 0.1
julia> play(v)
```

AudioNodes
----------

In addition to the basic `play` function you can create more complex networks
of AudioNodes in a render chain. In fact, when using the basic `play` to play
an Array, behind the scenes an instance of the ArrayPlayer type is created
and added to the master AudioMixer inputs. Audionodes also implement a `stop`
function, which will remove them from the render graph. When an implicit
AudioNode is created automatically, such as when using `play` on an Array, the
`play` function should return the audio node that is playing the Array, so it
can be stopped if desired.

To explictly do the same as above:

```julia
julia> v = rand(44100) * 0.1
julia> player = ArrayPlayer(v)
julia> play(player)
```

To generate 2 sin tones:

```julia
julia> osc1 = SinOsc(440)
julia> osc2 = SinOsc(660)
julia> play(osc1)
julia> play(osc2)
julia> stop(osc1)
julia> stop(osc2)
```

All AudioNodes must implement a `render` function that can be called to
retreive the next block of audio.

AudioStreams
------------

AudioStreams represent an external source or destination for audio, such as the
sound card. The `play` function attaches AudioNodes to the default stream
unless a stream is given as the 2nd argument.

AudioStream is an abstract type, which currently has a PortAudioStream subtype
that writes to the sound card, and a TestAudioStream that is used in the unit
tests.

Currently only 1 stream at a time is supported so there's no reason to provide
an explicit stream to the `play` function. The stream has a root mixer field
which is an instance of the AudioMixer type, so that multiple AudioNodes
can be heard at the same time. Whenever a new frame of audio is needed by the
sound card, the stream calls the `render` method on the root audio mixer, which
will in turn call the `render` methods on any input AudioNodes that are set
up as inputs.

Installation
------------

To install the latest release version, simply run

```julia
julia> Pkg.add("AudioIO")
```

If you want to install the lastest master, it's almost as easy:

```julia
julia> Pkg.clone("AudioIO")
julia> Pkg.build("AudioIO")
```

