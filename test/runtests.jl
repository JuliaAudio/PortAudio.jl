#!/usr/bin/env julia

using Logging: Debug
using PortAudio:
    combine_default_sample_rates,
    devices,
    get_default_input_device,
    get_default_output_device,
    get_device_info,
    handle_status,
    initialize,
    paOutputUnderflowed,
    PortAudio,
    PortAudioDevice,
    PortAudioStream,
    recover_xrun,
    safe_load,
    seek_alsa_conf,
    @stderr_as_debug,
    terminate
using PortAudio.LibPortAudio:
    Pa_AbortStream,
    PaError,
    PaErrorCode,
    paFloat32,
    Pa_GetDefaultHostApi,
    Pa_GetHostApiCount,
    Pa_GetLastHostErrorInfo,
    Pa_GetSampleSize,
    Pa_GetStreamCpuLoad,
    Pa_GetStreamInfo,
    Pa_GetStreamTime,
    Pa_HostApiDeviceIndexToDeviceIndex,
    paHostApiNotFound,
    Pa_HostApiTypeIdToHostApiIndex,
    PaHostErrorInfo,
    paInDevelopment,
    paInvalidDevice,
    Pa_IsFormatSupported,
    Pa_IsStreamActive,
    Pa_IsStreamStopped,
    paNoError,
    paNoFlag,
    paNotInitialized,
    Pa_OpenDefaultStream,
    Pa_SetStreamFinishedCallback,
    Pa_Sleep,
    PaStream,
    PaStreamInfo,
    PaStreamParameters
using SampledSignals: nchannels, s, SampleBuf, samplerate, SinSource
using Test: @test, @test_logs, @test_nowarn, @testset, @test_throws

@testset "Debug messages" begin
    @test_logs (:debug, "hi") min_level = Debug @test_nowarn @stderr_as_debug begin
        print(stderr, "hi")
        true
    end
end

@testset "PortAudio Tests" begin
    @testset "Reports version" begin
        io = IOBuffer()
        PortAudio.versioninfo(io)
        result = split(String(take!((io))), "\n")
        # make sure this is the same version I tested with
        @test startswith(result[1], "PortAudio V19")
    end

    @testset "Can list devices without crashing" begin
        devices()
    end

    @testset "Null errors" begin
        @test_throws BoundsError get_device_info(-1)
    end
end

