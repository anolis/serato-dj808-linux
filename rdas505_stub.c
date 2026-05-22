/*
 * rdas505_stub.c — Fake Roland DJ-505 ASIO driver (RDAS1197.DLL replacement)
 *
 * The DJ-505's real Windows ASIO driver uses kernel-mode USB audio, which
 * doesn't exist under Wine.  This stub implements the full IASIO COM vtable,
 * returns plausible values (48000 Hz, 1024-sample buffers, 8-in/6-out), and
 * routes audio to the default waveOut device.
 *
 * CLSID: {8CEA6E64-A172-4bd4-8A9A-0204E73C4005}  (matches real RDAS1197.DLL)
 * Channel layout matches real driver strings from RDAS1197.DLL:
 *   8 inputs:  DECK1 DVS IN/R, DECK2 DVS IN/R, TR-S IN/R, MIC RECORD/R
 *   6 outputs: MASTER OUTPUT/R, CUE OUTPUT/R, MASTER RECORD/R
 *
 * Compile (64-bit Windows DLL):
 *   x86_64-w64-mingw32-gcc -shared -O2 -o RDAS1197.DLL rdas505_stub.c \
 *       rdas505_stub.def -Wl,--export-all-symbols -lkernel32 -luser32 -lwinmm
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <process.h>

/* ── ASIO type definitions ─────────────────────────────────────────────── */

typedef long   ASIOBool;
typedef long   ASIOError;
typedef double ASIOSampleRate;
typedef long   ASIOSampleType;

#define ASIOTrue  1
#define ASIOFalse 0
#define ASE_OK           0
#define ASE_NotPresent  -1000
#define ASE_SUCCESS     0x3f4847a0
#define ASE_InvalidParameter -998

typedef struct { long lo; long hi; } ASIOSamples;
typedef struct { long lo; long hi; } ASIOTimeStamp;

typedef struct {
    long index;
    long associatedChannel;
    long associatedGroup;
    ASIOBool isCurrentSource;
    char name[32];
} ASIOClockSource;

typedef struct {
    long    channel;
    ASIOBool isInput;
    ASIOBool isActive;
    long    channelGroup;
    ASIOSampleType type;
    char    name[32];
} ASIOChannelInfo;

typedef struct {
    ASIOBool isInput;
    long     channelNum;
    void    *buffers[2];
} ASIOBufferInfo;

typedef struct {
    void (*bufferSwitch)(long doubleBufferIndex, ASIOBool directProcess);
    void (*sampleRateDidChange)(ASIOSampleRate sRate);
    long (*asioMessage)(long selector, long value, void *message, double *opt);
    void *(*bufferSwitchTimeInfo)(void *params, long doubleBufferIndex,
                                  ASIOBool directProcess);
} ASIOCallbacks;

/* ── IASIO vtable ─────────────────────────────────────────────────────── */

typedef struct IASIO_s IASIO;
typedef struct {
    HRESULT  (WINAPI *QueryInterface)(IASIO *, REFIID, void **);
    ULONG    (WINAPI *AddRef)(IASIO *);
    ULONG    (WINAPI *Release)(IASIO *);
    ASIOBool  (WINAPI *init)(IASIO *, void *sysHandle);
    void      (WINAPI *getDriverName)(IASIO *, char *name);
    long      (WINAPI *getDriverVersion)(IASIO *);
    void      (WINAPI *getErrorMessage)(IASIO *, char *string);
    ASIOError (WINAPI *start)(IASIO *);
    ASIOError (WINAPI *stop)(IASIO *);
    ASIOError (WINAPI *getChannels)(IASIO *, long *numIn, long *numOut);
    ASIOError (WINAPI *getLatencies)(IASIO *, long *inLat, long *outLat);
    ASIOError (WINAPI *getBufferSize)(IASIO *, long *minSz, long *maxSz,
                                      long *prefSz, long *gran);
    ASIOError (WINAPI *canSampleRate)(IASIO *, ASIOSampleRate);
    ASIOError (WINAPI *getSampleRate)(IASIO *, ASIOSampleRate *);
    ASIOError (WINAPI *setSampleRate)(IASIO *, ASIOSampleRate);
    ASIOError (WINAPI *getClockSources)(IASIO *, ASIOClockSource *, long *);
    ASIOError (WINAPI *setClockSource)(IASIO *, long reference);
    ASIOError (WINAPI *getSamplePosition)(IASIO *, ASIOSamples *, ASIOTimeStamp *);
    ASIOError (WINAPI *getChannelInfo)(IASIO *, ASIOChannelInfo *);
    ASIOError (WINAPI *createBuffers)(IASIO *, ASIOBufferInfo *, long numCh,
                                      long bufSz, ASIOCallbacks *);
    ASIOError (WINAPI *disposeBuffers)(IASIO *);
    ASIOError (WINAPI *controlPanel)(IASIO *);
    ASIOError (WINAPI *future)(IASIO *, long selector, void *opt);
    ASIOError (WINAPI *outputReady)(IASIO *);
} IASIOVtbl;

