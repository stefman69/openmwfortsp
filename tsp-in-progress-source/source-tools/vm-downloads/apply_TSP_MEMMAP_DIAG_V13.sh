#!/usr/bin/env bash
set -Eeuo pipefail

HOST="${1:-${TSP_HOST:-root@192.168.1.21}}"
CONTAINER="openmw_builder"

GLSRC="/root/gl4es-tsp-pvr-texture-v2"
OMWSRC="/root/openmw-0.51-tsp-src"
OMWBUILD="/root/openmw-0.51-tsp-build"

ROOT="/mnt/mmc/ports/openmw"
PORTS="/mnt/mmc/ROMS/Ports"
PROD_GL="$ROOT/lib/libGL.so.1"
TSP_GL="$ROOT/lib.tsp-pvr-texture-v2/libGL.so.1"
V12_LAUNCHER="$PORTS/Morrowind-TSP-PVR-TEXTURE-DIAG-V12.sh"
V13_LAUNCHER="$PORTS/Morrowind-TSP-MEMMAP-DIAG-V13.sh"
V13_OMW="$ROOT/bin/openmw-0.51.tsp-memmap-v13"
V13_PULL="$ROOT/tsp_memmap_v13_pull.sh"

EXPECTED_PROD_GL="98794823e6df485fd90c53bdbdf5830e0118eda212b0d4b141562bb692e090bb"
EXPECTED_V12_GL="3617ae7b8bd1c91d8f01f644cd42d8362fd4f003ef46125c84149daaf6c39ff9"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
SOCK="/tmp/tsp-memmap-v13-$$"

LOCAL_GL="$DL/libGL.so.1-tsp-memmap-v13"
LOCAL_OMW="$DL/openmw-0.51.tsp-memmap-v13"
LOCAL_V12="$DL/Morrowind-TSP-PVR-TEXTURE-DIAG-V12.sh"
LOCAL_V13="$DL/Morrowind-TSP-MEMMAP-DIAG-V13.sh"
LOCAL_PULL="$DL/tsp_memmap_v13_pull.sh"

mkdir -p "$DL"

cleanup() {
    ssh -S "$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    local rc="$1"
    shift
    echo
    echo "============================================================"
    echo "PATCH STOPPED"
    echo "============================================================"
    echo "ERROR: $*"
    echo "return_code=$rc"
    echo "Your VM terminal remains open."
    echo "Production TSPS/Mali files were not intentionally modified."
    echo "No new gl4es source fork was created."
    echo "============================================================"
    exit "$rc"
}

echo "============================================================"
echo "TSP MEMORY + MAP BROAD DIAGNOSTIC V13"
echo "============================================================"
echo "TSP gl4es source (IN PLACE): $GLSRC"
echo "TSPS source (UNTOUCHED):     /root/gl4es-tsps"
echo "OpenMW source (IN PLACE):    $OMWSRC"
echo "Device:                      $HOST"
echo

command -v docker >/dev/null 2>&1 || fail 3 "docker is unavailable"
command -v ssh >/dev/null 2>&1 || fail 3 "ssh is unavailable"
command -v scp >/dev/null 2>&1 || fail 3 "scp is unavailable"
command -v python3 >/dev/null 2>&1 || fail 3 "python3 is unavailable"

echo "[0/11] SSH/PASSWORD PRECHECK FIRST"
echo "If password authentication is used, enter it now; this connection is reused."

ssh \
    -M \
    -S "$SOCK" \
    -o ControlPersist=600 \
    -o StrictHostKeyChecking=accept-new \
    "$HOST" true \
    || fail 10 "could not open reusable SSH connection"

echo "SSH PRECHECK: PASS"

# Avoid introducing a second password prompt for local sudo.
docker info >/dev/null 2>&1 \
    || fail 11 "Docker is not accessible as the current VM user"

STATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
case "$STATE" in
    running) ;;
    paused) docker unpause "$CONTAINER" >/dev/null || fail 12 "could not unpause $CONTAINER" ;;
    exited|created) docker start "$CONTAINER" >/dev/null || fail 12 "could not start $CONTAINER" ;;
    "") fail 12 "Docker container $CONTAINER does not exist" ;;
    *) fail 12 "unsupported Docker state: $STATE" ;;
esac

echo
echo "[1/11] VERIFYING SOURCE + DEVICE BASELINES"

for d in "$GLSRC" "$OMWSRC" /root/gl4es-tsps; do
    docker exec "$CONTAINER" test -d "$d" || fail 13 "missing source tree: $d"
done

PROD_SHA="$(ssh -S "$SOCK" -o BatchMode=yes "$HOST" \
    "sha256sum '$PROD_GL' 2>/dev/null | awk '{print \$1}'")"
TSP_SHA="$(ssh -S "$SOCK" -o BatchMode=yes "$HOST" \
    "sha256sum '$TSP_GL' 2>/dev/null | awk '{print \$1}'")"
PROD_OMW_SHA="$(ssh -S "$SOCK" -o BatchMode=yes "$HOST" \
    "sha256sum '$ROOT/bin/openmw-0.51' 2>/dev/null | awk '{print \$1}'")"

echo "production_libgl=$PROD_SHA"
echo "current_tsp_sidecar=$TSP_SHA"
echo "production_openmw=$PROD_OMW_SHA"

[ "$PROD_SHA" = "$EXPECTED_PROD_GL" ] \
    || fail 14 "production libGL hash changed"

[ "$TSP_SHA" = "$EXPECTED_V12_GL" ] \
    || fail 15 "TSP sidecar is not the verified V12 baseline"

if [ ! -f "$LOCAL_V12" ]; then
    echo "Pulling installed V12 launcher through the existing authenticated connection."
    scp -q -o ControlPath="$SOCK" "$HOST:$V12_LAUNCHER" "$LOCAL_V12" \
        || fail 16 "could not obtain V12 launcher"
fi

grep -q 'TSP_PVR_TEXTURE_FORK_V2' "$LOCAL_V12" \
    || fail 16 "V12 launcher marker missing"

