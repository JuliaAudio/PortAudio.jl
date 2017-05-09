#include <portaudio.h>
#include "pa_ringbuffer.h"
#include <stdio.h>
#include <unistd.h>

#define SHIM_VERSION 3
#define MIN(x, y) ((x) < (y) ? (x) : (y))

typedef enum {
    PA_SHIM_ERRMSG_OVERFLOW, // input overflow
    PA_SHIM_ERRMSG_UNDERFLOW, // output underflow
    PA_SHIM_ERRMSG_ERR_OVERFLOW, // error buffer overflowed
} pa_shim_errmsg_t;

// this callback type is used to notify the Julia side that the portaudio
// callback has run
typedef void (*pa_shim_notifycb_t)(void *userdata);

// This struct is shared between the Julia side and C
typedef struct {
    PaUtilRingBuffer *inputbuf; // ringbuffer for input
    PaUtilRingBuffer *outputbuf; // ringbuffer for output
    PaUtilRingBuffer *errorbuf; // ringbuffer to send error notifications
    int sync; // keep input/output ring buffers synchronized (0/1)
    pa_shim_notifycb_t notifycb; // Julia callback to notify conditions
    void *inputhandle; // condition to notify on new input
    void *outputhandle; // condition to notify when ready for output
    void *errorhandle; // condition to notify on new error
} pa_shim_info_t;

void senderr(pa_shim_info_t *info, pa_shim_errmsg_t msg) {
    if(PaUtil_GetRingBufferWriteAvailable(info->errorbuf) < 2) {
        // we've overflowed our error buffer! notify the host.
        msg = PA_SHIM_ERRMSG_ERR_OVERFLOW;
    }
    PaUtil_WriteRingBuffer(info->errorbuf, &msg, 1);
    if(info->notifycb) {
        info->notifycb(info->errorhandle);
    }
}

// return the version of the shim so we can make sure things are in sync
int pa_shim_getversion(void)
{
    return SHIM_VERSION;
}

/*
 * This routine will be called by the PortAudio engine when audio is needed.
 * It may called at interrupt level on some machines so don't do anything that
 * could mess up the system like calling malloc() or free().
 */
int pa_shim_processcb(const void *input, void *output,
                     unsigned long frameCount,
                     const PaStreamCallbackTimeInfo* timeInfo,
                     PaStreamCallbackFlags statusFlags,
                     void *userData)
{
    pa_shim_info_t *info = userData;
    if(info->notifycb == NULL) {
        fprintf(stderr, "pa_shim ERROR: notifycb is NULL\n");
    }

    int nwrite = PaUtil_GetRingBufferWriteAvailable(info->inputbuf);
    int nread = PaUtil_GetRingBufferReadAvailable(info->outputbuf);
    nwrite = MIN(frameCount, nwrite);
    nread = MIN(frameCount, nread);
    if(info->sync) {
        // to keep the buffers synchronized, set readable and writable to
        // their minimum value
        nread = MIN(nread, nwrite);
        nwrite = nread;
    }
    // read/write from the ringbuffers
    PaUtil_WriteRingBuffer(info->inputbuf, input, nwrite);
    if(info->notifycb) {
        info->notifycb(info->inputhandle);
    }
    PaUtil_ReadRingBuffer(info->outputbuf, output, nread);
    if(info->notifycb) {
        info->notifycb(info->outputhandle);
    }
    if(nwrite < frameCount) {
        senderr(info, PA_SHIM_ERRMSG_OVERFLOW);
    }
    if(nread < frameCount) {
        senderr(info, PA_SHIM_ERRMSG_UNDERFLOW);
        // we didn't fill the whole output buffer, so zero it out
        memset(output+nread*info->outputbuf->elementSizeBytes, 0,
               (frameCount - nread)*info->outputbuf->elementSizeBytes);
    }

    return paContinue;
}
