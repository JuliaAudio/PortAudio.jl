#include <portaudio.h>
#include <semaphore.h>
#include <stdio.h>
#include <unistd.h>

int paCallback(const void *inputBuffer, void *outputBuffer,
               unsigned long framesPerBuffer,
               const PaStreamCallbackTimeInfo* timeInfo,
               PaStreamCallbackFlags statusFlags,
               void *userData);

static PaStream *AudioStream;
static int JuliaPipeReadFD = 0;
static int JuliaPipeWriteFD = 0;
static sem_t CSemaphore;
static void *Buffer = NULL;

int make_pipe(void)
{
    int pipefd[2];
    pipe(pipefd);
    JuliaPipeReadFD = pipefd[0];
    JuliaPipeWriteFD = pipefd[1];
    sem_init(&CSemaphore, 0, 0);
    return JuliaPipeReadFD;
}

void synchronize_buffer(void *buffer)
{
    Buffer = buffer;
    sem_post(&CSemaphore);
}

PaError open_stream(unsigned int sampleRate, unsigned int bufSize)
{
    PaError err;

    err = Pa_OpenDefaultStream(&AudioStream,
            1,          /* single input channel */
            1,          /* mono output */
            paFloat32,  /* 32 bit floating point output */
            sampleRate,
            bufSize,    /* frames per buffer, i.e. the number of sample frames
                           that PortAudio will request from the callback. Many
                           apps may want to use paFramesPerBufferUnspecified,
                           which tells PortAudio to pick the best, possibly
                           changing, buffer size.*/
            paCallback, /* this is your callback function */
            NULL); /*This is a pointer that will be passed to your callback*/
    if(err != paNoError)
    {
        return err;
    }

    err = Pa_StartStream(AudioStream);
    if(err != paNoError)
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
int paCallback(const void *inputBuffer, void *outputBuffer,
               unsigned long framesPerBuffer,
               const PaStreamCallbackTimeInfo* timeInfo,
               PaStreamCallbackFlags statusFlags,
               void *userData)
{
    unsigned int i;
    unsigned char fd_data = 0;

    sem_wait(&CSemaphore);
    for(i=0; i<framesPerBuffer; i++)
    {
        ((float *)outputBuffer)[i] = ((float *)Buffer)[i];
        ((float *)Buffer)[i] = ((float *)inputBuffer)[i];
    }
    write(JuliaPipeWriteFD, &fd_data, 1);
    return 0;
}