echo
echo "[2/11] BACKING UP CURRENT SOURCES + CURRENT BUILD OUTPUTS"

docker exec -i "$CONTAINER" bash -s -- \
    "$GLSRC" "$OMWSRC" "$OMWBUILD" "$STAMP" <<'DOCKER_BACKUP'
set -Eeuo pipefail

GLSRC="$1"
OMWSRC="$2"
OMWBUILD="$3"
STAMP="$4"

BACK="/root/tsp_patch_backups/memmap-v13-pre-$STAMP"
mkdir -p "$BACK/gl4es" "$BACK/openmw" "$BACK/build"

for rel in src/gl/framebuffers.c src/gl/buffers.c src/gl/shader.c src/gl/program.c; do
    [ -f "$GLSRC/$rel" ] || { echo "ERROR: missing $GLSRC/$rel"; exit 21; }
    cp -p "$GLSRC/$rel" "$BACK/gl4es/$(basename "$rel").before"
    sha256sum "$GLSRC/$rel" >> "$BACK/gl4es.before.sha256"
done

for rel in apps/openmw/mwrender/occlusionculling.cpp apps/openmw/mwrender/localmap.cpp; do
    [ -f "$OMWSRC/$rel" ] || { echo "ERROR: missing $OMWSRC/$rel"; exit 22; }
    cp -p "$OMWSRC/$rel" "$BACK/openmw/$(basename "$rel").before"
    sha256sum "$OMWSRC/$rel" >> "$BACK/openmw.before.sha256"
done

git -C "$GLSRC" status --short --untracked-files=all > "$BACK/gl4es-status.before.txt" 2>&1 || true
git -C "$GLSRC" diff > "$BACK/gl4es-working.before.diff" 2>&1 || true
git -C "$OMWSRC" status --short --untracked-files=all > "$BACK/openmw-status.before.txt" 2>&1 || true
git -C "$OMWSRC" diff > "$BACK/openmw-working.before.diff" 2>&1 || true

[ -f "$GLSRC/lib/libGL.so.1" ] && cp -p "$GLSRC/lib/libGL.so.1" "$BACK/build/libGL.before" || true

for b in "$OMWBUILD/openmw" "$OMWBUILD/apps/openmw/openmw"; do
    if [ -f "$b" ]; then
        cp -p "$b" "$BACK/build/openmw.before"
        sha256sum "$b" > "$BACK/build/openmw.before.sha256"
        break
    fi
done

echo "backup=$BACK"
DOCKER_BACKUP

echo
echo "[3/11] PATCHING THE EXISTING TSP WORKING TREES IN PLACE"

docker exec -i "$CONTAINER" python3 - "$GLSRC" "$OMWSRC" <<'PY'
from pathlib import Path
import sys

gl = Path(sys.argv[1])
omw = Path(sys.argv[2])

def rep(s, old, new, label):
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label}: expected 1 anchor, found {n}")
    return s.replace(old, new, 1)

# ------------------------------------------------------------------
# Existing native-life log -> add buffers, shaders and programs.
# ------------------------------------------------------------------
p = gl / "src/gl/framebuffers.c"
s = p.read_text()

