#!/usr/bin/env bash
# =============================================================================
# serato-dj808-linux  —  Roland DJ-808 + Serato DJ Pro on Linux via Wine
# =============================================================================
#
# Makes the Roland DJ-808 (and likely other Roland/BOSS USB MIDI controllers)
# work with Serato DJ Pro running under Wine on Linux.
#
# What this patcher does
# ----------------------
# 1. Builds + installs a custom libusb-1.0.dll stub that reads USB VID/PID
#    from Wine's device registry instead of trying raw USB ioctls (which Wine
#    stubs out).  Serato uses libusb to identify the controller.
#
# 2. Builds + installs an LD_PRELOAD hook (.so) that intercepts open()/openat()
#    calls from the Wine loader and redirects specific DLL paths to our patched
#    copies, without touching the system Wine installation.
#
# 3. Builds + installs RDAS1174.DLL, a fake Roland ASIO COM driver.  The real
#    driver talks to Roland's kernel USB audio driver (absent under Wine).  This
#    stub returns plausible ASIO values, drives Serato's audio engine via the
#    bufferSwitch callback, routes audio to the default waveOut device, and
#    implements the DJ-808 channel FX (Filter/Noise/Jet/Phaser) in software.
#    Source: rdas_stub.c / rdas_stub.def (sibling files in this repo).
#
# 4. Registers the seratodjpro:// URI scheme on Linux so that the OAuth login
#    flow (Firefox opens id.serato.com → redirects to seratodjpro://…) routes
#    back to the running Serato process instead of silently failing.
#
# 5. Applies version-specific binary patches to Serato DJ Pro.exe that fix the
#    USB-device aggregation loop.  Without these, Serato retries the DJ-808
#    aggregation ~78 000 times and never connects.
#
# 6. Sets Wine's "My Music" shell folder to the user's Serato library root
#    (--music-dir) so that new crates and library changes are written to the
#    same _Serato_ database that already holds the existing track collection.
#    Without this, Serato writes crates to an empty home library and they
#    vanish on next launch.
#
# 7. Rewrites legacy track paths in the Serato library database and all crate
#    files when --music-dir is given.  Serato DJ Pro 4.x stores paths as
#    Wine Z:-relative absolutes (e.g. "media/user/Drive/Music/track.mp3"),
#    but libraries created by Serato DJ Pro 2.x store paths relative to the
#    My Music root (e.g. "Music/track.mp3").  Without this rewrite every
#    track in an imported library shows as missing.
#
# 8. Writes a launch wrapper (~/.local/bin/serato-dj-pro) and updates (or
#    creates) the .desktop shortcut so the app launches correctly from any
#    desktop environment.
#
# Supported Serato versions
# -------------------------
#   4.0.7  — fully patched (binary patches + all hooks)
#   others — hooks + libusb stub applied; binary patches skipped with a warning
#
# Requirements
# ------------
#   gcc, mingw-w64 (x86-64 cross compiler), wine (WineHQ stable recommended),
#   python3, xdg-mime, update-desktop-database
#
# Usage
# -----
#   chmod +x patch.sh
#   ./patch.sh [--wineprefix PATH] [--wine-bin PATH] [--music-dir PATH] [--dry-run]
#
#   --music-dir PATH   Linux path to the directory that contains (or should
#                      contain) your _Serato_ library folder.  This is the root
#                      of the drive or folder where your music collection lives,
#                      e.g. /media/youruser/MyDrive or /home/youruser/Music.
#                      Serato will read/write crates and library data here.
#                      If omitted, the current Wine "My Music" mapping is left
#                      unchanged (crates may not persist if it points elsewhere).
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults (overridable via flags)
# ---------------------------------------------------------------------------
WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
WINE_BIN="${WINE_BIN:-wine}"
MUSIC_DIR=""
DRY_RUN=0

SERATO_REL="drive_c/Program Files/Serato/Serato DJ Pro"
SERATO_DIR=""
SERATO_EXE=""
SERATO_VERSION=""

INSTALL_DIR="$HOME/.local/share/serato-dj808-linux"
LAUNCH_WRAPPER="$HOME/.local/bin/serato-dj-pro"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wineprefix) WINEPREFIX="$2"; shift 2 ;;
        --wine-bin)   WINE_BIN="$2";   shift 2 ;;
        --music-dir)  MUSIC_DIR="$2";  shift 2 ;;
        --dry-run)    DRY_RUN=1;       shift   ;;
        -h|--help)
            sed -n '/^# Usage/,/^# ===/p' "$0" | grep -v "^# ===" | sed 's/^# \{0,2\}//'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }
run()   { [[ $DRY_RUN -eq 1 ]] && echo "[DRY]   $*" || "$@"; }

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1  (install $2)"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo ""
echo "  serato-dj808-linux patcher"
echo "  Roland DJ-808 + Serato DJ Pro on Linux via Wine"
echo "  ------------------------------------------------"
echo ""

require_cmd "$WINE_BIN"         "wine / wine-stable"
require_cmd gcc                 "gcc"
require_cmd x86_64-w64-mingw32-gcc "mingw-w64"
require_cmd python3             "python3"
require_cmd xdg-mime            "xdg-utils"

SERATO_DIR="$WINEPREFIX/$SERATO_REL"
SERATO_EXE="$SERATO_DIR/Serato DJ Pro.exe"

[[ -f "$SERATO_EXE" ]] || die "Serato DJ Pro.exe not found at: $SERATO_EXE
       Install Serato DJ Pro first, then run this patcher."