struct IASIO_s { const IASIOVtbl *lpVtbl; };

/* ── IClassFactory vtable ─────────────────────────────────────────────── */

typedef struct ICF_s ICF;
typedef struct {
    HRESULT (WINAPI *QueryInterface)(ICF *, REFIID, void **);
    ULONG   (WINAPI *AddRef)(ICF *);
    ULONG   (WINAPI *Release)(ICF *);
    HRESULT (WINAPI *CreateInstance)(ICF *, void *pOuter, REFIID, void **);
    HRESULT (WINAPI *LockServer)(ICF *, BOOL);
} ICFVtbl;

struct ICF_s { const ICFVtbl *lpVtbl; };

/* ── IASIO implementation ─────────────────────────────────────────────── */

static HRESULT WINAPI asio_QI(IASIO *t, REFIID r, void **p) { *p = t; return S_OK; }
static ULONG   WINAPI asio_AR(IASIO *t) { return 1; }
static ULONG   WINAPI asio_Rel(IASIO *t) { return 1; }

static ASIOBool WINAPI asio_init(IASIO *t, void *sys) { return ASIOTrue; }

static void WINAPI asio_getName(IASIO *t, char *n) { strcpy(n, "DJ-505 ASIO"); }
static long WINAPI asio_getVer(IASIO *t)            { return 1; }
static void WINAPI asio_getErr(IASIO *t, char *s)   { strcpy(s, "No error"); }

/* 8 inputs, 6 outputs — matches real RDAS1197.DLL channel count */
static ASIOError WINAPI asio_getCh(IASIO *t, long *ni, long *no) {
    *ni = 8; *no = 6; return ASE_OK;
}
static ASIOError WINAPI asio_getLat(IASIO *t, long *il, long *ol) {
    *il = 1024; *ol = 1024; return ASE_OK;
}
static ASIOError WINAPI asio_getBufSz(IASIO *t, long *mn, long *mx, long *pf, long *gr) {
    *mn = 64; *mx = 4096; *pf = 1024; *gr = 64; return ASE_OK;
}
static ASIOError WINAPI asio_canSR(IASIO *t, ASIOSampleRate sr) { return ASE_OK; }
static ASIOError WINAPI asio_getSR(IASIO *t, ASIOSampleRate *sr) {
    *sr = 48000.0; return ASE_OK;
}
static ASIOError WINAPI asio_setSR(IASIO *t, ASIOSampleRate sr) { return ASE_OK; }

static ASIOError WINAPI asio_getClk(IASIO *t, ASIOClockSource *c, long *n) {
    *n = 1;
    if (c) {
        c->index = 0; c->associatedChannel = -1; c->associatedGroup = -1;
        c->isCurrentSource = ASIOTrue;
        strcpy(c->name, "Internal");
    }
    return ASE_OK;
}
static ASIOError WINAPI asio_setClk(IASIO *t, long ref) { return ASE_OK; }

static ASIOError WINAPI asio_getSPos(IASIO *t, ASIOSamples *s, ASIOTimeStamp *ts) {
    if (s)  { s->lo = 0;  s->hi = 0; }
    if (ts) { ts->lo = 0; ts->hi = 0; }
    return ASE_OK;
}
static const char *const g_in_names[] = {
    "DECK1 DVS IN", "DECK1 DVS IN(R)",
    "DECK2 DVS IN", "DECK2 DVS IN(R)",
    "TR-S IN",      "TR-S IN(R)",
    "MIC RECORD",   "MIC RECORD(R)",
};
static const char *const g_out_names[] = {
    "MASTER OUTPUT", "MASTER OUTPUT(R)",
    "CUE OUTPUT",    "CUE OUTPUT(R)",
    "MASTER RECORD", "MASTER RECORD(R)",
};