if "TSP_MEMMAP_NATIVE_DIAG_V13" not in s:
    s = rep(
        s,
        '''static unsigned long tsp_native_tex_gen=0, tsp_native_tex_del=0;
static unsigned long long tsp_native_rb_live_bytes=0;
''',
        '''static unsigned long tsp_native_tex_gen=0, tsp_native_tex_del=0;
/* TSP_MEMMAP_NATIVE_DIAG_V13 */
static unsigned long tsp_native_buf_gen=0, tsp_native_buf_del=0;
static unsigned long tsp_native_shader_gen=0, tsp_native_shader_req_del=0, tsp_native_shader_native_del=0;
static unsigned long tsp_native_program_gen=0, tsp_native_program_del=0;
static unsigned long long tsp_native_rb_live_bytes=0;
typedef struct { GLuint id; unsigned long long bytes; int used; } tsp_native_buf_rec_t;
#define TSP_NATIVE_BUF_MAX 8192
static tsp_native_buf_rec_t tsp_native_buf[TSP_NATIVE_BUF_MAX];
static unsigned long long tsp_native_buf_live_bytes=0;
''',
        "native counters",
    )

    s = rep(
        s,
        'if(p&&p[0]){f=fopen(p,"a");if(f){fprintf(f,"# TSP_NATIVE_LIFE_DIAG_V1 seq event fields\\n");fflush(f);}}',
        'if(p&&p[0]){f=fopen(p,"a");if(f){fprintf(f,"# TSP_NATIVE_LIFE_DIAG_V3 TSP_MEMMAP_NATIVE_DIAG_V13 FBO/RB/TEX/BUF/SHADER/PROGRAM\\n");fflush(f);}}',
        "native log header",
    )

    anchor = 'static void tsp_native_fbo_deleted(GLuint id){if(!tsp_native_life_on()||!id)return;++tsp_native_fbo_del;tsp_native_log("DEL_FBO id=%u gen=%lu del=%lu live=%ld",id,tsp_native_fbo_gen,tsp_native_fbo_del,(long)tsp_native_fbo_gen-(long)tsp_native_fbo_del);}\n'
    add = anchor + r'''static tsp_native_buf_rec_t* tsp_native_buf_slot(GLuint id,int create){
    tsp_native_buf_rec_t*empty=NULL;if(!id)return NULL;
    for(int i=0;i<TSP_NATIVE_BUF_MAX;i++){
        if(tsp_native_buf[i].used&&tsp_native_buf[i].id==id)return &tsp_native_buf[i];
        if(!tsp_native_buf[i].used&&!empty)empty=&tsp_native_buf[i];
    }
    if(create&&empty){empty->used=1;empty->id=id;empty->bytes=0;return empty;}
    return NULL;
}
void tsp_native_life_buffer_generated(GLuint id,const char*owner){
    if(!tsp_native_life_on()||!id)return;
    ++tsp_native_buf_gen;(void)tsp_native_buf_slot(id,1);
    tsp_native_log("GEN_BUF id=%u owner=%s gen=%lu del=%lu live=%ld live_bytes=%llu",
        id,owner?owner:"?",tsp_native_buf_gen,tsp_native_buf_del,
        (long)tsp_native_buf_gen-(long)tsp_native_buf_del,tsp_native_buf_live_bytes);
}
void tsp_native_life_buffer_storage(GLuint id,unsigned long long bytes,const char*owner){
    if(!tsp_native_life_on()||!id)return;
    tsp_native_buf_rec_t*r=tsp_native_buf_slot(id,1);
    if(r){
        if(tsp_native_buf_live_bytes>=r->bytes)tsp_native_buf_live_bytes-=r->bytes;
        else tsp_native_buf_live_bytes=0;
        r->bytes=bytes;tsp_native_buf_live_bytes+=bytes;
    }
    tsp_native_log("BUF_STORAGE id=%u owner=%s bytes=%llu live_bytes=%llu",
        id,owner?owner:"?",bytes,tsp_native_buf_live_bytes);
}
void tsp_native_life_buffer_deleted(GLuint id,const char*owner){
    if(!tsp_native_life_on()||!id)return;
    tsp_native_buf_rec_t*r=tsp_native_buf_slot(id,0);
    if(r){
        if(tsp_native_buf_live_bytes>=r->bytes)tsp_native_buf_live_bytes-=r->bytes;
        else tsp_native_buf_live_bytes=0;
        r->used=0;r->id=0;r->bytes=0;
    }
    ++tsp_native_buf_del;
    tsp_native_log("DEL_BUF id=%u owner=%s gen=%lu del=%lu live=%ld live_bytes=%llu",
        id,owner?owner:"?",tsp_native_buf_gen,tsp_native_buf_del,
        (long)tsp_native_buf_gen-(long)tsp_native_buf_del,tsp_native_buf_live_bytes);
}
void tsp_native_life_shader_generated(GLuint id,GLenum type){
    if(!tsp_native_life_on()||!id)return;
    ++tsp_native_shader_gen;
    tsp_native_log("GEN_SHADER id=%u type=0x%x gen=%lu req_del=%lu native_del=%lu live=%ld",
        id,type,tsp_native_shader_gen,tsp_native_shader_req_del,tsp_native_shader_native_del,
        (long)tsp_native_shader_gen-(long)tsp_native_shader_native_del);
}
void tsp_native_life_shader_delete_request(GLuint id,int attached,int forwarded){
    if(!tsp_native_life_on()||!id)return;
    ++tsp_native_shader_req_del;
    tsp_native_log("REQ_DEL_SHADER id=%u attached=%d native_forwarded=%d gen=%lu req_del=%lu native_del=%lu",
        id,attached,forwarded,tsp_native_shader_gen,tsp_native_shader_req_del,tsp_native_shader_native_del);
}
void tsp_native_life_shader_native_deleted(GLuint id){
    if(!tsp_native_life_on()||!id)return;
    ++tsp_native_shader_native_del;
    tsp_native_log("DEL_SHADER_NATIVE id=%u gen=%lu req_del=%lu native_del=%lu live=%ld",
        id,tsp_native_shader_gen,tsp_native_shader_req_del,tsp_native_shader_native_del,
        (long)tsp_native_shader_gen-(long)tsp_native_shader_native_del);
}
void tsp_native_life_program_generated(GLuint id){
    if(!tsp_native_life_on()||!id)return;
    ++tsp_native_program_gen;
    tsp_native_log("GEN_PROGRAM id=%u gen=%lu del=%lu live=%ld",
        id,tsp_native_program_gen,tsp_native_program_del,
        (long)tsp_native_program_gen-(long)tsp_native_program_del);
}
void tsp_native_life_program_deleted(GLuint id){
    if(!tsp_native_life_on()||!id)return;
    ++tsp_native_program_del;
    tsp_native_log("DEL_PROGRAM id=%u gen=%lu del=%lu live=%ld",
        id,tsp_native_program_gen,tsp_native_program_del,
        (long)tsp_native_program_gen-(long)tsp_native_program_del);
}
'''
    s = rep(s, anchor, add, "native helper insertion")
    p.write_text(s)
    print("PATCHED framebuffers.c")
else:
    print("ALREADY framebuffers.c")

# ------------------------------------------------------------------
# Native buffer accounting, including the default TSP orphan-rotation path.
# ------------------------------------------------------------------
p = gl / "src/gl/buffers.c"
s = p.read_text()