# Detect version from PE version resource (strings fallback)
SERATO_VERSION=$(python3 - "$SERATO_EXE" <<'PYEOF'
import sys, re
with open(sys.argv[1], 'rb') as f:
    data = f.read()
# look for FileVersion or ProductVersion string in PE resources
m = re.search(rb'(\d+\.\d+\.\d+)(?:\.\d+)?', data[0x3c0000:0x4000000])
if not m:
    m = re.search(rb'(\d+\.\d+\.\d+)', data)
print(m.group(1).decode() if m else 'unknown')
PYEOF
)

info "Found Serato DJ Pro version: $SERATO_VERSION"
info "Wine prefix: $WINEPREFIX"
info "Install dir: $INSTALL_DIR"
echo ""

# ---------------------------------------------------------------------------
# Create install directory
# ---------------------------------------------------------------------------
run mkdir -p "$INSTALL_DIR/x86_64-windows"
run mkdir -p "$HOME/.local/bin"
run mkdir -p "$HOME/.local/share/applications"

# ---------------------------------------------------------------------------
# Step 1 — Build libusb-1.0.dll stub
# ---------------------------------------------------------------------------
info "Step 1/8 — Building libusb-1.0.dll stub..."

cat > /tmp/_libusb_stub.c << 'CSRC'
/*
 * Custom libusb-1.0.dll stub for Serato DJ Pro on Wine.
 *
 * Wine's CM_Get_Parent is a stub, so libusb's hub-IOCTL path to get device
 * descriptors never works.  This DLL enumerates USB devices directly from the
 * Wine registry and parses VID/PID from device instance ID strings like
 * "USB\VID_0582&PID_01C9\512&256&1&6", which is sufficient for Serato to
 * identify connected hardware controllers.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef struct libusb_context {} libusb_context;

struct libusb_device {
    int ref_count;
    uint16_t vid, pid;
    uint8_t  bus_number, device_address;
    uint16_t bcd_device;
    uint8_t  num_configurations;
};

struct libusb_device_descriptor {
    uint8_t  bLength, bDescriptorType;
    uint16_t bcdUSB;
    uint8_t  bDeviceClass, bDeviceSubClass, bDeviceProtocol, bMaxPacketSize0;
    uint16_t idVendor, idProduct, bcdDevice;
    uint8_t  iManufacturer, iProduct, iSerialNumber, bNumConfigurations;
};

struct libusb_config_descriptor {
    uint8_t  bLength, bDescriptorType;
    uint16_t wTotalLength;
    uint8_t  bNumInterfaces, bConfigurationValue, iConfiguration, bmAttributes, MaxPower;
    const void *interface;
    const unsigned char *extra;
    int extra_length;
};

#define MAX_DEVICES 64
static struct libusb_device g_devices[MAX_DEVICES];
static int g_device_count = 0;

static BOOL parse_instance_id(const char *id,
                               uint16_t *vid, uint16_t *pid,
                               uint8_t *bus, uint8_t *addr)
{
    unsigned int v=0,p=0,b=0,a=0,x1=0,x2=0;
    if (sscanf(id,"USB\\VID_%04x&PID_%04x\\%x&%x&%x&%x",&v,&p,&b,&a,&x1,&x2)>=4) {
        *vid=(uint16_t)v; *pid=(uint16_t)p;
        *bus=(uint8_t)b;  *addr=(uint8_t)a;
        return TRUE;
    }
    return FALSE;
}

/*
 * Check if a USB device with the given VID/PID is physically connected by
 * scanning Z:\sys\bus\usb\devices\ (= /sys/bus/usb/devices/ on Linux).
 * Returns TRUE if found or if sysfs is inaccessible (fail-open).
 */