if !isempty(devices())
    # make sure we can terminate, then reinitialize
    terminate()
    initialize()

    @testset "libportaudio" begin
        @test handle_status(Pa_GetHostApiCount()) >= 0
        @test handle_status(Pa_GetDefaultHostApi()) >= 0
        @test PaErrorCode(Pa_HostApiTypeIdToHostApiIndex(paInDevelopment)) ==
                     paHostApiNotFound
        @test Pa_HostApiDeviceIndexToDeviceIndex(paInDevelopment, 0) == 0
        @test safe_load(Pa_GetLastHostErrorInfo(), ErrorException("no info")) isa PaHostErrorInfo
        @test PaErrorCode(Pa_IsFormatSupported(C_NULL, C_NULL, 0.0)) == paInvalidDevice
        @test PaErrorCode(
            Pa_OpenDefaultStream(Ref(C_NULL), 0, 0, paFloat32, 0.0, 0, C_NULL, C_NULL),
        ) == paInvalidDevice
        stream = PortAudioStream(2, 2)
        pointer = stream.pointer_ref[]
        @test !(Bool(handle_status(Pa_IsStreamStopped(pointer))))
        @test Bool(handle_status(Pa_IsStreamActive(pointer)))
        @test safe_load(Pa_GetStreamInfo(pointer), ErrorException("no info")) isa
              PaStreamInfo
        @test Pa_GetStreamTime(pointer) >= 0
        @test Pa_GetStreamCpuLoad(pointer) >= 0
        @test PaErrorCode(handle_status(Pa_AbortStream(pointer))) == paNoError
        @test PaErrorCode(handle_status(Pa_SetStreamFinishedCallback(pointer, C_NULL))) ==
              paNoError
        Pa_Sleep(1)
        @test Pa_GetSampleSize(paFloat32) == 4
    end

    # these default values are specific to my machines
    inidx = get_default_input_device()
    default_indev = PortAudioDevice(get_device_info(inidx), inidx).name
    outidx = get_default_output_device()
    default_outdev = PortAudioDevice(get_device_info(outidx), outidx).name

    @testset "Local Tests" begin
        @testset "Open Default Device" begin
            println("Recording...")
            stream = PortAudioStream(2, 0)
            buf = read(stream, 5s)
            close(stream)
            @test size(buf) ==
                  (round(Int, 5 * samplerate(stream)), nchannels(stream.source))
            println("Playing back recording...")
            PortAudioStream(0, 2) do stream
                write(stream, buf)
            end
            println("Testing pass-through")
            stream = PortAudioStream(2, 2)
            sink = stream.sink
            source = stream.source
            @test sprint(show, sink) == "2 channel sink: $(repr(default_indev))"
            @test sprint(show, source) == "2 channel source: $(repr(default_outdev))"
            write(stream, stream, 5s)
            recover_xrun(stream)
            @test_throws ErrorException("""
                Attempted to close PortAudioSink or PortAudioSource.
                Close the containing PortAudioStream instead
                """) close(sink)
            @test_throws ErrorException("""
                Attempted to close PortAudioSink or PortAudioSource.
                Close the containing PortAudioStream instead
                """) close(source)
            close(stream)
            @test !isopen(stream)
            @test !isopen(sink)
            @test !isopen(source)
            println("done")
        end
        @testset "Samplerate-converting writing" begin
            stream = PortAudioStream(0, 2)
            write(
                stream,
                SinSource(eltype(stream), samplerate(stream) * 0.8, [220, 330]),
                3s,
            )
            write(
                stream,
                SinSource(eltype(stream), samplerate(stream) * 1.2, [220, 330]),
                3s,
            )
            close(stream)
        end
        @testset "Open Device by name" begin
            stream = PortAudioStream(default_indev, default_outdev)
            buf = read(stream, 0.001s)
            @test size(buf) ==
                  (round(Int, 0.001 * samplerate(stream)), nchannels(stream.source))
            write(stream, buf)
            io = IOBuffer()
            show(io, stream)
            @test occursin(
                """
 PortAudioStream{Float32}
   Samplerate: 44100.0Hz
   2 channel sink: $(repr(default_outdev))
   2 channel source: $(repr(default_indev))""",
                String(take!(io)),
            )
            close(stream)
        end
        @testset "Error handling" begin
            @test_throws ErrorException PortAudioStream("foobarbaz")
            @test_throws ErrorException PortAudioStream(default_indev, "foobarbaz")
            @test_logs (:warn, "libportaudio: Output underflowed") handle_status(
                PaError(paOutputUnderflowed)
            )
            @test_throws ErrorException("libportaudio: PortAudio not initialized") handle_status(
                PaError(paNotInitialized)
            )
            @test_throws ErrorException("""
                Could not find ALSA config directory. Searched:


                If ALSA is installed, set the "ALSA_CONFIG_DIR" environment
                variable. The given directory should have a file "alsa.conf".

                If it would be useful to others, please file an issue at
                https://github.com/JuliaAudio/PortAudio.jl/issues
                with your alsa config directory so we can add it to the search
                paths.
                """) seek_alsa_conf([])
            @test_throws ErrorException(
                """
Can't open duplex stream with mismatched samplerates (in: 0, out: 1).
Try changing your sample rate in your driver settings or open separate input and output
streams.
""",
            ) combine_default_sample_rates(1, 0, 1, 1)
        end
        # no way to check that the right data is actually getting read or written here,
        # but at least it's not crashing.
        @testset "Queued Writing" begin
            stream = PortAudioStream(0, 2)
            buf = SampleBuf(
                rand(eltype(stream), 48000, nchannels(stream.sink)) * 0.1,
                samplerate(stream),
            )
            t1 = @async write(stream, buf)
            t2 = @async write(stream, buf)
            @test fetch(t1) == 48000
            @test fetch(t2) == 48000
            close(stream)
        end
        @testset "Queued Reading" begin
            stream = PortAudioStream(2, 0)
            buf = SampleBuf(
                rand(eltype(stream), 48000, nchannels(stream.source)) * 0.1,
                samplerate(stream),
            )
            t1 = @async read!(stream, buf)
            t2 = @async read!(stream, buf)
            @test fetch(t1) == 48000
            @test fetch(t2) == 48000
            close(stream)
        end
    end
end