if "TSP_NATIVE_BUFFER_DIAG_V13" not in s:
    s = rep(
        s,
        '#include <string.h>\n',
        '''#include <string.h>
/* TSP_NATIVE_BUFFER_DIAG_V13 */
void tsp_native_life_buffer_generated(GLuint id,const char*owner);
void tsp_native_life_buffer_storage(GLuint id,unsigned long long bytes,const char*owner);
void tsp_native_life_buffer_deleted(GLuint id,const char*owner);
''',
        "buffer declarations",
    )

    s = rep(
        s,
        '''    gles_glGenBuffers(1, &fresh);
    if (!fresh) return 0;
    bindBuffer(target, fresh);
    gles_glBufferData(target, buff->size, buff->data, buff->usage);
''',
        '''    gles_glGenBuffers(1, &fresh);
    if (!fresh) return 0;
    tsp_native_life_buffer_generated(fresh, "orphan-rotate");
    bindBuffer(target, fresh);
    gles_glBufferData(target, buff->size, buff->data, buff->usage);
    tsp_native_life_buffer_storage(fresh, (unsigned long long)buff->size, "orphan-rotate");
''',
        "orphan rotation",
    )

    s = rep(
        s,
        '''        if(!buff->real_buffer) {
            LOAD_GLES(glGenBuffers);
            gles_glGenBuffers(1, &buff->real_buffer);
        }
        LOAD_GLES(glBufferData);
        LOAD_GLES(glBindBuffer);
        bindBuffer(target, buff->real_buffer);
        gles_glBufferData(target, size, data, usage);
''',
        '''        if(!buff->real_buffer) {
            LOAD_GLES(glGenBuffers);
            gles_glGenBuffers(1, &buff->real_buffer);
            tsp_native_life_buffer_generated(buff->real_buffer, "BufferData");
        }
        LOAD_GLES(glBufferData);
        LOAD_GLES(glBindBuffer);
        bindBuffer(target, buff->real_buffer);
        gles_glBufferData(target, size, data, usage);
        tsp_native_life_buffer_storage(buff->real_buffer, (unsigned long long)size, "BufferData");
''',
        "BufferData accounting",
    )

    s = rep(
        s,
        '''        if(!buff->real_buffer) {
            LOAD_GLES(glGenBuffers);
            gles_glGenBuffers(1, &buff->real_buffer);
        }
        LOAD_GLES(glBufferData);
        LOAD_GLES(glBindBuffer);
        bindBuffer(buff->type, buff->real_buffer);
        gles_glBufferData(buff->type, size, data, usage);
''',
        '''        if(!buff->real_buffer) {
            LOAD_GLES(glGenBuffers);
            gles_glGenBuffers(1, &buff->real_buffer);
            tsp_native_life_buffer_generated(buff->real_buffer, "NamedBufferData");
        }
        LOAD_GLES(glBufferData);
        LOAD_GLES(glBindBuffer);
        bindBuffer(buff->type, buff->real_buffer);
        gles_glBufferData(buff->type, size, data, usage);
        tsp_native_life_buffer_storage(buff->real_buffer, (unsigned long long)size, "NamedBufferData");
''',
        "NamedBufferData accounting",
    )

    s = rep(
        s,
        '''   gles_glDeleteBuffers(1, &buffer);
}
''',
        '''   gles_glDeleteBuffers(1, &buffer);
   tsp_native_life_buffer_deleted(buffer, "deleteSingleBuffer");
}
''',
        "buffer deletion accounting",
    )

    p.write_text(s)
    print("PATCHED buffers.c")
else:
    print("ALREADY buffers.c")

# ------------------------------------------------------------------
# Shader lifetime observation only. No deletion behavior change.
# ------------------------------------------------------------------
p = gl / "src/gl/shader.c"
s = p.read_text()

if "TSP_SHADER_LIFETIME_DIAG_V13" not in s:
    anchor = 'GLuint APIENTRY_GL4ES gl4es_glCreateShader(GLenum shaderType) {\n'
    s = rep(
        s,
        anchor,
        '''/* TSP_SHADER_LIFETIME_DIAG_V13
 * Diagnostic only: do not change the intentional persistent prewarm policy.
 */
void tsp_native_life_shader_generated(GLuint id,GLenum type);
void tsp_native_life_shader_delete_request(GLuint id,int attached,int forwarded);
void tsp_native_life_shader_native_deleted(GLuint id);

''' + anchor,
        "shader declarations",
    )

    s = rep(
        s,
        '    // store the new empty shader in the list\n',
        '    tsp_native_life_shader_generated(shader, shaderType);\n    // store the new empty shader in the list\n',
        "shader create accounting",
    )

    s = rep(
        s,
        '''    glshader->deleted = 1;
    noerrorShim();
    if(!glshader->attached) {
''',
        '''    glshader->deleted = 1;
    tsp_native_life_shader_delete_request(glshader->id, glshader->attached, glshader->attached ? 0 : 1);
    noerrorShim();
    if(!glshader->attached) {
''',
        "shader delete request accounting",
    )

    s = rep(
        s,
        '''            gles_glDeleteShader(shader);
        }   
''',
        '''            gles_glDeleteShader(shader);
            tsp_native_life_shader_native_deleted(shader);
        }   
''',
        "native shader delete accounting",
    )

    p.write_text(s)
    print("PATCHED shader.c")
else:
    print("ALREADY shader.c")

# ------------------------------------------------------------------
# Native program accounting + actual CPU uniform-cache leak fix.
# ------------------------------------------------------------------
p = gl / "src/gl/program.c"
s = p.read_text()

if "TSP_PROGRAM_LIFETIME_DIAG_V13" not in s:
    anchor = 'GLuint APIENTRY_GL4ES gl4es_glCreateProgram(void) {\n'
    s = rep(
        s,
        anchor,
        '''/* TSP_PROGRAM_LIFETIME_DIAG_V13 */
void tsp_native_life_program_generated(GLuint id);
void tsp_native_life_program_deleted(GLuint id);

''' + anchor,
        "program declarations",
    )

    s = rep(
        s,
        '    // store the new empty shader in the list for later use\n',
        '    tsp_native_life_program_generated(program);\n    // store the new empty shader in the list for later use\n',
        "program create accounting",
    )

    s = rep(
        s,
        '''        gles_glDeleteProgram(glprogram->id);
        errorGL();
''',
        '''        gles_glDeleteProgram(glprogram->id);
        tsp_native_life_program_deleted(glprogram->id);
        errorGL();
''',
        "program delete accounting",
    )

    s = rep(
        s,
        '''    if(glprogram->cache.cap < uniform_cache) {
        glprogram->cache.cap=uniform_cache;
        glprogram->cache.cache = malloc(glprogram->cache.cap);
    }
    memset(glprogram->cache.cache, 0, glprogram->cache.cap);
''',
        '''    /* TSP_PROGRAM_CACHE_REALLOC_FIX_V13
     * Growing this cache used to overwrite the previous malloc pointer.
     */
    if(glprogram->cache.cap < uniform_cache) {
        void* tsp_new_cache = realloc(glprogram->cache.cache, uniform_cache);
        if(!tsp_new_cache && uniform_cache) {
            LOGE("TSP_PROGRAM_CACHE_REALLOC_FIX_V13 allocation failed size=%u\\n", uniform_cache);
            return;
        }
        glprogram->cache.cache = tsp_new_cache;
        glprogram->cache.cap = uniform_cache;
    }
    if(glprogram->cache.cache && glprogram->cache.cap)
        memset(glprogram->cache.cache, 0, glprogram->cache.cap);
''',
        "uniform cache leak",
    )

    p.write_text(s)
    print("PATCHED program.c")