static BOOL is_physically_present(uint16_t vid, uint16_t pid)
{
    char vid_str[8], pid_str[8];
    /* sysfs idVendor/idProduct are lowercase hex with a trailing newline */
    snprintf(vid_str, sizeof(vid_str), "%04x", vid);
    snprintf(pid_str, sizeof(pid_str), "%04x", pid);

    WIN32_FIND_DATAA ffd;
    HANDLE h = FindFirstFileA("Z:\\sys\\bus\\usb\\devices\\*", &ffd);
    if (h == INVALID_HANDLE_VALUE) return TRUE; /* sysfs not accessible, assume present */

    BOOL found = FALSE;
    do {
        if (!(ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        if (ffd.cFileName[0] == '.') continue;

        char path[512]; char buf[16]; DWORD nr; HANDLE fh;

        snprintf(path, sizeof(path),
                 "Z:\\sys\\bus\\usb\\devices\\%s\\idVendor", ffd.cFileName);
        fh = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
        if (fh == INVALID_HANDLE_VALUE) continue;
        nr = 0; ReadFile(fh, buf, sizeof(buf)-1, &nr, NULL); CloseHandle(fh);
        buf[nr] = '\0';
        for (DWORD i = 0; i < nr; i++) if (buf[i]=='\n'||buf[i]=='\r') buf[i]='\0';
        if (_stricmp(buf, vid_str) != 0) continue;

        snprintf(path, sizeof(path),
                 "Z:\\sys\\bus\\usb\\devices\\%s\\idProduct", ffd.cFileName);
        fh = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
        if (fh == INVALID_HANDLE_VALUE) continue;
        nr = 0; ReadFile(fh, buf, sizeof(buf)-1, &nr, NULL); CloseHandle(fh);
        buf[nr] = '\0';
        for (DWORD i = 0; i < nr; i++) if (buf[i]=='\n'||buf[i]=='\r') buf[i]='\0';
        if (_stricmp(buf, pid_str) != 0) continue;

        found = TRUE;
        break;
    } while (FindNextFileA(h, &ffd));

    FindClose(h);
    return found;
}

static void enumerate_usb_devices(void)
{
    HKEY hKey; DWORD idx; char hw_class[256];
    g_device_count = 0;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,
                      "SYSTEM\\CurrentControlSet\\Enum\\USB",
                      0, KEY_READ, &hKey) != ERROR_SUCCESS) return;
    for (idx=0;;idx++) {
        DWORD class_len=sizeof(hw_class);
        if (RegEnumKeyExA(hKey,idx,hw_class,&class_len,NULL,NULL,NULL,NULL)!=ERROR_SUCCESS) break;
        if (strstr(hw_class,"&MI_")) continue;
        unsigned int tv=0,tp=0;
        if (sscanf(hw_class,"VID_%04x&PID_%04x",&tv,&tp)!=2) continue;
        HKEY hInst;
        if (RegOpenKeyExA(hKey,hw_class,0,KEY_READ,&hInst)!=ERROR_SUCCESS) continue;
        DWORD inst_idx; char instance_id[256];
        for (inst_idx=0;;inst_idx++) {
            DWORD inst_len=sizeof(instance_id);
            if (RegEnumKeyExA(hInst,inst_idx,instance_id,&inst_len,NULL,NULL,NULL,NULL)!=ERROR_SUCCESS) break;
            if (g_device_count>=MAX_DEVICES) break;
            char full_id[512];
            snprintf(full_id,sizeof(full_id),"USB\\%s\\%s",hw_class,instance_id);
            uint16_t vid,pid; uint8_t bus,addr;
            if (!parse_instance_id(full_id,&vid,&pid,&bus,&addr)) continue;
            if (!is_physically_present(vid,pid)) continue;
            HKEY hDev; uint16_t bcd_device=0;
            if (RegOpenKeyExA(hInst,instance_id,0,KEY_READ,&hDev)==ERROR_SUCCESS) {
                char hw_id[256]=""; DWORD hw_id_len=sizeof(hw_id),type;
                if (RegQueryValueExA(hDev,"HardwareId",NULL,&type,(BYTE*)hw_id,&hw_id_len)==ERROR_SUCCESS) {
                    unsigned int rev=0;
                    if (sscanf(hw_id,"USB\\VID_%*x&PID_%*x&REV_%04x",&rev)==1)
                        bcd_device=(uint16_t)rev;
                }
                RegCloseKey(hDev);
            }
            struct libusb_device *d=&g_devices[g_device_count++];
            d->ref_count=1; d->vid=vid; d->pid=pid;
            d->bus_number=bus; d->device_address=addr;
            d->bcd_device=bcd_device; d->num_configurations=1;
        }
        RegCloseKey(hInst);
    }
    RegCloseKey(hKey);
}

__declspec(dllexport) int libusb_init(libusb_context **ctx)
    { if(ctx)*ctx=NULL; enumerate_usb_devices(); return 0; }
__declspec(dllexport) void libusb_exit(libusb_context *ctx)
    { (void)ctx; g_device_count=0; }

__declspec(dllexport) int libusb_get_device_list(libusb_context *ctx, struct libusb_device ***list)
{
    (void)ctx; enumerate_usb_devices();
    struct libusb_device **arr=(struct libusb_device**)calloc(g_device_count+1,sizeof(void*));
    if(!arr) return -12;
    for(int i=0;i<g_device_count;i++){g_devices[i].ref_count++;arr[i]=&g_devices[i];}
    arr[g_device_count]=NULL; *list=arr; return g_device_count;
}
__declspec(dllexport) void libusb_free_device_list(struct libusb_device **list,int u){(void)u;free(list);}
__declspec(dllexport) struct libusb_device *libusb_ref_device(struct libusb_device *d){if(d)d->ref_count++;return d;}
__declspec(dllexport) void libusb_unref_device(struct libusb_device *d){(void)d;}

__declspec(dllexport) int libusb_get_device_descriptor(struct libusb_device *dev,
                                                         struct libusb_device_descriptor *desc)
{
    if(!dev||!desc) return -2;
    memset(desc,0,sizeof(*desc));
    desc->bLength=18; desc->bDescriptorType=1; desc->bcdUSB=0x0200;
    desc->bDeviceClass=0xFF; desc->bDeviceProtocol=0xFF; desc->bMaxPacketSize0=64;
    desc->idVendor=dev->vid; desc->idProduct=dev->pid;
    desc->bcdDevice=dev->bcd_device; desc->bNumConfigurations=dev->num_configurations;
    return 0;
}

__declspec(dllexport) int libusb_get_config_descriptor(struct libusb_device *dev,
                                                         uint8_t idx,
                                                         struct libusb_config_descriptor **config)
{
    (void)dev;(void)idx;
    struct libusb_config_descriptor *cfg=(struct libusb_config_descriptor*)calloc(1,sizeof(*cfg));
    if(!cfg) return -12;
    cfg->bLength=9; cfg->bDescriptorType=2; cfg->wTotalLength=9;
    cfg->bConfigurationValue=1; cfg->bmAttributes=0x80; cfg->MaxPower=250;
    *config=cfg; return 0;
}
__declspec(dllexport) void libusb_free_config_descriptor(struct libusb_config_descriptor *c){free(c);}
__declspec(dllexport) int libusb_get_active_config_descriptor(struct libusb_device *d,struct libusb_config_descriptor **c)
    {return libusb_get_config_descriptor(d,0,c);}