static ASIOError WINAPI asio_getChInfo(IASIO *t, ASIOChannelInfo *i) {
    if (!i) return ASE_InvalidParameter;
    i->isActive = ASIOFalse;
    i->channelGroup = 0;
    i->type = 18; /* ASIOSTInt32LSB */
    if (i->isInput) {
        if (i->channel >= 0 && i->channel < 8)
            strncpy(i->name, g_in_names[i->channel], 32);
        else
            snprintf(i->name, 32, "Input %ld", i->channel + 1);
    } else {
        if (i->channel >= 0 && i->channel < 6)
            strncpy(i->name, g_out_names[i->channel], 32);
        else
            snprintf(i->name, 32, "Output %ld", i->channel + 1);
    }
    return ASE_OK;
}

#define MAX_CH  16
#define MAX_BSZ 4096
static int32_t g_bufs[MAX_CH][2][MAX_BSZ];

static ASIOCallbacks *g_cb       = NULL;
static long           g_buf_sz   = 1024;
static volatile long  g_running  = 0;
static HANDLE         g_thread   = NULL;
static int            g_out_slot[MAX_CH];

/* Double-buffered stereo int16 for waveOut at 48000 Hz */
static int16_t g_pcm[2][MAX_BSZ * 2];

static void fill_pcm(int16_t *out, int asio_idx)
{
    for (long s = 0; s < g_buf_sz; s++) {
        int64_t l = 0, r = 0;
        for (int ch = 0; ch < MAX_CH; ch++) {
            if (g_out_slot[ch] < 0) continue;
            int64_t v = g_bufs[g_out_slot[ch]][asio_idx][s];
            if (ch % 2 == 0) l += v;
            else             r += v;
        }
        if (l >  0x7fffffffLL) l =  0x7fffffffLL;
        if (l < -0x80000000LL) l = -0x80000000LL;
        if (r >  0x7fffffffLL) r =  0x7fffffffLL;
        if (r < -0x80000000LL) r = -0x80000000LL;
        out[s * 2]     = (int16_t)(l >> 16);
        out[s * 2 + 1] = (int16_t)(r >> 16);
    }
}

static unsigned __stdcall callback_thread(void *arg)
{
    (void)arg;

    HANDLE   evt    = CreateEventW(NULL, FALSE, FALSE, NULL);
    HWAVEOUT hwo    = NULL;
    BOOL     use_wo = FALSE;
    WAVEHDR  hdr[2];
    memset(hdr, 0, sizeof(hdr));

    WAVEFORMATEX wfx = {
        WAVE_FORMAT_PCM, 2, 48000, 192000, 4, 16, 0
    };

    if (waveOutOpen(&hwo, WAVE_MAPPER, &wfx,
                    (DWORD_PTR)evt, 0, CALLBACK_EVENT) == MMSYSERR_NOERROR) {
        use_wo = TRUE;
        for (int i = 0; i < 2; i++) {
            hdr[i].lpData         = (LPSTR)g_pcm[i];
            hdr[i].dwBufferLength = (DWORD)(g_buf_sz * 4);
            waveOutPrepareHeader(hwo, &hdr[i], sizeof(WAVEHDR));
            waveOutWrite(hwo, &hdr[i], sizeof(WAVEHDR));
        }
    }

    long asio_idx = 0;
    int  wave_idx = 0;

    while (g_running) {
        if (use_wo) {
            while (!(hdr[wave_idx].dwFlags & WHDR_DONE) && g_running)
                WaitForSingleObject(evt, 20);
            if (!g_running) break;

            if (g_cb && g_cb->bufferSwitch)
                g_cb->bufferSwitch(asio_idx, ASIOTrue);

            fill_pcm(g_pcm[wave_idx], asio_idx);
            hdr[wave_idx].dwBufferLength = (DWORD)(g_buf_sz * 4);
            waveOutWrite(hwo, &hdr[wave_idx], sizeof(WAVEHDR));

            wave_idx ^= 1;
            asio_idx ^= 1;
        } else {
            DWORD ms = (DWORD)((g_buf_sz * 1000UL) / 48000UL);
            Sleep(ms > 0 ? ms : 1);
            if (g_running && g_cb && g_cb->bufferSwitch)
                g_cb->bufferSwitch(asio_idx, ASIOTrue);
            asio_idx ^= 1;
        }
    }

    if (use_wo) {
        waveOutReset(hwo);
        for (int i = 0; i < 2; i++)
            waveOutUnprepareHeader(hwo, &hdr[i], sizeof(WAVEHDR));
        waveOutClose(hwo);
    }
    CloseHandle(evt);
    return 0;
}