else:
    print("ALREADY program.c")

# ------------------------------------------------------------------
# Map fix: child occlusion callbacks must positively scope to SceneCamera.
# ------------------------------------------------------------------
p = omw / "apps/openmw/mwrender/occlusionculling.cpp"
s = p.read_text()

if "TSP_RTTOCC_CAMERA_GUARD_V13" not in s:
    s = rep(
        s,
        '''    void PagedOccluderCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)
    {
        if (!mCuller->isFrameActive())
''',
        '''    void PagedOccluderCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)
    {
        // TSP_RTTOCC_CAMERA_GUARD_V13
        osg::Camera* tspCurrentCamera = cv ? cv->getCurrentCamera() : nullptr;
        if (tspCurrentCamera == nullptr || tspCurrentCamera->getName() != Constants::SceneCamera)
        {
            const char* tspDiag = std::getenv("TSP_RTTOCC_DIAG");
            static unsigned int tspWrongCameraLogs = 0;
            if (mCuller->isFrameActive() && tspDiag && tspDiag[0] == '1' && tspWrongCameraLogs < 128)
            {
                ++tspWrongCameraLogs;
                Log(Debug::Warning) << "TSP_RTTOCC_WRONGCAM_V13 callback=paged active=1 camera="
                                    << (tspCurrentCamera ? tspCurrentCamera->getName() : "<null>")
                                    << " count=" << tspWrongCameraLogs;
            }
            traverse(node, cv);
            return;
        }

        if (!mCuller->isFrameActive())
''',
        "paged camera guard",
    )

    s = rep(
        s,
        '''    void CellOcclusionCallback::operator()(osg::Group* node, osgUtil::CullVisitor* cv)
    {
        // If occlusion is not active this frame (interior, shadow camera, etc.), traverse normally
        if (!mCuller->isFrameActive())
''',
        '''    void CellOcclusionCallback::operator()(osg::Group* node, osgUtil::CullVisitor* cv)
    {
        // TSP_RTTOCC_CAMERA_GUARD_V13
        osg::Camera* tspCurrentCamera = cv ? cv->getCurrentCamera() : nullptr;
        if (tspCurrentCamera == nullptr || tspCurrentCamera->getName() != Constants::SceneCamera)
        {
            const char* tspDiag = std::getenv("TSP_RTTOCC_DIAG");
            static unsigned int tspWrongCameraLogs = 0;
            if (mCuller->isFrameActive() && tspDiag && tspDiag[0] == '1' && tspWrongCameraLogs < 128)
            {
                ++tspWrongCameraLogs;
                Log(Debug::Warning) << "TSP_RTTOCC_WRONGCAM_V13 callback=cell active=1 camera="
                                    << (tspCurrentCamera ? tspCurrentCamera->getName() : "<null>")
                                    << " count=" << tspWrongCameraLogs;
            }
            traverse(node, cv);
            return;
        }

        // If occlusion is not active this frame, traverse normally.
        if (!mCuller->isFrameActive())
''',
        "cell camera guard",
    )

    p.write_text(s)
    print("PATCHED occlusionculling.cpp")
else:
    print("ALREADY occlusionculling.cpp")

# ------------------------------------------------------------------
# Map teardown fix: LocalMap::clear must drain outstanding one-shot RTTs.
# ------------------------------------------------------------------
p = omw / "apps/openmw/mwrender/localmap.cpp"
s = p.read_text()

if "TSP_LOCALMAP_CAMERA_DRAIN_V13" not in s:
    old = '''    void LocalMap::clear()
    {
        ++tspMapLifeGeneration;

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_begin"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }

        mExteriorSegments.clear();
        mInteriorSegments.clear();

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_end"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }
    }
'''
    new = '''    void LocalMap::clear()
    {
        ++tspMapLifeGeneration;
        const std::size_t tspRttBefore = mLocalMapRTTs.size();

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_begin"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << tspRttBefore;
        }

        // TSP_LOCALMAP_CAMERA_DRAIN_V13
        // A save-load clear is a hard lifetime boundary for one-shot PRE_RENDER
        // local-map RTT cameras. Do not leave them attached until a later GUI frame.
        for (auto& rtt : mLocalMapRTTs)
        {
            if (rtt)
            {
                rtt->setNodeMask(0);
                mRoot->removeChild(rtt);
            }
        }
        mLocalMapRTTs.clear();

        mExteriorSegments.clear();
        mInteriorSegments.clear();

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_CAMERA_DRAIN_V13"
                << " gen=" << tspMapLifeGeneration
                << " drained=" << tspRttBefore
                << " remaining=" << mLocalMapRTTs.size();

            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_end"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }
    }
'''
    s = rep(s, old, new, "local map camera drain")
    p.write_text(s)
    print("PATCHED localmap.cpp")
else:
    print("ALREADY localmap.cpp")

print("SOURCE PATCH COMPLETE")
PY

docker exec "$CONTAINER" bash -c "
set -e
grep -q TSP_MEMMAP_NATIVE_DIAG_V13 '$GLSRC/src/gl/framebuffers.c'
grep -q TSP_NATIVE_BUFFER_DIAG_V13 '$GLSRC/src/gl/buffers.c'
grep -q TSP_SHADER_LIFETIME_DIAG_V13 '$GLSRC/src/gl/shader.c'
grep -q TSP_PROGRAM_CACHE_REALLOC_FIX_V13 '$GLSRC/src/gl/program.c'
grep -q TSP_RTTOCC_CAMERA_GUARD_V13 '$OMWSRC/apps/openmw/mwrender/occlusionculling.cpp'
grep -q TSP_LOCALMAP_CAMERA_DRAIN_V13 '$OMWSRC/apps/openmw/mwrender/localmap.cpp'
" || fail 30 "source verification failed"

