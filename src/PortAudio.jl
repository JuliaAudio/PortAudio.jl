module PortAudio
using SampleTypes
using Compat
using FixedPointNumbers
using Devectorize
using RingBuffers

# Get binary dependencies loaded from BinDeps
include( "../deps/deps.jl")
include("libportaudio.jl")

export PortAudioSink, PortAudioSource

# initialize PortAudio on module load
Pa_Initialize()

type PortAudioDevice
    name::UTF8String
    host_api::UTF8String
    max_input_channels::Int
    max_output_channels::Int
    device_index::PaDeviceIndex
end

function devices()
    ndevices = Pa_GetDeviceCount()
    infos = PaDeviceInfo[Pa_GetDeviceInfo(i) for i in 0:(ndevices - 1)]

    [PortAudioDevice(bytestring(d.name),
                        bytestring(Pa_GetHostApiInfo(d.host_api).name),
                        d.max_input_channels,
                        d.max_output_channels,
                        i-1)
     for (i, d) in enumerate(infos)]
end

# paramaterized on the sample type and sampling rate type
type PortAudioSink{T, U} <: SampleSink
    stream::PaStream
    nchannels::Int
    samplerate::U
    bufsize::Int
    ringbuf::RingBuffer
    open::Bool
    task::Task

    function PortAudioSink(eltype, rate, channels, bufsize)
        stream = Pa_OpenDefaultStream(0, channels, type_to_fmt[eltype], float(rate), bufsize)
        writers = Condition[]
        # we want the ringbuf to output zeros to portaudio if it runs out of samples
        ringbuf = RingBuffer(eltype, RINGBUF_FRAMES, channels; underflow=PAD)
        Pa_StartStream(stream)

        this = new(stream, channels, rate, bufsize, ringbuf, true)
        this.task = @schedule sinktask(this)
        finalizer(this, close)
        yield()

        this
    end
end

PortAudioSink(eltype=Float32, rate=48000Hz, channels=2, bufsize=DEFAULT_BUFSIZE) =
    PortAudioSink{eltype, typeof(rate)}(eltype, rate, channels, bufsize)


const DEFAULT_BUFSIZE=4096
const RINGBUF_FRAMES = 131072

function Base.close(sink::PortAudioSink)
    sink.open = false
    # no task switches inside finalizer, not sure if we'll need this or not
    # wait(sink.task)
    Pa_StopStream(sink.stream)
    Pa_CloseStream(sink.stream)
end


SampleTypes.nchannels(sink::PortAudioSink) = sink.nchannels
SampleTypes.samplerate(sink::PortAudioSink) = sink.samplerate
Base.eltype{T, U}(sink::PortAudioSink{T, U}) = T

# type PortAudioSource <: SampleSource
#     stream::PaStream
# end

function SampleTypes.unsafe_write(sink::PortAudioSink, buf::SampleBuf)
    write(sink.ringbuf, buf)
end

# function SampleTypes.unsafe_read!(sink::PortAudioSource, buf::SampleBuf)
# end

function sinktask(sink::PortAudioSink)
    println("starting sink task")
    buffer = Array(eltype(sink), sink.bufsize, nchannels(sink))
    try
        while sink.open
            total = Pa_GetStreamWriteAvailable(sink.stream)
            written = 0
            while(written < total)
                tocopy = min(size(buffer, 1), total - written)
                read!(sink.ringbuf, sub(buffer, 1:tocopy, :))
                # TODO: this will only work for mono streams
                Pa_WriteStream(sink.stream, buffer, tocopy, true)
                written += tocopy
            end
            sleep(0.005)
        end
    catch ex
        warn("PortAudio Sink Task died with exception: $ex")
        Base.show_backtrace(STDOUT, catch_backtrace())
    end
    println("sink task finished")
end

# function sourcetask(sink::PortAudioSource)
#     while sink.open
#     end
#
#             while Pa_GetStreamReadAvailable(stream.stream) < n
#                 sleep(0.005)
#             end
#             Pa_ReadStream(stream.stream, buffer, n, stream.show_warnings)
#             # assume the root is always active
#             rendered = render(stream.root.renderer, buffer, stream.info)::AudioBuf
#             for i in 1:length(rendered)
#                 buffer[i] = rendered[i]
#             end
#             for i in (length(rendered)+1):n
#                 buffer[i] = 0.0
#             end
#             while Pa_GetStreamWriteAvailable(stream.stream) < n
#                 sleep(0.005)
#             end
#             Pa_WriteStream(stream.stream, buffer, n, stream.show_warnings)
# end


















