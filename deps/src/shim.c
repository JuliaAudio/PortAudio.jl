#include <portaudio.h>
#include <semaphore.h>
#include <julia/julia.h>
#include <math.h>
#include <stdio.h>

// some defines we need to include until PR 4997 is merged
STATIC_INLINE jl_function_t *jl_get_function(jl_module_t *m, const char *name)
{
    return  (jl_function_t*) jl_get_global(m, jl_symbol(name));
}

DLLEXPORT jl_value_t *jl_call2(jl_function_t *f, jl_value_t *a, jl_value_t *b)
{
    jl_value_t *v;
    JL_TRY {
        JL_GC_PUSH3(&f,&a,&b);
        jl_value_t *args[2] = {a,b};
        v = jl_apply(f, args, 2);
        JL_GC_POP();
    }
    JL_CATCH {
        v = NULL;
    }
    return v;
}

static int paCallback(const void *inputBuffer, void *outputBuffer,
                          unsigned long framesPerBuffer,
                          const PaStreamCallbackTimeInfo* timeInfo,
                          PaStreamCallbackFlags statusFlags,
                          void *userData);

static PaStream *AudioStream;
static jl_value_t *JuliaRemote;
static sem_t CSemaphore;
static void *OutData = NULL;
static unsigned long OutFrames = 0;
static jl_function_t *RemotePutFunc = NULL;
static jl_value_t *RemotePutArg = NULL;


void wake_callback_thread(void *outData, unsigned int outFrames)
{
    OutData = outData;
    OutFrames = outFrames;
    sem_post(&CSemaphore);
}

PaError open_stream(unsigned int sampleRate, unsigned int bufSize,
                    jl_value_t *jlRemote)
{
    PaError err;

    JuliaRemote = jlRemote;
    sem_init(&CSemaphore, 0, 0);
    RemotePutFunc = jl_get_function(jl_base_module, "put");
    RemotePutArg = jl_box_int32(0);

    err = Pa_OpenDefaultStream(&AudioStream,
            0,          /* no input channels */
            1,          /* mono output */
            paFloat32,  /* 32 bit floating point output */
            sampleRate,
            bufSize,        /* frames per buffer, i.e. the number of sample frames
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


//PaError stop_sin(void)
//{
//    PaError err;
//    err = Pa_StopStream(sin_stream);
//    if(err != paNoError)
//    {
//        return err;
//    }
//
//    err = Pa_CloseStream(sin_stream);
//    if( err != paNoError )
//    {
//        return err;
//    }
//    return paNoError;
//}


/*
 * This routine will be called by the PortAudio engine when audio is needed.
 * It may called at interrupt level on some machines so don't do anything that
 * could mess up the system like calling malloc() or free().
 */
static int paCallback(const void *inputBuffer, void *outputBuffer,
                           unsigned long framesPerBuffer,
                           const PaStreamCallbackTimeInfo* timeInfo,
                           PaStreamCallbackFlags statusFlags,
                           void *userData)
{
    unsigned int i;

    sem_wait(&CSemaphore);
    for(i=0; i<framesPerBuffer; i++)
    {
        ((float *)outputBuffer)[i] = ((float *)OutData)[i];
    }
    // TODO: copy the input data somewhere
    jl_call2(RemotePutFunc, JuliaRemote, RemotePutArg);
    return 0;
}