echo
echo "[4/11] BUILDING TSP GL4ES FROM THE SAME WORKING TREE"

docker exec "$CONTAINER" bash -lc \
    "bash /root/rebuild_gl4es_tsp_pvr_texture_v2.sh" \
    || fail 40 "gl4es rebuild failed"

GL_EXPORT="/root/gl4es-tsp-pvr-texture-v2-export-o3/libGL.so.1"
docker exec "$CONTAINER" test -f "$GL_EXPORT" \
    || fail 41 "expected gl4es export missing"

echo
echo "[5/11] BUILDING OPENMW INCREMENTALLY"

if ! docker exec "$CONTAINER" bash -lc \
    "cmake --build '$OMWBUILD' --target openmw -- -j2"
then
    echo "Parallel build failed; retrying the SAME configured build at -j1."
    docker exec "$CONTAINER" bash -lc \
        "cmake --build '$OMWBUILD' --target openmw -- -j1" \
        || fail 50 "OpenMW build failed at -j2 and -j1"
fi

OMW_BUILT="$(docker exec "$CONTAINER" bash -lc '
for b in /root/openmw-0.51-tsp-build/openmw /root/openmw-0.51-tsp-build/apps/openmw/openmw; do
    if [ -f "$b" ] && [ -x "$b" ]; then printf "%s\n" "$b"; exit 0; fi
done
find /root/openmw-0.51-tsp-build -type f -name openmw -perm -111 2>/dev/null | head -n1
')"

[ -n "$OMW_BUILT" ] || fail 51 "could not locate rebuilt OpenMW"
echo "OpenMW built binary: $OMW_BUILT"

echo
echo "[6/11] EXPORTING + VERIFYING COMPILED RUNTIME MARKERS"

rm -f "$LOCAL_GL" "$LOCAL_OMW"
docker cp "$CONTAINER:$GL_EXPORT" "$LOCAL_GL" >/dev/null || fail 60 "libGL export failed"
docker cp "$CONTAINER:$OMW_BUILT" "$LOCAL_OMW" >/dev/null || fail 60 "OpenMW export failed"
chmod +x "$LOCAL_OMW"

for marker in TSP_NATIVE_LIFE_DIAG_V3 TSP_MEMMAP_NATIVE_DIAG_V13 GEN_BUF REQ_DEL_SHADER GEN_PROGRAM; do
    grep -a -q "$marker" "$LOCAL_GL" || fail 61 "compiled libGL missing runtime marker: $marker"
done

for marker in TSP_RTTOCC_WRONGCAM_V13 TSP_LOCALMAP_CAMERA_DRAIN_V13; do
    grep -a -q "$marker" "$LOCAL_OMW" || fail 62 "compiled OpenMW missing runtime marker: $marker"
done

NEW_GL_SHA="$(sha256sum "$LOCAL_GL" | awk '{print $1}')"
NEW_OMW_SHA="$(sha256sum "$LOCAL_OMW" | awk '{print $1}')"

echo "new_tsp_libgl=$NEW_GL_SHA"
echo "new_tsp_openmw=$NEW_OMW_SHA"

echo
echo "[7/11] DERIVING V13 LAUNCHER FROM V12"

cp -p "$LOCAL_V12" "$LOCAL_V13"

python3 - "$LOCAL_V13" <<'PY_LAUNCH'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if "TSP_MEMMAP_LAUNCH_V13" not in s:
    old = '''        export TSP_GL4ES_OVERRIDE="$TSP_PVR_TEXTURE_SIDE"
        echo "TSP_PVR_TEXTURE_FORK_V2 selected=1 lib=$TSP_PVR_TEXTURE_SIDE"
    else
        unset TSP_GL4ES_OVERRIDE
        echo "TSP_PVR_TEXTURE_FORK_V2 selected=0 using production libGL"
    fi
'''
    new = '''        export TSP_GL4ES_OVERRIDE="$TSP_PVR_TEXTURE_SIDE"

        # TSP_MEMMAP_LAUNCH_V13
        TSP_MEMMAP_OPENMW="$GAMEDIR/bin/openmw-0.51.tsp-memmap-v13"
        if [ ! -x "$TSP_MEMMAP_OPENMW" ]; then
            echo "ERROR: V13 TSP OpenMW sidecar missing: $TSP_MEMMAP_OPENMW"
            exit 75
        fi
        OPENMW_BIN="$TSP_MEMMAP_OPENMW"
        export TSP_RTTOCC_DIAG=1

        echo "TSP_PVR_TEXTURE_FORK_V2 selected=1 lib=$TSP_PVR_TEXTURE_SIDE"
        echo "TSP_MEMMAP_LAUNCH_V13 selected=1 openmw=$OPENMW_BIN rttocc_diag=1"
    else
        unset TSP_GL4ES_OVERRIDE
        unset TSP_RTTOCC_DIAG
        echo "TSP_PVR_TEXTURE_FORK_V2 selected=0 using production libGL"
        echo "TSP_MEMMAP_LAUNCH_V13 selected=0 using production OpenMW"
    fi
'''
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: V12 launcher anchor count={n}")
    s = s.replace(old, new, 1)

p.write_text(s)
print("PASS: V13 launcher patched")
PY_LAUNCH

chmod +x "$LOCAL_V13"
grep -q TSP_MEMMAP_LAUNCH_V13 "$LOCAL_V13" || fail 70 "V13 launcher marker missing"

echo
echo "[8/11] BUILDING MATCHING DEVICE-LOCAL DIAGNOSTIC PULL"