# type Pa_AudioStream <: AudioStream
#     root::AudioMixer
#     info::DeviceInfo
#     show_warnings::Bool
#     stream::PaStream
#     sformat::PaSampleFormat
#     sbuffer::Array{Real}
#     sbuffer_output_waiting::Integer
#     parent_may_use_buffer::Bool
#
#     """
#         Get device parameters needed for opening with portaudio
#         default is input as 44100/16bit int, same as CD audio type input
#     """
#     function Pa_AudioStream(device_index, channels=2, input=false,
#                               sample_rate::Integer=44100,
#                               framesPerBuffer::Integer=2048,
#                               show_warnings::Bool=false,
#                               sample_format::PaSampleFormat=paInt16)
#         require_portaudio_init()
#         stream = Pa_OpenStream(device_index, channels, input, sample_format,
#                                Cdouble(sample_rate), Culong(framesPerBuffer))
#         Pa_StartStream(stream)
#         root = AudioMixer()
#         datatype = PaSampleFormat_to_T(sample_format)
#         sbuf = ones(datatype, framesPerBuffer)
#         this = new(root, DeviceInfo(sample_rate, framesPerBuffer),
#                    show_warnings, stream, sample_format, sbuf, 0, false)
#         info("Scheduling PortAudio Render Task...")
#         if input
#             @schedule(pa_input_task(this))
#         else
#             @schedule(pa_output_task(this))
#         end
#         this
#     end
# end
#
# """
# Blocking read from a Pa_AudioStream that is open as input
# """
# function read_Pa_AudioStream(stream::Pa_AudioStream)
#     while true
#         while stream.parent_may_use_buffer == false
#             sleep(0.001)
#         end
#         buffer = deepcopy(stream.sbuffer)
#         stream.parent_may_use_buffer = false
#         return buffer
#      end
# end
#
# """
# Blocking write to a Pa_AudioStream that is open for output
# """
# function write_Pa_AudioStream(stream::Pa_AudioStream, buffer)
#     retval = 1
#     sbufsize = length(stream.sbuffer)
#     inputlen = length(buffer)
#     if(inputlen > sbufsize)
#         info("Overflow at write_Pa_AudioStream")
#         retval = 0
#     elseif(inputlen < sbufsize)
#         info("Underflow at write_Pa_AudioStream")
#         retval = -1
#     end
#     while true
#         while stream.parent_may_use_buffer == false
#             sleep(0.001)
#         end
#         for idx in 1:min(sbufsize, inputlen)
#             stream.sbuffer[idx] = buffer[idx]
#         end
#         stream.parent_may_use_buffer = false
#     end
#     retval
# end
#
# ############ Internal Functions ############
#
# function portaudio_task(stream::PortAudioStream)
#     info("PortAudio Render Task Running...")
#     n = bufsize(stream)
#     buffer = zeros(AudioSample, n)
#     try
#         while true
#             while Pa_GetStreamReadAvailable(stream.stream) < n
#                 sleep(0.005)
#             end
#             Pa_ReadStream(stream.stream, buffer, n, stream.show_warnings)
#             # assume the root is always active
#             rendered = render(stream.root.renderer, buffer, stream.info)::AudioBuf
#             for i in 1:length(rendered)
#                 buffer[i] = rendered[i]
#             end
#             for i in (length(rendered)+1):n
#                 buffer[i] = 0.0
#             end
#             while Pa_GetStreamWriteAvailable(stream.stream) < n
#                 sleep(0.005)
#             end
#             Pa_WriteStream(stream.stream, buffer, n, stream.show_warnings)
#         end
#     catch ex
#         warn("Audio Task died with exception: $ex")
#         Base.show_backtrace(STDOUT, catch_backtrace())
#     end
# end
#
# """
#     Get input device data, pass as a producer, no rendering
# """
# function pa_input_task(stream::Pa_AudioStream)
#     info("PortAudio Input Task Running...")
#     n = bufsize(stream)
#     datatype = PaSampleFormat_to_T(stream.sformat)
#     # bigger ccall buffer to avoid overflow related errors
#     buffer = zeros(datatype, n * 8)
#     try
#         while true
#             while Pa_GetStreamReadAvailable(stream.stream) < n
#                 sleep(0.005)
#             end
#             while stream.parent_may_use_buffer
#                 sleep(0.005)
#             end
#             err = ccall((:Pa_ReadStream, libportaudio), PaError,
#                         (PaStream, Ptr{Void}, Culong),
#                         stream.stream, buffer, n)
#             handle_status(err, stream.show_warnings)
#             stream.sbuffer[1: n] = buffer[1: n]
#             stream.parent_may_use_buffer = true
#             sleep(0.005)
#         end
#     catch ex
#         warn("Audio Input Task died with exception: $ex")
#         Base.show_backtrace(STDOUT, catch_backtrace())
#     end
# end
#
# """
#     Send output device data, no rendering
# """
# function pa_output_task(stream::Pa_AudioStream)
#     info("PortAudio Output Task Running...")
#     n = bufsize(stream)
#     try
#         while true
#             navail = stream.sbuffer_output_waiting
#             if navail > n
#                 info("Possible output buffer overflow in stream")
#                 navail = n
#             end
#             if (navail > 1) & (stream.parent_may_use_buffer == false) &
#                (Pa_GetStreamWriteAvailable(stream.stream) < navail)
#                 Pa_WriteStream(stream.stream, stream.sbuffer,
#                                navail, stream.show_warnings)
#                 stream.parent_may_use_buffer = true
#             else
#                 sleep(0.005)
#             end
#         end
#     catch ex
#         warn("Audio Output Task died with exception: $ex")
#         Base.show_backtrace(STDOUT, catch_backtrace())
#     end
# end

end # module PortAudio
