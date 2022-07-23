# precompile some important functions
const DEFAULT_SINK_MESSENGER_TYPE = Messenger{Float32, SampledSignalsWriter, Tuple{Matrix{Float32}, Int64, Int64}, Int64}
const DEFAULT_SOURCE_MESSENGER_TYPE = Messenger{Float32, SampledSignalsReader, Tuple{Matrix{Float32}, Int64, Int64}, Int64}
const DEFAULT_STREAM_TYPE = PortAudioStream{DEFAULT_SINK_MESSENGER_TYPE, DEFAULT_SOURCE_MESSENGER_TYPE}
const DEFAULT_SINK_TYPE = PortAudioSink{DEFAULT_SINK_MESSENGER_TYPE, DEFAULT_SOURCE_MESSENGER_TYPE}
const DEFAULT_SOURCE_TYPE = PortAudioSource{DEFAULT_SINK_MESSENGER_TYPE, DEFAULT_SOURCE_MESSENGER_TYPE}

precompile(close, (DEFAULT_STREAM_TYPE,))
precompile(devices, ())
precompile(__init__, ())
precompile(isopen, (DEFAULT_STREAM_TYPE,))
precompile(nchannels, (DEFAULT_SINK_TYPE,))
precompile(nchannels, (DEFAULT_SOURCE_TYPE,))
precompile(PortAudioStream, (Int, Int))
precompile(PortAudioStream, (String, Int, Int))
precompile(PortAudioStream, (String, String, Int, Int))
precompile(samplerate, (DEFAULT_STREAM_TYPE,))
precompile(send, (DEFAULT_SINK_MESSENGER_TYPE,))
precompile(send, (DEFAULT_SOURCE_MESSENGER_TYPE,))
precompile(unsafe_read!, (DEFAULT_SOURCE_TYPE, Vector{Float32}, Int, Int))
precompile(unsafe_read!, (DEFAULT_SOURCE_TYPE, Matrix{Float32}, Int, Int))
precompile(unsafe_write, (DEFAULT_SINK_TYPE, Vector{Float32}, Int, Int))
precompile(unsafe_write, (DEFAULT_SINK_TYPE, Matrix{Float32}, Int, Int))