static ASIOError WINAPI asio_createBufs(IASIO *t, ASIOBufferInfo *bi,
                                         long nch, long bsz, ASIOCallbacks *cb) {
    memset(g_bufs,    0, sizeof(g_bufs));
    memset(g_out_slot, -1, sizeof(g_out_slot));
    for (long i = 0; i < nch && i < MAX_CH; i++) {
        bi[i].buffers[0] = g_bufs[i][0];
        bi[i].buffers[1] = g_bufs[i][1];
        if (!bi[i].isInput && bi[i].channelNum >= 0 && bi[i].channelNum < MAX_CH)
            g_out_slot[bi[i].channelNum] = (int)i;
    }
    g_cb     = cb;
    g_buf_sz = (bsz > 0 && bsz <= MAX_BSZ) ? bsz : 1024;
    return ASE_OK;
}
static ASIOError WINAPI asio_dispBufs(IASIO *t) {
    g_cb = NULL;
    return ASE_OK;
}

static ASIOError WINAPI asio_start(IASIO *t)
{
    if (g_running) return ASE_OK;
    g_running = 1;
    g_thread  = (HANDLE)_beginthreadex(NULL, 0, callback_thread, NULL, 0, NULL);
    return ASE_OK;
}

static ASIOError WINAPI asio_stop(IASIO *t)
{
    if (!g_running) return ASE_OK;
    g_running = 0;
    if (g_thread) {
        WaitForSingleObject(g_thread, 500);
        CloseHandle(g_thread);
        g_thread = NULL;
    }
    return ASE_OK;
}

static ASIOError WINAPI asio_ctrlPanel(IASIO *t) { return ASE_OK; }
static ASIOError WINAPI asio_future(IASIO *t, long sel, void *opt) { return ASE_NotPresent; }
static ASIOError WINAPI asio_outRdy(IASIO *t) { return ASE_OK; }

static const IASIOVtbl g_asio_vtbl = {
    asio_QI, asio_AR, asio_Rel,
    asio_init, asio_getName, asio_getVer, asio_getErr,
    asio_start, asio_stop, asio_getCh, asio_getLat, asio_getBufSz,
    asio_canSR, asio_getSR, asio_setSR, asio_getClk, asio_setClk,
    asio_getSPos, asio_getChInfo, asio_createBufs, asio_dispBufs,
    asio_ctrlPanel, asio_future, asio_outRdy
};

static IASIO g_asio = { &g_asio_vtbl };

/* ── IClassFactory implementation ─────────────────────────────────────── */

static HRESULT WINAPI cf_QI(ICF *t, REFIID r, void **p) { *p = t; return S_OK; }
static ULONG   WINAPI cf_AR(ICF *t)  { return 2; }
static ULONG   WINAPI cf_Rel(ICF *t) { return 1; }
static HRESULT WINAPI cf_CI(ICF *t, void *outer, REFIID r, void **p) {
    *p = &g_asio; return S_OK;
}
static HRESULT WINAPI cf_LS(ICF *t, BOOL lock) { return S_OK; }

static const ICFVtbl g_cf_vtbl = { cf_QI, cf_AR, cf_Rel, cf_CI, cf_LS };
static ICF g_cf = { &g_cf_vtbl };

/* ── DLL entry points ─────────────────────────────────────────────────── */

BOOL WINAPI DllEntryPoint(HINSTANCE h, DWORD reason, LPVOID reserved) {
    return TRUE;
}

HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID *ppv) {
    *ppv = &g_cf;
    return S_OK;
}

HRESULT WINAPI DllCanUnloadNow(void)   { return S_FALSE; }
HRESULT WINAPI DllRegisterServer(void) { return S_OK; }
HRESULT WINAPI DllUnregisterServer(void) { return S_OK; }