__declspec(dllexport) uint8_t libusb_get_bus_number(struct libusb_device *d){return d?d->bus_number:0;}
__declspec(dllexport) uint8_t libusb_get_device_address(struct libusb_device *d){return d?d->device_address:0;}
__declspec(dllexport) uint8_t libusb_get_port_number(struct libusb_device *d){return d?d->device_address:0;}
__declspec(dllexport) int libusb_get_port_numbers(struct libusb_device *d,uint8_t *p,int l){(void)d;(void)p;(void)l;return 0;}
__declspec(dllexport) struct libusb_device *libusb_get_parent(struct libusb_device *d){(void)d;return NULL;}
__declspec(dllexport) int libusb_get_max_packet_size(struct libusb_device *d,unsigned char e){(void)d;(void)e;return 64;}
__declspec(dllexport) int libusb_get_max_iso_packet_size(struct libusb_device *d,unsigned char e){(void)d;(void)e;return 0;}
__declspec(dllexport) int libusb_open(struct libusb_device *d,void **h){(void)d;(void)h;return -6;}
__declspec(dllexport) void libusb_close(void *h){(void)h;}
__declspec(dllexport) int libusb_set_configuration(void *h,int c){(void)h;(void)c;return -6;}
__declspec(dllexport) int libusb_claim_interface(void *h,int i){(void)h;(void)i;return -6;}
__declspec(dllexport) int libusb_release_interface(void *h,int i){(void)h;(void)i;return -6;}
__declspec(dllexport) int libusb_set_interface_alt_setting(void *h,int i,int a){(void)h;(void)i;(void)a;return -6;}
__declspec(dllexport) int libusb_clear_halt(void *h,unsigned char e){(void)h;(void)e;return -6;}
__declspec(dllexport) int libusb_reset_device(void *h){(void)h;return -6;}
__declspec(dllexport) int libusb_kernel_driver_active(void *h,int i){(void)h;(void)i;return 0;}
__declspec(dllexport) int libusb_detach_kernel_driver(void *h,int i){(void)h;(void)i;return -6;}
__declspec(dllexport) int libusb_attach_kernel_driver(void *h,int i){(void)h;(void)i;return -6;}
__declspec(dllexport) int libusb_get_string_descriptor_ascii(void *h,uint8_t i,unsigned char *d,int l)
    {(void)h;(void)i;(void)d;(void)l;return -6;}
__declspec(dllexport) int libusb_wrap_sys_device(libusb_context *ctx,intptr_t s,void **h)
    {(void)ctx;(void)s;(void)h;return -6;}
__declspec(dllexport) int libusb_open_device_with_vid_pid(libusb_context *ctx,uint16_t v,uint16_t p)
    {(void)ctx;(void)v;(void)p;return 0;}
__declspec(dllexport) int libusb_alloc_streams(void *h,uint32_t n,unsigned char *e,int ne)
    {(void)h;(void)n;(void)e;(void)ne;return -6;}
__declspec(dllexport) int libusb_free_streams(void *h,unsigned char *e,int ne)
    {(void)h;(void)e;(void)ne;return -6;}
__declspec(dllexport) int libusb_get_configuration(void *h,int *c)
    {(void)h;if(c)*c=1;return 0;}

