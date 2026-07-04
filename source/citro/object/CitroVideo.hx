package citro.object;

@:headerCode('
#include <errno.h>
#include <sys/time.h>
#include <theora/theoradec.h>
#include <tremor/ivorbiscodec.h>
#include <citro2d.h>
#include <citro3d.h>
#include <3ds.h>

typedef struct tf_callbacks {
    size_t (*read_func)  (void *ptr, size_t size, size_t nmemb, void *datasource);
    int    (*seek_func)  (void *datasource, ogg_int64_t offset, int whence);
    int    (*close_func) (void *datasource);
    long   (*tell_func)  (void *datasource);
} THEORA_callbacks;

typedef struct {
    int width;
    int height;
    double fps;
    th_pixel_fmt fmt;
    th_colorspace colorspace;
} THEORA_videoinfo;

typedef struct {
    int channels;
    int rate;
} THEORA_audioinfo;

typedef struct {
    ogg_sync_state sync;
    ogg_page page;
    int eos;
    int tpackets;
    int vpackets;
    ogg_stream_state tstream;
    ogg_stream_state vstream;
    th_info tinfo;
    th_comment tcomment;
    vorbis_info vinfo;
    vorbis_comment vcomment;
    th_dec_ctx *tdec;
    int pp_level_max;
    int pp_level;
    int pp_inc;
    int vdsp_init;
    vorbis_dsp_state vdsp;
    int vblock_init;
    vorbis_block vblock;
    THEORA_callbacks io;
    void *datasource;
    THEORA_videoinfo videoinfo;
    THEORA_audioinfo audioinfo;
    int frames;
    int dropped;
    double videobuf_time;
    ogg_int64_t timer_calibrate;
    int vstate;
} THEORA_Context;

typedef struct theora_3ds_vframe {
    C2D_Image img;
    C3D_Tex buff[2];
    bool curbuf;
} TH3DS_Frame;
')
@:headerClassCode('
THEORA_Context vidCtx;
TH3DS_Frame frame;
Handle y2rEventHandle;
ogg_int64_t pauseStart = 0;

int THEORA_Create(THEORA_Context* ctx, const char* filepath);
void THEORA_Close(THEORA_Context *ctx);
bool THEORA_HasVideo(THEORA_Context *ctx);
bool THEORA_HasAudio(THEORA_Context *ctx);
THEORA_videoinfo* THEORA_vidinfo(THEORA_Context *ctx);
THEORA_audioinfo* THEORA_audinfo(THEORA_Context *ctx);
int THEORA_eos(THEORA_Context *ctx);
int THEORA_getvideo(THEORA_Context *ctx, th_ycbcr_buffer ybr);
int THEORA_readaudio(THEORA_Context *ctx, char *bufferOut, int buffSize);
int THEORA_gettime(THEORA_Context *ctx);

int frameInit(TH3DS_Frame* vframe, THEORA_videoinfo* info);
void frameDelete(TH3DS_Frame* vframe);
void frameWrite(TH3DS_Frame* vframe, THEORA_videoinfo* info, th_ycbcr_buffer ybr);
')
@:cppFileCode('
#define VIDEO_DEFAULT_BUFFER_SIZE 524288
static char oggDebugBuf[8192];
static int oggDebugLen = 0;

static inline int oggGetData(THEORA_Context *ctx) {
    errno = 0;

    if(!(ctx->io.read_func))
        return -1;

    if(ctx->datasource) {
        char *buffer = ogg_sync_buffer(&ctx->sync, VIDEO_DEFAULT_BUFFER_SIZE);
        long bytes = ctx->io.read_func(buffer, 1, VIDEO_DEFAULT_BUFFER_SIZE, ctx->datasource);

        long pos = ftell((FILE*)ctx->datasource);
        if(bytes>0) ogg_sync_wrote(&ctx->sync, bytes);
        if(bytes==0 && errno) return -1;
        return bytes;
    } else
        return 0;
}

static inline void oggQueuePage(THEORA_Context *ctx) {
    if (ctx->tpackets) ogg_stream_pagein(&ctx->tstream, &ctx->page);
    if (ctx->vpackets) ogg_stream_pagein(&ctx->vstream, &ctx->page);
}

static inline int oggGetNextPacket(THEORA_Context *ctx, ogg_stream_state *stream, ogg_packet *packet) {
    while (ogg_stream_packetout(stream, packet) <= 0) {
        const int rc = oggGetData(ctx);
        if (rc <= 0) { ctx->eos = 1; return 0; }
        else { while (ogg_sync_pageout(&ctx->sync, &ctx->page) > 0) oggQueuePage(ctx); }
    }
    return 1;
}

static inline ogg_int32_t CLIP_TO_15(ogg_int32_t x) {
    int ret = x;
    ret -= ((x<=32767)-1)&(x-32767);
    ret -= ((x>=-32768)-1)&(x+32768);
    return ret;
}


int THEORA_CallbackCreate(THEORA_Context* ctx, void* datasource, THEORA_callbacks* io) {
    if (!ctx || !datasource) return 1;
    ogg_packet packet;
    th_setup_info *tsetup = NULL;
    memset(ctx, 0, sizeof(THEORA_Context));
    ctx->timer_calibrate = -1;
    ctx->datasource = datasource;
    ctx->io = *io;

    ogg_sync_init(&ctx->sync);
    vorbis_info_init(&ctx->vinfo);
    vorbis_comment_init(&ctx->vcomment);
    th_info_init(&ctx->tinfo);
    th_comment_init(&ctx->tcomment);

    bool stateflag = false;
    while (!stateflag) {
        int ret = oggGetData(ctx);
        if (ret == 0) break;
        while (ogg_sync_pageout(&ctx->sync, &ctx->page) > 0) {
            ogg_stream_state test;
            if (!ogg_page_bos(&ctx->page)) { oggQueuePage(ctx); stateflag=1; break; }
            ogg_stream_init(&test, ogg_page_serialno(&ctx->page));
            ogg_stream_pagein(&test, &ctx->page);
            ogg_stream_packetout(&test, &packet);
            if(!ctx->tpackets && th_decode_headerin(&ctx->tinfo, &ctx->tcomment, &tsetup, &packet)>=0){
                memcpy(&ctx->tstream, &test, sizeof(test));
                ctx->tpackets = 1;
            }else if(!ctx->vpackets && vorbis_synthesis_headerin(&ctx->vinfo, &ctx->vcomment, &packet)>=0){
                memcpy(&ctx->vstream, &test, sizeof(test));
                ctx->vpackets = 1;
            }else{
                ogg_stream_clear(&test);
            }
        }
    }

    bool decoderAllocated = false;
    bool havePendingDataPacket = false;
    ogg_packet pendingPacket;

    while((ctx->tpackets && (ctx->tpackets<3)) || (ctx->vpackets && (ctx->vpackets<3))){
        while(ctx->tpackets && (ctx->tpackets < 3)) {
            if (ogg_stream_packetout(&ctx->tstream, &packet) != 1) break;
            int hret = th_decode_headerin(&ctx->tinfo, &ctx->tcomment, &tsetup, &packet);
            if (hret < 0) return 1;
            ctx->tpackets++;
            if (hret == 0) {
                pendingPacket = packet;
                havePendingDataPacket = true;
                ctx->tpackets = 3;
                break;
            }
        }
        while(ctx->vpackets && (ctx->vpackets < 3)) {
            if (ogg_stream_packetout(&ctx->vstream, &packet) != 1) break;
            if(vorbis_synthesis_headerin(&ctx->vinfo, &ctx->vcomment, &packet)) return 1;
            ctx->vpackets++;
        }
        if (havePendingDataPacket) break;
        if(ogg_sync_pageout(&ctx->sync, &ctx->page)>0) {
            oggQueuePage(ctx);
        } else{
            if(oggGetData(ctx)==0) return 1;
        }
    }

    if (ctx->tpackets) {
        if((ctx->tinfo.frame_width > 99999) || (ctx->tinfo.frame_height > 99999)) return 3;
        ctx->tdec = th_decode_alloc(&ctx->tinfo, tsetup);
        decoderAllocated = true;
        th_decode_ctl(ctx->tdec, TH_DECCTL_GET_PPLEVEL_MAX, &ctx->pp_level_max, sizeof(ctx->pp_level_max));
        ctx->pp_level = ctx->pp_level_max;
        th_decode_ctl(ctx->tdec, TH_DECCTL_SET_PPLEVEL, &ctx->pp_level, sizeof(ctx->pp_level));

        double fps = 0;
        if (ctx->tinfo.fps_denominator) fps = ((double) ctx->tinfo.fps_numerator) / ((double) ctx->tinfo.fps_denominator);
        else fps = ctx->tinfo.fps_numerator;
        ctx->videoinfo.width = ((ctx->tinfo.pic_x + ctx->tinfo.frame_width + 1) & ~1) - (ctx->tinfo.pic_x & ~1);
        ctx->videoinfo.height = ((ctx->tinfo.pic_y + ctx->tinfo.frame_height + 1) & ~1) - (ctx->tinfo.pic_y & ~1);
        ctx->videoinfo.fps = fps;
        ctx->videoinfo.fmt = ctx->tinfo.pixel_fmt;
        ctx->videoinfo.colorspace = ctx->tinfo.colorspace;
    }

    if (ctx->vpackets) {
        ctx->audioinfo.channels = ctx->vinfo.channels;
        ctx->audioinfo.rate = ctx->vinfo.rate;
    }

    if (tsetup) th_setup_free(tsetup);

    if (ctx->vpackets) {
        ctx->vdsp_init = vorbis_synthesis_init(&ctx->vdsp, &ctx->vinfo) == 0;
        ctx->vblock_init = vorbis_block_init(&ctx->vdsp, &ctx->vblock) == 0;
    }

    if (havePendingDataPacket && decoderAllocated) {
        ogg_int64_t granulepos = 0;
        if(pendingPacket.granulepos>=0) th_decode_ctl(ctx->tdec,TH_DECCTL_SET_GRANPOS,&pendingPacket.granulepos, sizeof(pendingPacket.granulepos));
        int rc = th_decode_packetin(ctx->tdec, &pendingPacket, &granulepos);
        if (rc == 0) {
            ctx->videobuf_time = th_granule_time(ctx->tdec, granulepos);
            ctx->frames++;
        }
    }

    return 0;
}

static double get_time_th(THEORA_Context *ctx) {
    static ogg_int64_t last = 0;
    ogg_int64_t now;
    struct timeval tv;
    gettimeofday(&tv,0);
    now = tv.tv_sec*1000+tv.tv_usec/1000;
    if(ctx->timer_calibrate == -1) ctx->timer_calibrate = last = now;
    if(now-last > 1000) ctx->timer_calibrate += (now-last);
    last=now;
    return (now-ctx->timer_calibrate)*.001;
}

static int THEORAi_readvideo(THEORA_Context *ctx) {
    ogg_int64_t granulepos = 0;
    ogg_packet packet;
    int retval = 0;
    int rc;
    if (!oggGetNextPacket(ctx, &ctx->tstream, &packet)) return 0;

    if(ctx->pp_inc) {
        ctx->pp_level += ctx->pp_inc;
        th_decode_ctl(ctx->tdec, TH_DECCTL_SET_PPLEVEL, &ctx->pp_level, sizeof(ctx->pp_level));
        ctx->pp_inc=0;
    }
    if(packet.granulepos>=0) th_decode_ctl(ctx->tdec,TH_DECCTL_SET_GRANPOS,&packet.granulepos, sizeof(packet.granulepos));
    if((rc = th_decode_packetin(ctx->tdec, &packet, &granulepos)) == 0) {
        ctx->videobuf_time=th_granule_time(ctx->tdec, granulepos);
        ctx->frames++;
        if(ctx->videobuf_time<get_time_th(ctx)-0.5) {
            ctx->pp_inc=ctx->pp_level>0?-1:0;
            ctx->dropped++;
        } else {
            retval = 1;
        }
    }
    return retval;
}

static int THEORAi_decodevideo(THEORA_Context *ctx, th_ycbcr_buffer ybr) {
    double tdiff;
    tdiff=ctx->videobuf_time-get_time_th(ctx);
    if(tdiff>ctx->tinfo.fps_denominator*0.25/ctx->tinfo.fps_numerator) {
        ctx->pp_inc=ctx->pp_level<ctx->pp_level_max?1:0;
    }
    else if(tdiff<ctx->tinfo.fps_denominator*0.05/ctx->tinfo.fps_numerator) {
        ctx->pp_inc=ctx->pp_level>0?-1:0;
    }
    if (ctx->videobuf_time<=get_time_th(ctx)) {
        if (th_decode_ycbcr_out(ctx->tdec, ybr) != 0) return -1;
        return 1;
    }
    return 0;
}

static long ov_read_th(THEORA_Context *ctx, char *buffer, int bytes_req) {
    int i,j;
    ogg_int32_t **pcm;
    long samples;
    if(!ctx->vpackets) return -1;
    while(1) {
        samples=vorbis_synthesis_pcmout(&ctx->vdsp, &pcm);
        if(samples)break;
        ogg_packet packet;
        if (!oggGetNextPacket(ctx, &ctx->vstream, &packet)) return 0;
        if (vorbis_synthesis(&ctx->vblock, &packet) == 0) vorbis_synthesis_blockin(&ctx->vdsp, &ctx->vblock);
    }
    if(samples>0){
        long channels=ctx->vinfo.channels;
        if(samples>(bytes_req/(2*channels))) samples=bytes_req/(2*channels);
        for(i=0;i<channels;i++) {
            ogg_int32_t *src=pcm[i];
            short *dest=((short *)buffer)+i;
            for(j=0;j<samples;j++) { *dest=CLIP_TO_15(src[j]>>9); dest+=channels; }
        }
        vorbis_synthesis_read(&ctx->vdsp, samples);
        return(samples*2*channels);
    }else{
        return(samples);
    }
}

static inline unsigned bitCeil_th(unsigned x) {
    return x <= 1 ? 1 : (1u << (32 - __builtin_clz(x - 1)));
}

static inline size_t fmtGetBPP_th(GPU_TEXCOLOR fmt) {
    switch (fmt) {
        case GPU_RGBA8: return 4;
        case GPU_RGB8: return 3;
        default: return 0;
    }
}

namespace citro {
namespace object {

    int CitroVideo_obj::THEORA_Create(THEORA_Context* ctx, const char* filepath) {
        THEORA_callbacks io = {
            .read_func = (size_t (*) (void*, size_t, size_t, void*)) fread,
            .seek_func = (int (*) (void*, ogg_int64_t, int)) fseek,
            .close_func = (int (*) (void*)) fclose,
            .tell_func = (long int (*) (void*)) ftell,
        };
        FILE *fp = fopen(filepath, "rb");
        static char fileBuffer[VIDEO_DEFAULT_BUFFER_SIZE]; 
        setvbuf(fp, fileBuffer, _IOFBF, VIDEO_DEFAULT_BUFFER_SIZE);

        return THEORA_CallbackCreate(ctx, fp, &io);
    }

    void CitroVideo_obj::THEORA_Close(THEORA_Context *ctx) {
        if (ctx->tdec) th_decode_free(ctx->tdec);
        if (ctx->vblock_init) vorbis_block_clear(&ctx->vblock);
        if (ctx->vdsp_init) vorbis_dsp_clear(&ctx->vdsp);
        if (ctx->tpackets) ogg_stream_clear(&ctx->tstream);
        if (ctx->vpackets) ogg_stream_clear(&ctx->vstream);
        th_info_clear(&ctx->tinfo);
        th_comment_clear(&ctx->tcomment);
        vorbis_comment_clear(&ctx->vcomment);
        vorbis_info_clear(&ctx->vinfo);
        ogg_sync_clear(&ctx->sync);
        if (ctx->io.close_func) ctx->io.close_func(ctx->datasource);
    }

    int CitroVideo_obj::THEORA_gettime(THEORA_Context *ctx) {
        return (int)(ctx->videobuf_time * 1000.0);
    }

    bool CitroVideo_obj::THEORA_HasVideo(THEORA_Context *ctx) { return ctx->tpackets; }
    bool CitroVideo_obj::THEORA_HasAudio(THEORA_Context *ctx) { return ctx->vpackets; }
    THEORA_videoinfo* CitroVideo_obj::THEORA_vidinfo(THEORA_Context *ctx) { return &ctx->videoinfo; }
    THEORA_audioinfo* CitroVideo_obj::THEORA_audinfo(THEORA_Context *ctx) { return &ctx->audioinfo; }
    int CitroVideo_obj::THEORA_eos(THEORA_Context *ctx) { return ctx->eos; }

    int CitroVideo_obj::THEORA_getvideo(THEORA_Context *ctx, th_ycbcr_buffer ybr) {
        if (ctx->vstate == 0) if (THEORAi_readvideo(ctx)) ctx->vstate = 1;
        if (ctx->vstate == 1) {
            int ret = THEORAi_decodevideo(ctx, ybr);
            if (ret != 0) ctx->vstate = 0;
            return !!ret;
        }
        return 0;
    }

    int CitroVideo_obj::THEORA_readaudio(THEORA_Context *ctx, char *bufferOut, int buffSize) {
        uint64_t samplesRead = 0;
        int samplesToRead = buffSize;
        while(samplesToRead > 0) {
            int samplesJustRead = ov_read_th(ctx, bufferOut, samplesToRead > 4096 ? 4096 : samplesToRead);
            if(samplesJustRead < 0) return samplesJustRead;
            else if(samplesJustRead == 0) break;
            samplesRead += samplesJustRead;
            samplesToRead -= samplesJustRead;
            bufferOut += samplesJustRead;
        }
        return samplesRead / sizeof(int16_t);
    }

    int CitroVideo_obj::frameInit(TH3DS_Frame* vframe, THEORA_videoinfo* info) {
        if (!vframe || !info || y2rInit()) return 1;

        if (info->fmt == TH_PF_444) return 2;
        if (info->fmt == TH_PF_RSVD) return 2;

        for (int i = 0; i < 2; i++) {
            C3D_Tex* curtex = &vframe->buff[i];
            C3D_TexInit(curtex, bitCeil_th(info->width), bitCeil_th(info->height), GPU_RGB8);
            C3D_TexSetFilter(curtex, GPU_LINEAR, GPU_LINEAR);
            memset(curtex->data, 0, curtex->size);
        }

        Tex3DS_SubTexture* subtex = (Tex3DS_SubTexture*)malloc(sizeof(Tex3DS_SubTexture));
        subtex->width = info->width;
        subtex->height = info->height;
        subtex->left = 0.0f;
        subtex->top = 1.0f;
        subtex->right = (float)info->width/bitCeil_th(info->width);
        subtex->bottom = 1.0-((float)info->height/bitCeil_th(info->height));

        vframe->curbuf = false;
        vframe->img.tex = &vframe->buff[vframe->curbuf];
        vframe->img.subtex = subtex;

        return 0;
    }

    void CitroVideo_obj::frameDelete(TH3DS_Frame* vframe) {
        if (!vframe) return;
        Y2RU_StopConversion();
        if (vframe->buff[0].data) {
            C3D_TexDelete(&vframe->buff[0]);
            C3D_TexDelete(&vframe->buff[1]);
        }
        if (vframe->img.subtex) free((void*)vframe->img.subtex);
        y2rExit();
    }

    void CitroVideo_obj::frameWrite(TH3DS_Frame* vframe, THEORA_videoinfo* info, th_ycbcr_buffer ybr) {
        bool is_busy = false;
        Y2RU_IsBusyConversion(&is_busy);

        if (is_busy) return;

        bool drawbuf = !vframe->curbuf;
        C3D_Tex* wframe = &vframe->buff[drawbuf];

        if (!vframe || !info) return;
        if (!ybr[0].data || !ybr[1].data || !ybr[2].data) return;

        Y2RU_StopConversion();
        while (is_busy) Y2RU_IsBusyConversion(&is_busy);

        if (info->fmt == TH_PF_420) Y2RU_SetInputFormat(INPUT_YUV420_INDIV_8);
        else if (info->fmt == TH_PF_422) Y2RU_SetInputFormat(INPUT_YUV422_INDIV_8);

        Y2RU_SetOutputFormat(OUTPUT_RGB_24);
        Y2RU_SetRotation(ROTATION_NONE);
        Y2RU_SetBlockAlignment(BLOCK_8_BY_8);
        Y2RU_SetTransferEndInterrupt(true);
        Y2RU_SetInputLineWidth(info->width);
        Y2RU_SetInputLines(info->height);
        Y2RU_SetStandardCoefficient(COEFFICIENT_ITU_R_BT_601_SCALING);
        Y2RU_SetAlpha(0xFF);

        Y2RU_SetSendingY(ybr[0].data, info->width * info->height, info->width, ybr[0].stride - info->width);
        Y2RU_SetSendingU(ybr[1].data, (info->width/2) * (info->height/2), info->width/2, ybr[1].stride - (info->width >> 1));
        Y2RU_SetSendingV(ybr[2].data, (info->width/2) * (info->height/2), info->width/2, ybr[2].stride - (info->width >> 1));

        Y2RU_SetReceiving(wframe->data, info->width * info->height * fmtGetBPP_th(wframe->fmt), info->width * 8 * fmtGetBPP_th(wframe->fmt), (bitCeil_th(info->width) - info->width) * 8 * fmtGetBPP_th(wframe->fmt));
        Y2RU_StartConversion();

        vframe->curbuf = drawbuf;
        vframe->img.tex = wframe;
    }

} // namespace object
} // namespace citro
')
class CitroVideo extends citro.object.CitroObject {
    public var playing(default, null):Bool = false;
    public var paused(default, null):Bool = false;
    public var hasVideo(default, null):Bool = false;
    public var hasAudio(default, null):Bool = false;
    public var frameWidth:Int = 0;
    public var frameHeight:Int = 0;

    public var currentTime(get, never):Float;
    public function get_currentTime():Float {
        if (!hasVideo) return -1;
        return (untyped __cpp__('THEORA_gettime(&vidCtx)')) / 1000;
    }

    public function new() {
        super();
    }

    public function load(path:String):Bool {
        var ok:Bool = untyped __cpp__('THEORA_Create(&vidCtx, {0}.c_str()) == 0', path);
        if (!ok) return false;

        hasVideo = untyped __cpp__('(bool)THEORA_HasVideo(&vidCtx)');
        hasAudio = untyped __cpp__('(bool)THEORA_HasAudio(&vidCtx)');

        if (!hasVideo && !hasAudio) return false;

        if (hasVideo) {
            var initRes:Int = untyped __cpp__('frameInit(&frame, THEORA_vidinfo(&vidCtx))');
            if (initRes != 0) return false;
            frameWidth = untyped __cpp__('THEORA_vidinfo(&vidCtx)->width');
            frameHeight = untyped __cpp__('THEORA_vidinfo(&vidCtx)->height');
        }

        playing = true;
        paused = false;
        untyped __cpp__('vidCtx.timer_calibrate = -1;');
        return true;
    }

    public function pause() {
        if (!playing || paused) return;
        paused = true;
        untyped __cpp__('
            struct timeval tv;
            gettimeofday(&tv, 0);
            pauseStart = tv.tv_sec*1000+tv.tv_usec/1000;
        ');
    }

    public function resume() {
        if (!playing || !paused) return;
        untyped __cpp__('
            struct timeval tv;
            gettimeofday(&tv, 0);
            ogg_int64_t now = tv.tv_sec*1000+tv.tv_usec/1000;
            vidCtx.timer_calibrate += (now - pauseStart);
        ');
        paused = false;
    }

    public function tick() {
        if (!playing || paused) return;

        var isEos:Bool = untyped __cpp__('(bool)THEORA_eos(&vidCtx)');
        if (isEos) {
            playing = false;
            return;
        }

        if (hasVideo) {
            untyped __cpp__('
                th_ycbcr_buffer ybr;
                bool got = THEORA_getvideo(&vidCtx, ybr);
                if (got)
                    frameWrite(&frame, THEORA_vidinfo(&vidCtx), ybr);
            ');
        }
    }

    public function applyTo(sprite:CitroSprite):Void {
        if (!hasVideo) return;
        untyped __cpp__('
            sprite->data.image = frame.img;
            sprite->width = frame.img.subtex->width;
            sprite->height = frame.img.subtex->height;
        ', sprite);
    }

    override function destroy() {
        super.destroy();
        if (hasVideo) untyped __cpp__('frameDelete(&frame)');
        untyped __cpp__('THEORA_Close(&vidCtx)');
    }
}