cat > "$LOCAL_PULL" <<'PULL'
#!/bin/sh
(
ROOT="/mnt/mmc/ports/openmw"
PORTS="/mnt/mmc/ROMS/Ports"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/tsp_memmap_v13_$STAMP.tar"
TMP="$ROOT/.tsp_memmap_v13_pull_$$"

cleanup_pull() {
    rm -rf "$TMP" 2>/dev/null || true
}

echo "========================================"
echo "V13 MEMORY + MAP DIAGNOSTIC PULL"
echo "========================================"
echo "$OUT"
echo

rm -rf "$TMP" 2>/dev/null || true

if ! mkdir -p "$TMP"; then
    echo "ERROR: could not create $TMP"
else
    echo "[1/7] Identity"
    {
        echo "collected=$(date)"
        uname -a 2>/dev/null || true
        echo
        echo "===== V13 LAUNCHER ====="
        sha256sum "$PORTS/Morrowind-TSP-MEMMAP-DIAG-V13.sh" 2>/dev/null || true
        echo
        echo "===== PRODUCTION LIBGL ====="
        sha256sum "$ROOT/lib/libGL.so.1" 2>/dev/null || true
        echo
        echo "===== TSP V13 LIBGL ====="
        sha256sum "$ROOT/lib.tsp-pvr-texture-v2/libGL.so.1" 2>/dev/null || true
        echo
        echo "===== PRODUCTION OPENMW ====="
        sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null || true
        echo
        echo "===== TSP V13 OPENMW ====="
        sha256sum "$ROOT/bin/openmw-0.51.tsp-memmap-v13" 2>/dev/null || true
        echo
        echo "===== MAP-DIAG IDENTITY ====="
        cat "$ROOT/tsp_map_diag/latest/identity.txt" 2>/dev/null || true
    } > "$TMP/identity.txt" 2>&1

    echo "[2/7] Complete map/native diagnostics"
    if [ -d "$ROOT/tsp_map_diag/latest" ]; then
        cp -pr "$ROOT/tsp_map_diag/latest" "$TMP/map-diag-latest" 2>/dev/null || true
    else
        echo "MISSING: tsp_map_diag/latest" > "$TMP/map-diag-MISSING.txt"
    fi

    echo "[3/7] OpenMW + focused events"
    [ -f "$ROOT/openmw_log.txt" ] && cp -p "$ROOT/openmw_log.txt" "$TMP/" 2>/dev/null || true
    {
        echo "===== MAP CAMERA / RTT ====="
        grep -E \
          'TSP_RTTOCC_WRONGCAM_V13|TSP_LOCALMAP_CAMERA_DRAIN_V13|TSP_MAPLIFE_V2|TSP_GMAP_MEM_V1' \
          "$ROOT/openmw_log.txt" 2>/dev/null || true
        echo
        echo "===== LOAD MEMORY ====="
        grep -E \
          'TSP_LOADMEM_V1|TSP_LOAD_TRACE_051_V13|TSP_MEMGATE_V1|cleanup-done' \
          "$ROOT/openmw_log.txt" 2>/dev/null || true
        echo
        echo "===== SHADER PREWARM ====="
        grep -E \
          'TSP_WARMDRAW|TSP_PRECOMPILE|TSP_DEDUP|TSP_VARIANT|TSP_LOAD_FREEZE' \
          "$ROOT/openmw_log.txt" 2>/dev/null || true
    } > "$TMP/v13-focused-openmw.txt" 2>&1

    echo "[4/7] Freeze monitor"
    [ -d "$ROOT/tsp_freeze_monitor/latest" ] \
        && cp -pr "$ROOT/tsp_freeze_monitor/latest" "$TMP/freeze-monitor-latest" 2>/dev/null || true

    echo "[5/7] PowerVR + memory state"
    {
        echo "===== PVR DRIVER STATS ====="
        cat /sys/kernel/debug/pvr/driver_stats 2>/dev/null || true
        echo
        echo "===== PVR DEFER/FREE ====="
        for f in /sys/kernel/debug/pvr/*defer* /sys/kernel/debug/pvr/*free*; do
            [ -f "$f" ] || continue
            echo "--- $f ---"
            head -n 1000 "$f" 2>/dev/null || true
        done
        echo
        echo "===== MEMINFO ====="
        cat /proc/meminfo 2>/dev/null || true
        echo
        echo "===== SWAPS ====="
        cat /proc/swaps 2>/dev/null || true
        echo
        echo "===== ZRAM ====="
        zramctl 2>/dev/null || true
        cat /sys/block/zram0/mm_stat 2>/dev/null || true
        echo
        echo "===== VMSTAT ====="
        grep -E \
          '^(pgmajfault|pswpin|pswpout|pgscan_|pgsteal_|allocstall|compact_|oom_kill)' \
          /proc/vmstat 2>/dev/null || true
    } > "$TMP/current-system.txt" 2>&1

    echo "[6/7] Kernel log"
    dmesg > "$TMP/dmesg.txt" 2>/dev/null || true

    echo "[7/7] Building archive"
    cd "$ROOT" 2>/dev/null || true

    if [ "$PWD" != "$ROOT" ]; then
        echo "ERROR: could not enter $ROOT"
        cleanup_pull
    else
        rm -f "$OUT" 2>/dev/null || true
        if tar -cf "$OUT" "$(basename "$TMP")"; then
            cleanup_pull
            sync
            echo
            echo "========================================"
            echo "V13 DIAGNOSTIC PULL COMPLETE"
            echo "========================================"
            echo "$OUT"
            sha256sum "$OUT" 2>/dev/null || true
            ls -lh "$OUT" 2>/dev/null || true
            if tar -tf "$OUT" >/dev/null 2>&1; then
                echo "PASS: archive readable"
            else
                echo "ERROR: archive validation failed"
            fi
        else
            RC=$?
            echo "ERROR: tar failed rc=$RC"
            echo "LobiShell should remain open."
            rm -f "$OUT" 2>/dev/null || true
            cleanup_pull
        fi
    fi
fi

echo
echo "Returned safely to LobiShell."
)
PULL

chmod +x "$LOCAL_PULL"

echo
echo "[9/11] BACKING UP + INSTALLING TSP-ONLY DEVICE FILES"

REMOTE_BACK="$ROOT/tsp_patch_backups/memmap-v13-pre-$STAMP"

ssh -S "$SOCK" -o BatchMode=yes "$HOST" "
set -e
mkdir -p '$REMOTE_BACK'
cp -p '$TSP_GL' '$REMOTE_BACK/libGL.so.1.tsp-v12.before'
sha256sum '$TSP_GL' > '$REMOTE_BACK/libGL.so.1.tsp-v12.before.sha256'
cp -p '$ROOT/bin/openmw-0.51' '$REMOTE_BACK/openmw-0.51.production.reference'
sha256sum '$ROOT/bin/openmw-0.51' > '$REMOTE_BACK/openmw-0.51.production.reference.sha256'
[ -f '$V12_LAUNCHER' ] && cp -p '$V12_LAUNCHER' '$REMOTE_BACK/' || true
[ -f '$V13_LAUNCHER' ] && cp -p '$V13_LAUNCHER' '$REMOTE_BACK/V13-launcher.previous' || true
[ -f '$V13_OMW' ] && cp -p '$V13_OMW' '$REMOTE_BACK/openmw-v13.previous' || true
"

scp -q -o ControlPath="$SOCK" "$LOCAL_GL" "$HOST:$TSP_GL.new-$STAMP" \
    || fail 90 "libGL transfer failed"
scp -q -o ControlPath="$SOCK" "$LOCAL_OMW" "$HOST:$V13_OMW.new-$STAMP" \
    || fail 90 "OpenMW transfer failed"
scp -q -o ControlPath="$SOCK" "$LOCAL_V13" "$HOST:$V13_LAUNCHER.new-$STAMP" \
    || fail 90 "launcher transfer failed"
scp -q -o ControlPath="$SOCK" "$LOCAL_PULL" "$HOST:$V13_PULL.new-$STAMP" \
    || fail 90 "diagnostic pull transfer failed"

ssh -S "$SOCK" -o BatchMode=yes "$HOST" "
set -e
test \"\$(sha256sum '$TSP_GL.new-$STAMP' | awk '{print \$1}')\" = '$NEW_GL_SHA'
test \"\$(sha256sum '$V13_OMW.new-$STAMP' | awk '{print \$1}')\" = '$NEW_OMW_SHA'
chmod 755 '$TSP_GL.new-$STAMP' '$V13_OMW.new-$STAMP' '$V13_LAUNCHER.new-$STAMP' '$V13_PULL.new-$STAMP'
mv -f '$TSP_GL.new-$STAMP' '$TSP_GL'
mv -f '$V13_OMW.new-$STAMP' '$V13_OMW'
mv -f '$V13_LAUNCHER.new-$STAMP' '$V13_LAUNCHER'
mv -f '$V13_PULL.new-$STAMP' '$V13_PULL'
sync
" || fail 91 "device install failed"

echo
echo "[10/11] FINAL DEVICE VERIFICATION"

FINAL_PROD_SHA="$(ssh -S "$SOCK" -o BatchMode=yes "$HOST" \
    "sha256sum '$PROD_GL' | awk '{print \$1}'")"
FINAL_PROD_OMW_SHA="$(ssh -S "$SOCK" -o BatchMode=yes "$HOST" \
    "sha256sum '$ROOT/bin/openmw-0.51' | awk '{print \$1}'")"
FINAL_TSP_SHA="$(ssh -S "$SOCK" -o BatchMode=yes "$HOST" \
    "sha256sum '$TSP_GL' | awk '{print \$1}'")"
FINAL_OMW_SHA="$(ssh -S "$SOCK" -o BatchMode=yes "$HOST" \
    "sha256sum '$V13_OMW' | awk '{print \$1}'")"

[ "$FINAL_PROD_SHA" = "$EXPECTED_PROD_GL" ] || fail 100 "production libGL changed"
[ "$FINAL_PROD_OMW_SHA" = "$PROD_OMW_SHA" ] || fail 100 "production OpenMW changed"
[ "$FINAL_TSP_SHA" = "$NEW_GL_SHA" ] || fail 101 "installed TSP libGL hash mismatch"
[ "$FINAL_OMW_SHA" = "$NEW_OMW_SHA" ] || fail 101 "installed V13 OpenMW hash mismatch"

ssh -S "$SOCK" -o BatchMode=yes "$HOST" "
set -e
grep -a -q TSP_MEMMAP_NATIVE_DIAG_V13 '$TSP_GL'
grep -a -q TSP_RTTOCC_WRONGCAM_V13 '$V13_OMW'
grep -q TSP_MEMMAP_LAUNCH_V13 '$V13_LAUNCHER'
test -x '$V13_PULL'
" || fail 102 "installed runtime marker verification failed"

echo "production_libgl_unchanged=$FINAL_PROD_SHA"
echo "production_openmw_unchanged=$FINAL_PROD_OMW_SHA"
echo "tsp_v13_libgl=$FINAL_TSP_SHA"
echo "tsp_v13_openmw=$FINAL_OMW_SHA"

echo
echo "[11/11] COMPLETE"
echo
echo "============================================================"
echo "V13 INSTALLED"
echo "============================================================"
echo "Run on the ORIGINAL TSP:"
echo
echo "  Morrowind-TSP-MEMMAP-DIAG-V13.sh"
echo
echo "Test local/world map, then reload the same save 10-20 times."
echo "If it remains stable, keep playing afterward."
echo
echo "After exiting, in the already-authenticated LobiShell session run:"
echo
echo "  sh /mnt/mmc/ports/openmw/tsp_memmap_v13_pull.sh"
echo
echo "Upload the resulting:"
echo "  /mnt/mmc/ports/openmw/tsp_memmap_v13_YYYYMMDD-HHMMSS.tar"
echo
echo "Source backup:"
echo "  /root/tsp_patch_backups/memmap-v13-pre-$STAMP"
echo "Device backup:"
echo "  $REMOTE_BACK"
echo
echo "No new source fork was created."
echo "TSPS/Mali production files were verified unchanged."
