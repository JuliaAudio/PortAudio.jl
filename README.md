AudioIO.jl
==========

[![Build Status](https://travis-ci.org/ssfrr/AudioIO.jl.png)](https://travis-ci.org/ssfrr/AudioIO.jl)

AudioIO is a Julia library for interfacing to audio streams, which include
playing to and recording from sound cards, reading and writing audio files,
sending to network audio streams, etc. Currently only playing to the sound card
through PortAudio is supported. It is under heavy development, so the API could
change, there will be bugs, there are important missing features.

If you want to try it anyways, from your julia console:

    julia> Pkg.clone("https://github.com/ssfrr/AudioIO.jl.git")
    julia> Pkg.build("AudioIO")

Basic Array Playback
--------------------

Arrays in various formats can be played through your soundcard. Currently the
native format that is delivered to the PortAudio backend is Float32 in the
range of [-1, 1]. Arrays in other sizes of float are converted. Arrays
in Signed or Unsigned Integer types are scaled so that the full range is
mapped to [-1, 1] floating point values.

To play a 1-second burst of noise:

    julia> v = rand(44100) * 0.1
    julia> play(v)

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

    julia> v = rand(44100) * 0.1
    julia> player = ArrayPlayer(v)
    julia> play(player)

To generate 2 sin tones:

    julia> osc1 = SinOsc(440)
    julia> osc2 = SinOsc(660)
    julia> play(osc1)
    julia> play(osc2)
    julia> stop(osc1)
    julia> stop(osc2)

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
