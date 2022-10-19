using PortAudio

const RADIANS_PER_FRAME = 1 / 44100 * 440 * 2 * pi

function test()
    stream = PortAudioStream() do _, output_array, frames_per_buffer, frames_already
        # 44100 frames / second
        # 440 cycles / second 
        # 2pi radians / cycle
        if frames_already > 44100
            0
        else
            for frame in 1:frames_per_buffer
                output_array[1, frame] = sin((frames_already + frame) * RADIANS_PER_FRAME)
            end
            frames_per_buffer
        end
    end
    start(stream)
    sleep(2)
    close(stream)
end
