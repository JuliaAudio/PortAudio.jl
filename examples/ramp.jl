using AudioIO

# Give PortAudio time to load
play([0])
sleep(2)

println("""
                    *
                *   *
            *   *   *
        *   *   *   *
    *   *   *   *   *
*   *   *   *   *   *
""")
wave = SinOsc(440) * LinRamp(0.0, 1.0, 2.0)
play(wave)
sleep(2)
stop(wave)


println("""
                    *
                *   *   *
            *   *   *   *   *
        *   *   *   *   *   *   *
    *   *   *   *   *   *   *   *   *
*   *   *   *   *   *   *   *   *   *   *
""")
wave = SinOsc(440) * LinRamp([0.0, 1.0, 0.0], [2.0, 2.0])
play(wave)
sleep(4)
stop(wave)