BOOL WINAPI DllMain(HINSTANCE inst,DWORD reason,LPVOID reserved)
{
    (void)inst;(void)reserved;
    if(reason==DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(inst);
    return TRUE;
}
CSRC

if [[ $DRY_RUN -eq 0 ]]; then
    x86_64-w64-mingw32-gcc -shared -O2 -o "$INSTALL_DIR/x86_64-windows/libusb-1.0.dll" \
        /tmp/_libusb_stub.c \
        -lsetupapi -Wl,--subsystem,windows \
        2>/tmp/_libusb_build.log \
        && ok "libusb-1.0.dll built" \
        || die "libusb build failed. Log: /tmp/_libusb_build.log"
else
    info "[DRY] would build libusb-1.0.dll"
fi

# ---------------------------------------------------------------------------
# Step 2 — Build LD_PRELOAD hook
# ---------------------------------------------------------------------------
info "Step 2/8 — Building LD_PRELOAD hook..."

# Resolve actual Wine DLL directory
WINE_DLL_DIR=""
for candidate in \
    /opt/wine-stable/lib/wine \
    /usr/lib/wine \
    /usr/lib/x86_64-linux-gnu/wine \
    "$(dirname "$(command -v "$WINE_BIN")")/../lib/wine"
do
    if [[ -d "$candidate/x86_64-windows" ]]; then
        WINE_DLL_DIR="$candidate"
        break
    fi
done
[[ -n "$WINE_DLL_DIR" ]] || die "Could not locate Wine DLL directory. Set WINE_BIN to your wine binary."

info "Wine DLL dir: $WINE_DLL_DIR"

cat > /tmp/_wine_open_hook.c << CSRC2
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdio.h>

static const char WINE_DLL_DIR[] = "${WINE_DLL_DIR}";
static const char INSTALL_DIR[]  = "${INSTALL_DIR}";

struct redir { const char *suffix; const char *local_name; };
static const struct redir redirects[] = {
    { "/x86_64-windows/setupapi.dll", "/x86_64-windows/setupapi.dll" },
    { "/x86_64-windows/winmm.dll",    "/x86_64-windows/winmm.dll"    },
};
#define NUM_REDIRECTS (sizeof(redirects)/sizeof(redirects[0]))

static const char *maybe_redirect(const char *path) {
    if (!path) return path;
    size_t wlen = strlen(WINE_DLL_DIR);
    if (strncmp(path, WINE_DLL_DIR, wlen) != 0) return path;
    const char *suffix = path + wlen;
    for (size_t i = 0; i < NUM_REDIRECTS; i++) {
        if (strcmp(suffix, redirects[i].suffix) == 0) {
            static char buf[4096];
            snprintf(buf, sizeof(buf), "%s%s", INSTALL_DIR, redirects[i].local_name);
            /* only redirect if our patched copy actually exists */
            struct stat st;
            if (stat(buf, &st) == 0) {
                fprintf(stderr, "[dj808] redirect: %s -> patched\\n", suffix+1);
                return buf;
            }
        }
    }
    return path;
}

typedef int (*open_fn)(const char*,int,...);
static open_fn real_open=NULL;
int open(const char *p,int f,...){
    if(!real_open) real_open=(open_fn)dlsym(RTLD_NEXT,"open");
    p=maybe_redirect(p);
    if(f&O_CREAT){va_list a;va_start(a,f);mode_t m=va_arg(a,mode_t);va_end(a);return real_open(p,f,m);}
    return real_open(p,f);
}
typedef int (*openat_fn)(int,const char*,int,...);
static openat_fn real_openat=NULL;
int openat(int d,const char *p,int f,...){
    if(!real_openat) real_openat=(openat_fn)dlsym(RTLD_NEXT,"openat");
    p=maybe_redirect(p);
    if(f&O_CREAT){va_list a;va_start(a,f);mode_t m=va_arg(a,mode_t);va_end(a);return real_openat(d,p,f,m);}
    return real_openat(d,p,f);
}
int open64(const char *p,int f,...){
    typedef int(*fn)(const char*,int,...);static fn r=NULL;
    if(!r) r=(fn)dlsym(RTLD_NEXT,"open64");
    p=maybe_redirect(p);
    if(f&O_CREAT){va_list a;va_start(a,f);mode_t m=va_arg(a,mode_t);va_end(a);return r(p,f,m);}
    return r(p,f);
}
CSRC2

if [[ $DRY_RUN -eq 0 ]]; then
    gcc -shared -fPIC -O2 -o "$INSTALL_DIR/wine_open_hook.so" \
        /tmp/_wine_open_hook.c -ldl \
        2>/tmp/_hook_build.log \
        && ok "wine_open_hook.so built" \
        || die "Hook build failed. Log: /tmp/_hook_build.log"
else
    info "[DRY] would build wine_open_hook.so"
fi

# ---------------------------------------------------------------------------
# Step 3 — Build + deploy ASIO stubs (DJ-808: RDAS1174.DLL, DJ-505: RDAS0208.DLL)
# ---------------------------------------------------------------------------
info "Step 3/8 — Building ASIO stubs..."

# DJ-808
RDAS_SRC="$SCRIPT_DIR/rdas_stub.c"
RDAS_DEF="$SCRIPT_DIR/rdas_stub.def"
[[ -f "$RDAS_SRC" ]] || die "rdas_stub.c not found at $RDAS_SRC"
[[ -f "$RDAS_DEF" ]] || die "rdas_stub.def not found at $RDAS_DEF"

RDAS_TARGET="$WINEPREFIX/drive_c/windows/system32/RDAS1174.DLL"

if [[ $DRY_RUN -eq 0 ]]; then
    x86_64-w64-mingw32-gcc -shared -O2 \
        -o "$INSTALL_DIR/x86_64-windows/RDAS1174.DLL" \
        "$RDAS_SRC" "$RDAS_DEF" \
        -Wl,--export-all-symbols -lkernel32 -luser32 -lwinmm \
        2>/tmp/_rdas_build.log \
        && ok "RDAS1174.DLL built" \
        || die "RDAS build failed. Log: /tmp/_rdas_build.log"
    cp "$INSTALL_DIR/x86_64-windows/RDAS1174.DLL" "$RDAS_TARGET"
    ok "RDAS1174.DLL deployed to $RDAS_TARGET"

    # Register DJ-808 ASIO in Wine registry
    wine reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\ASIO\\DJ-808 ASIO" \
        /v CLSID /t REG_SZ /d "{D6FB76C2-9C4E-4d46-92F3-649672C65096}" /f >/dev/null
    wine reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\ASIO\\DJ-808 ASIO" \
        /v Description /t REG_SZ /d "DJ-808 ASIO" /f >/dev/null
    wine reg add "HKEY_CLASSES_ROOT\\CLSID\\{D6FB76C2-9C4E-4d46-92F3-649672C65096}\\InprocServer32" \
        /ve /t REG_SZ /d "RDAS1174.DLL" /f >/dev/null
    wine reg add "HKEY_CLASSES_ROOT\\CLSID\\{D6FB76C2-9C4E-4d46-92F3-649672C65096}\\InprocServer32" \
        /v ThreadingModel /t REG_SZ /d "Apartment" /f >/dev/null
    ok "DJ-808 ASIO registered"
else
    info "[DRY] would build RDAS1174.DLL from rdas_stub.c"
    info "[DRY] would deploy to $RDAS_TARGET"
fi

# DJ-505
RDAS505_SRC="$SCRIPT_DIR/rdas505_stub.c"
RDAS505_DEF="$SCRIPT_DIR/rdas505_stub.def"
RDAS505_CLSID="{A81EC7B7-7913-49DF-B2B7-25E59A2F8065}"
RDAS505_TARGET="$WINEPREFIX/drive_c/windows/system32/RDAS0208.DLL"

if [[ -f "$RDAS505_SRC" && -f "$RDAS505_DEF" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
        x86_64-w64-mingw32-gcc -shared -O2 \
            -o "$INSTALL_DIR/x86_64-windows/RDAS0208.DLL" \
            "$RDAS505_SRC" "$RDAS505_DEF" \
            -Wl,--export-all-symbols -lkernel32 -luser32 -lwinmm \
            2>/tmp/_rdas505_build.log \
            && ok "RDAS0208.DLL (DJ-505) built" \
            || die "RDAS505 build failed. Log: /tmp/_rdas505_build.log"
        cp "$INSTALL_DIR/x86_64-windows/RDAS0208.DLL" "$RDAS505_TARGET"
        ok "RDAS0208.DLL deployed to $RDAS505_TARGET"

        # Register DJ-505 ASIO in Wine registry
        wine reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\ASIO\\DJ-505 ASIO" \
            /v CLSID /t REG_SZ /d "$RDAS505_CLSID" /f >/dev/null
        wine reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\ASIO\\DJ-505 ASIO" \
            /v Description /t REG_SZ /d "DJ-505 ASIO" /f >/dev/null
        wine reg add "HKEY_CLASSES_ROOT\\CLSID\\$RDAS505_CLSID\\InprocServer32" \
            /ve /t REG_SZ /d "RDAS0208.DLL" /f >/dev/null
        wine reg add "HKEY_CLASSES_ROOT\\CLSID\\$RDAS505_CLSID\\InprocServer32" \
            /v ThreadingModel /t REG_SZ /d "Apartment" /f >/dev/null
        ok "DJ-505 ASIO registered"
    else
        info "[DRY] would build RDAS0208.DLL from rdas505_stub.c"
        info "[DRY] would deploy to $RDAS505_TARGET"
    fi
else
    info "rdas505_stub.c not found — skipping DJ-505 ASIO stub"
fi

# ---------------------------------------------------------------------------
# Step 4 — Deploy libusb stub into Serato install dir
# ---------------------------------------------------------------------------
info "Step 4/8 — Deploying libusb stub..."

LIBUSB_TARGET="$SERATO_DIR/libusb-1.0.dll"
if [[ $DRY_RUN -eq 0 ]]; then
    if [[ -f "$LIBUSB_TARGET" && ! -f "${LIBUSB_TARGET}.orig" ]]; then
        cp "$LIBUSB_TARGET" "${LIBUSB_TARGET}.orig"
        info "Backed up original libusb-1.0.dll"
    fi
    cp "$INSTALL_DIR/x86_64-windows/libusb-1.0.dll" "$LIBUSB_TARGET"
    ok "libusb-1.0.dll deployed to Serato directory"
else
    info "[DRY] would deploy libusb-1.0.dll to $LIBUSB_TARGET"
fi

# ---------------------------------------------------------------------------
# Step 5 — Apply version-specific binary patches to Serato DJ Pro.exe
# ---------------------------------------------------------------------------
info "Step 5/8 — Applying binary patches for Serato $SERATO_VERSION..."

apply_patches() {
    python3 - "$SERATO_EXE" "$SERATO_VERSION" << 'PYEOF'
import sys, shutil, os

exe_path = sys.argv[1]
version  = sys.argv[2]

# Each patch: (name, file_offset, expected_original_bytes, patch_bytes, description)
PATCHES = {
    "4.0.7": [
        # agg9a/agg9b: bypass direction==3 guard that blocks DJ-808 aggregation loop
        ("agg9a",  0x1a3fa1a, bytes.fromhex("0f8452fcffff"), bytes([0x90]*6),
         "bypass direction==3 first JE in aggregation retry path"),
        ("agg9b",  0x1a3fa2d, bytes.fromhex("0f843ffcffff"), bytes([0x90]*6),
         "bypass direction==3 second JE in aggregation retry path"),
        # agg10a/b/c: bypass vtable[2/3/5] gate checks that prevent search from running
        ("agg10a", 0x1a3bf3b, bytes.fromhex("7411"), bytes([0x90]*2),
         "bypass vtable[2] gate — primary MIDI search always runs"),
        ("agg10b", 0x1a3c192, bytes.fromhex("7411"), bytes([0x90]*2),
         "bypass vtable[3] gate — secondary MIDI search always runs"),
        ("agg10c", 0x1a3c4a4, bytes.fromhex("7411"), bytes([0x90]*2),
         "bypass vtable[5] gate — tertiary MIDI search always runs"),
    ],
}

if version not in PATCHES:
    print(f"[WARN]  No binary patches defined for version {version}.")
    print(f"[WARN]  The libusb stub and hook are still active — the controller")
    print(f"[WARN]  may work without patches on this version.")
    sys.exit(0)

# Backup
bak = exe_path + f".bak_dj808_{version.replace('.','_')}"
if not os.path.exists(bak):
    shutil.copy2(exe_path, bak)
    print(f"[INFO]  Backed up exe to {os.path.basename(bak)}")

with open(exe_path, 'r+b') as f:
    data = bytearray(f.read())

applied = skipped = already = 0
for name, offset, expected, patched, desc in PATCHES[version]:
    current = bytes(data[offset:offset+len(expected)])
    if current == patched:
        print(f"[OK]    {name}: already applied")
        already += 1
    elif current == expected:
        data[offset:offset+len(patched)] = patched
        print(f"[OK]    {name}: applied — {desc}")
        applied += 1
    else:
        print(f"[WARN]  {name}: unexpected bytes at 0x{offset:x}: "
              f"{current.hex(' ')} (expected {expected.hex(' ')})")
        print(f"        This patch may be for a different build. Skipping.")
        skipped += 1

if applied > 0:
    with open(exe_path, 'wb') as f:
        f.write(data)

print(f"[INFO]  Patches: {applied} applied, {already} already active, {skipped} skipped")
PYEOF
}

if [[ $DRY_RUN -eq 0 ]]; then
    apply_patches
else
    info "[DRY] would apply binary patches for version $SERATO_VERSION"
fi

# ---------------------------------------------------------------------------
# Step 6 — Set Wine "My Music" library root for crate persistence
# ---------------------------------------------------------------------------
info "Step 6/8 — Setting Wine library root (My Music) for crate persistence..."

if [[ -n "$MUSIC_DIR" ]]; then
    [[ -d "$MUSIC_DIR" ]] || die "--music-dir does not exist: $MUSIC_DIR"
    # Convert Linux absolute path → Wine Z: path (Z: is the Linux filesystem root)
    MUSIC_DIR_WIN="Z:$(echo "$MUSIC_DIR" | sed 's|/|\\|g')"
    if [[ $DRY_RUN -eq 0 ]]; then
        WINEPREFIX="$WINEPREFIX" "$WINE_BIN" reg add \
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders" \
            /v "My Music" /t REG_SZ /d "$MUSIC_DIR_WIN" /f &>/dev/null
        WINEPREFIX="$WINEPREFIX" "$WINE_BIN" reg add \
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders" \
            /v "My Music" /t REG_SZ /d "$MUSIC_DIR_WIN" /f &>/dev/null
        ok "My Music → $MUSIC_DIR_WIN"
    else
        info "[DRY] would set My Music → $MUSIC_DIR_WIN"
    fi
else
    warn "--music-dir not set; Wine My Music mapping left unchanged."
    warn "If crates don't persist after relaunch, re-run with --music-dir pointing"
    warn "to the directory that contains your _Serato_ library folder."
fi

# ---------------------------------------------------------------------------
# Step 7 — Rewrite legacy Serato 2.x track paths → Serato 4.x Z:-absolute
# ---------------------------------------------------------------------------
info "Step 7/8 — Rewriting legacy track paths in library and crates..."

if [[ -n "$MUSIC_DIR" ]]; then
    SERATO_LIB="$MUSIC_DIR/_Serato_"
    if [[ -d "$SERATO_LIB" ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            python3 - "$MUSIC_DIR" "$SERATO_LIB" << 'PYEOF'
import struct, os, sys, shutil, glob

music_dir = sys.argv[1]   # e.g. /media/anolis/Babylon
serato_lib = sys.argv[2]  # e.g. /media/anolis/Babylon/_Serato_

# The Z:-relative prefix we need to prepend to old relative paths.
# Z: = Linux root /, so strip the leading slash.
z_prefix = music_dir.lstrip('/')  # e.g. "media/anolis/Babylon"

def needs_fix(path_str):
    """True if path is old-format (relative to music root, not Z:-absolute)."""
    # New-format paths start with a real Linux root component, e.g. "media/", "home/"
    # Old-format paths start with a user folder, e.g. "Music/", "Downloads/"
    linux_abs = '/' + path_str.replace('\\', '/')
    return not os.path.exists(linux_abs)

def fixed_path(path_str):
    """Return the corrected Z:-absolute path, or None if unresolvable."""
    candidate = z_prefix + '/' + path_str.replace('\\', '/')
    if os.path.exists('/' + candidate):
        return candidate
    return None

def rebuild_with_new_paths(data, tag_to_fix):
    """
    Parse top-level tag/length records.  For each record whose tag matches
    tag_to_fix (b'otrk'), scan inner records for path tags (b'pfil' or b'ptrk')
    and rewrite if needed.  Returns (new_data_bytes, n_fixed, n_skipped).
    """
    path_tag = b'pfil' if tag_to_fix == b'otrk' and b'pfil' else b'ptrk'
    # Detect from first otrk which inner path tag is used
    # We'll handle both to be safe

    out = bytearray()
    pos = 0
    n_fixed = 0
    n_skipped = 0

    while pos < len(data) - 8:
        tag  = bytes(data[pos:pos+4])
        dlen = struct.unpack('>I', data[pos+4:pos+8])[0]
        if pos + 8 + dlen > len(data):
            out += data[pos:]
            break
        payload = bytes(data[pos+8:pos+8+dlen])

        if tag == tag_to_fix:
            # Rebuild inner record, patching pfil or ptrk
            inner_out = bytearray()
            ipos = 0
            while ipos < len(payload) - 8:
                itag  = bytes(payload[ipos:ipos+4])
                ilen  = struct.unpack('>I', payload[ipos+4:ipos+8])[0]
                if ipos + 8 + ilen > len(payload):
                    inner_out += payload[ipos:]
                    break
                ipay  = bytes(payload[ipos+8:ipos+8+ilen])

                if itag in (b'pfil', b'ptrk'):
                    try:
                        path_str = ipay.decode('utf-16-be')
                        if needs_fix(path_str):
                            new_path = fixed_path(path_str)
                            if new_path:
                                new_bytes = new_path.encode('utf-16-be')
                                inner_out += itag
                                inner_out += struct.pack('>I', len(new_bytes))
                                inner_out += new_bytes
                                n_fixed += 1
                                ipos += 8 + ilen
                                continue
                            else:
                                n_skipped += 1
                    except Exception:
                        pass

                inner_out += payload[ipos:ipos+8+ilen]
                ipos += 8 + ilen

            out += tag
            out += struct.pack('>I', len(inner_out))
            out += inner_out
        else:
            out += data[pos:pos+8+dlen]

        pos += 8 + dlen

    return bytes(out), n_fixed, n_skipped

total_fixed = 0
total_skipped = 0

# Fix database V2
db_path = os.path.join(serato_lib, 'database V2')
if os.path.exists(db_path):
    with open(db_path, 'rb') as f:
        db_data = bytearray(f.read())
    new_db, nf, ns = rebuild_with_new_paths(db_data, b'otrk')
    if nf > 0:
        shutil.copy2(db_path, db_path + '.bak_pathfix')
        with open(db_path, 'wb') as f:
            f.write(new_db)
        print(f'[OK]    database V2: {nf} paths fixed, {ns} unresolvable')
    else:
        print(f'[OK]    database V2: already up-to-date ({ns} unresolvable)')
    total_fixed += nf; total_skipped += ns

# Fix all crate files
crate_files = (
    glob.glob(os.path.join(serato_lib, 'Subcrates', '*.crate')) +
    glob.glob(os.path.join(serato_lib, 'Crates', '*.crate'))
)
crate_fixed = 0
for crate_path in crate_files:
    with open(crate_path, 'rb') as f:
        crate_data = bytearray(f.read())
    new_crate, nf, ns = rebuild_with_new_paths(crate_data, b'otrk')
    if nf > 0:
        shutil.copy2(crate_path, crate_path + '.bak_pathfix')
        with open(crate_path, 'wb') as f:
            f.write(new_crate)
        crate_fixed += 1
    total_fixed += nf; total_skipped += ns

print(f'[OK]    {crate_fixed}/{len(crate_files)} crate files updated')
print(f'[INFO]  Total: {total_fixed} paths fixed, {total_skipped} unresolvable')
PYEOF
        else
            info "[DRY] would rewrite legacy track paths in $SERATO_LIB"
        fi
    else
        info "No _Serato_ library found at $SERATO_LIB — skipping path fix"
    fi
else
    warn "--music-dir not set; skipping legacy path rewrite."
    warn "If tracks show as missing in Serato, re-run with --music-dir."
fi

# ---------------------------------------------------------------------------
# Step 8 — OAuth URI scheme + launch wrapper + desktop entry
# ---------------------------------------------------------------------------
info "Step 8/8 — Setting up OAuth handler, launch wrapper, desktop entry..."

# Register seratodjpro:// in Wine registry
if [[ $DRY_RUN -eq 0 ]]; then
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" reg add \
        "HKEY_CLASSES_ROOT\\seratodjpro" \
        /ve /t REG_SZ /d "URL:Serato DJ Pro Protocol" /f &>/dev/null
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" reg add \
        "HKEY_CLASSES_ROOT\\seratodjpro" \
        /v "URL Protocol" /t REG_SZ /d "" /f &>/dev/null
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" reg add \
        "HKEY_CLASSES_ROOT\\seratodjpro\\shell\\open\\command" \
        /ve /t REG_SZ \
        /d "\"C:\\\\Program Files\\\\Serato\\\\Serato DJ Pro\\\\Serato DJ Pro.exe\" \"%1\"" \
        /f &>/dev/null
    ok "seratodjpro:// registered in Wine registry"
fi

# Linux xdg URI scheme handler
HANDLER_SCRIPT="$INSTALL_DIR/seratodjpro-handler.sh"
if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$HANDLER_SCRIPT" << HEOF
#!/bin/bash
# Handles seratodjpro:// OAuth redirect callbacks for Serato DJ Pro on Wine
echo "[dj808 oauth] \$1" >> /tmp/seratodjpro_handler.log
exec env WINEPREFIX="${WINEPREFIX}" \\
    "${WINE_BIN}" start "\$1" >> /tmp/seratodjpro_handler.log 2>&1
HEOF
    chmod +x "$HANDLER_SCRIPT"

    cat > "$HOME/.local/share/applications/seratodjpro-handler.desktop" << DEOF
[Desktop Entry]
Type=Application
Name=Serato DJ Pro URI Handler
Exec=${HANDLER_SCRIPT} %u
MimeType=x-scheme-handler/seratodjpro;
NoDisplay=true
StartupNotify=false
DEOF
    xdg-mime default seratodjpro-handler.desktop x-scheme-handler/seratodjpro 2>/dev/null
    update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null
    ok "seratodjpro:// Linux xdg handler registered"
fi

# Launch wrapper
if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$LAUNCH_WRAPPER" << LEOF
#!/bin/bash
# Serato DJ Pro launcher — generated by serato-dj808-linux patcher
export WINEPREFIX="${WINEPREFIX}"
export LD_PRELOAD="${INSTALL_DIR}/wine_open_hook.so"
exec "${WINE_BIN}" "C:\\\\Program Files\\\\Serato\\\\Serato DJ Pro\\\\Serato DJ Pro.exe" "\$@"
LEOF
    chmod +x "$LAUNCH_WRAPPER"
    ok "Launch wrapper: $LAUNCH_WRAPPER"
fi

# Desktop entry
DESKTOP_ICON=$(find "$WINEPREFIX/drive_c" -name "*.0" -path "*Serato*" 2>/dev/null | head -1)
if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$HOME/.local/share/applications/serato-dj-pro.desktop" << DEOF
[Desktop Entry]
Name=Serato DJ Pro
Exec=${LAUNCH_WRAPPER}
Type=Application
StartupNotify=true
Path=${SERATO_DIR}
Icon=${DESKTOP_ICON}
StartupWMClass=serato dj pro.exe
DEOF
    update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null
    ok "Desktop entry updated"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "  ✓ Patcher complete."
echo ""
echo "  Launch Serato DJ Pro:"
echo "    $LAUNCH_WRAPPER"
echo ""
echo "  Or use the desktop shortcut (Serato DJ Pro)."
echo ""
if [[ "$SERATO_VERSION" != "4.0.7" ]]; then
    echo "  NOTE: Binary patches are only defined for 4.0.7."
    echo "  If the DJ-808 doesn't aggregate, open an issue at:"
    echo "  https://github.com/your-handle/serato-dj808-linux"
    echo ""
fi
echo "  Log files:"
echo "    /tmp/seratodjpro_handler.log  — OAuth login callbacks"
echo "    /tmp/serato_launch.log        — Wine/Serato stderr"
echo ""
