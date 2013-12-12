#include <portaudio.h>
#include <math.h>
#include <stdio.h>

#define SAMPLE_RATE 44100

static int patestCallback(const void *inputBuffer, void *outputBuffer,
                          unsigned long framesPerBuffer,
                          const PaStreamCallbackTimeInfo* timeInfo,
                          PaStreamCallbackFlags statusFlags,
                          void *userData);

static PaStream *sin_stream;


PaError play_sin(void)
{
    PaError err;
//    PaDeviceInfo *info;
//    int numDevices;

//    printf("Found Devices:\n");
//    numDevices = Pa_GetDeviceCount();
//    for(i = 0; i < numDevices; ++i)
//    {
//        info = Pa_GetDeviceInfo(i);
//        printf("%s\n", info->name);
//    }

    err = Pa_OpenDefaultStream(&sin_stream,
            0,          /* no input channels */
            2,          /* stereo output */
            paFloat32,  /* 32 bit floating point output */
            SAMPLE_RATE,
            1024,        /* frames per buffer, i.e. the number of sample frames
                           that PortAudio will request from the callback. Many
                           apps may want to use paFramesPerBufferUnspecified,
                           which tells PortAudio to pick the best, possibly
                           changing, buffer size.*/
            patestCallback, /* this is your callback function */
            NULL); /*This is a pointer that will be passed to your callback*/
    if(err != paNoError)
    {
        return err;
    }

    err = Pa_StartStream(sin_stream);
    if(err != paNoError)
    {
        return err;
    }

    return paNoError;
}

PaError stop_sin(void)
{
    PaError err;
    err = Pa_StopStream(sin_stream);
    if(err != paNoError)
    {
        return err;
    }

    err = Pa_CloseStream(sin_stream);
    if( err != paNoError )
    {
        return err;
    }
    return paNoError;
}


/*
 * This routine will be called by the PortAudio engine when audio is needed.
 * It may called at interrupt level on some machines so don't do anything that
 * could mess up the system like calling malloc() or free().
 */
static int patestCallback(const void *inputBuffer, void *outputBuffer,
                           unsigned long framesPerBuffer,
                           const PaStreamCallbackTimeInfo* timeInfo,
                           PaStreamCallbackFlags statusFlags,
                           void *userData)
{
    float freq_l = 100;
    float freq_r = 150;
    static float phase_l = 0;
    static float phase_r = 0;

    float *out = (float*)outputBuffer;
    unsigned int i;

    for(i=0; i<framesPerBuffer; i++)
    {
        /* should modulo by 2PI */
        phase_l += (2 * M_PI * freq_l / SAMPLE_RATE);
        if(phase_l > 2 * M_PI)
        {
            phase_l -= 2 * M_PI;
        }
        phase_r += (2 * M_PI * freq_r / SAMPLE_RATE);
        if(phase_r > 2 * M_PI)
        {
            phase_r -= 2 * M_PI;
        }
        out[2*i] = sin(phase_l);
        out[2*i + 1] = sin(phase_r);
    }
    return 0;
}
