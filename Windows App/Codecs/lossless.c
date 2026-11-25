/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Standalone audio decoder for Tool Drive Offline. Input is a single local
 * file. No FFmpeg protocols or URL handlers are used, including nested media.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <errno.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/intreadwrite.h>

#ifdef _WIN32
#define ENTRY wmain
typedef wchar_t pathchar;
#define OPEN_READ(p) _wfopen((p),L"rb")
#define OPEN_WRITE(p) _wfopen((p),L"wb")
#define DELETE_PATH _wremove
#define FILE_TELL _ftelli64
#define FILE_SEEK _fseeki64
#else
#define ENTRY main
typedef char pathchar;
#define OPEN_READ(p) fopen((p),"rb")
#define OPEN_WRITE(p) fopen((p),"wb")
#define DELETE_PATH remove
#define FILE_TELL ftello
#define FILE_SEEK fseeko
#endif

#define MAX_WAVE_BYTES UINT64_C(2147483600)
enum { DECODED = 0, INVALID = 1, DIRECT = 3 };

static int read_bytes(void *opaque, uint8_t *data, int size) {
    FILE *input = opaque;
    size_t n = fread(data, 1, size, input);
    return n ? (int)n : (ferror(input) ? AVERROR(EIO) : AVERROR_EOF);
}
static int64_t seek_input(void *opaque, int64_t offset, int origin) {
    FILE *input = opaque;
    origin &= ~AVSEEK_FORCE;
    if (origin == AVSEEK_SIZE) {
        int64_t old = FILE_TELL(input);
        if (old < 0 || FILE_SEEK(input, 0, SEEK_END)) return AVERROR(EIO);
        int64_t size = FILE_TELL(input);
        return FILE_SEEK(input, old, SEEK_SET) ? AVERROR(EIO) : size;
    }
    if (origin != SEEK_SET && origin != SEEK_CUR && origin != SEEK_END) return AVERROR(EINVAL);
    return FILE_SEEK(input, offset, origin) ? AVERROR(EIO) : FILE_TELL(input);
}
static int refuse_nested(AVFormatContext *ctx, AVIOContext **io, const char *name, int flags, AVDictionary **opts) {
    (void)ctx; (void)io; (void)name; (void)flags; (void)opts;
    return AVERROR(EPERM);
}
typedef struct {
    FILE *file;
    enum AVSampleFormat packed;
    int rate, channels, bits, floating;
    uint32_t mask;
    uint64_t bytes;
} Wave;

static int begin_wave(Wave *wave,const AVFrame *frame) {
    enum AVSampleFormat packed=av_get_packed_sample_fmt(frame->format);
    int channels=frame->ch_layout.nb_channels, rate=frame->sample_rate;
    if (channels<1 || channels>8 || rate<1 || rate>768000) return -1;
    switch (packed) {
        case AV_SAMPLE_FMT_U8: case AV_SAMPLE_FMT_S16: wave->bits=16;break;
        case AV_SAMPLE_FMT_S32: wave->bits=32;break;
        case AV_SAMPLE_FMT_FLT: case AV_SAMPLE_FMT_DBL: wave->bits=32;wave->floating=1;break;
        default: return -1;
    }
    wave->packed=packed; wave->rate=rate; wave->channels=channels;
    if (frame->ch_layout.order==AV_CHANNEL_ORDER_NATIVE && frame->ch_layout.u.mask<=UINT32_MAX)
        wave->mask=(uint32_t)frame->ch_layout.u.mask;
    uint8_t header[68]={0};
    memcpy(header,"RIFF",4); memcpy(header+8,"WAVEfmt ",8);
    AV_WL32(header+16,40); AV_WL16(header+20,0xfffe); AV_WL16(header+22,channels);
    AV_WL32(header+24,rate); AV_WL32(header+28,rate*channels*(wave->bits/8));
    AV_WL16(header+32,channels*wave->bits/8); AV_WL16(header+34,wave->bits);
    AV_WL16(header+36,22); AV_WL16(header+38,wave->bits); AV_WL32(header+40,wave->mask);
    const uint8_t pcm_guid[16]={1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113};
    memcpy(header+44,pcm_guid,16); if (wave->floating) header[44]=3;
    memcpy(header+60,"data",4);
    return fwrite(header,1,sizeof(header),wave->file)==sizeof(header) ? 0:-1;
}
static int render(Wave *wave,const AVFrame *frame) {
    if (!wave->rate && begin_wave(wave,frame)<0) return -1;
    if (frame->ch_layout.nb_channels!=wave->channels || frame->sample_rate!=wave->rate ||
        av_get_packed_sample_fmt(frame->format)!=wave->packed || frame->nb_samples<0) return -1;
    uint64_t bytes=(uint64_t)frame->nb_samples*wave->channels*(wave->bits/8);
    if (bytes>MAX_WAVE_BYTES-wave->bytes) return -1;
    int planar=av_sample_fmt_is_planar(frame->format), stride=av_get_bytes_per_sample(frame->format);
    uint8_t block[8192]; size_t used=0;
    for (int i=0;i<frame->nb_samples;i++) for(int c=0;c<wave->channels;c++) {
        const uint8_t *sample=frame->extended_data[planar ? c:0]+(size_t)(planar ? i:i*wave->channels+c)*stride;
        if (wave->packed==AV_SAMPLE_FMT_U8) {
            AV_WL16(block+used,((int)*sample-128)*256);
        } else if (wave->packed==AV_SAMPLE_FMT_DBL) {
            double x; float y;
            memcpy(&x,sample,sizeof(x)); y=(float)x; memcpy(block+used,&y,sizeof(y));
        } else {
            memcpy(block+used,sample,wave->bits/8);
        }
        used+=wave->bits/8;
        if (used==sizeof(block)) {
            if (fwrite(block,1,used,wave->file)!=used) return -1;
            used=0;
        }
    }
    if (used && fwrite(block,1,used,wave->file)!=used) return -1;
    wave->bytes+=bytes;
    return 0;
}
static int drain(AVCodecContext *decoder, AVFrame *frame, Wave *wave) {
    int status;
    while ((status=avcodec_receive_frame(decoder,frame))>=0) {
        if (render(wave,frame)<0) return -1;
        av_frame_unref(frame);
    }
    return status==AVERROR(EAGAIN) || status==AVERROR_EOF ? 0:-1;
}

int ENTRY(int argc,pathchar **argv) {
    if (argc!=3) return INVALID;
    int result=INVALID, output_created=0;
    FILE *input=OPEN_READ(argv[1]);
    AVFormatContext *fmt=avformat_alloc_context(); AVIOContext *io=NULL;
    AVCodecContext *decoder=NULL; AVPacket *packet=NULL; AVFrame *frame=NULL;
    Wave wave={0};
    if (!input || !fmt) goto finish;
    uint8_t *buffer=av_malloc(32768);
    if (!buffer) goto finish;
    io=avio_alloc_context(buffer,32768,0,input,read_bytes,NULL,seek_input);
    if (!io) {av_free(buffer); goto finish;}
    fmt->pb=io; fmt->flags|=AVFMT_FLAG_CUSTOM_IO; fmt->io_open=refuse_nested;
    fmt->max_streams=64;
    if (avformat_open_input(&fmt,NULL,NULL,NULL)<0) goto finish;
    int audio=av_find_best_stream(fmt,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);
    if (audio<0) goto finish;
    AVCodecParameters *params=fmt->streams[audio]->codecpar;
    if (params->codec_id==AV_CODEC_ID_AAC || params->codec_id==AV_CODEC_ID_MP3 ||
        params->codec_id==AV_CODEC_ID_FLAC || params->codec_id==AV_CODEC_ID_OPUS) {
        if (strstr(fmt->iformat->name,"mov")!=NULL) result=DIRECT;
        goto finish;
    }
    const AVCodec *codec=avcodec_find_decoder(params->codec_id);
    if (!codec || !(decoder=avcodec_alloc_context3(codec))) goto finish;
    if (avcodec_parameters_to_context(decoder,params)<0) goto finish;
    decoder->thread_count=1;
    decoder->err_recognition=AV_EF_EXPLODE;
    if (avcodec_open2(decoder,codec,NULL)<0) goto finish;
    if (!(wave.file=OPEN_WRITE(argv[2]))) goto finish;
    output_created=1;
    packet=av_packet_alloc(); frame=av_frame_alloc();
    if (!packet || !frame) goto finish;
    int status;
    while ((status=av_read_frame(fmt,packet))>=0) {
        if (packet->stream_index==audio &&
            (avcodec_send_packet(decoder,packet)<0 || drain(decoder,frame,&wave)<0)) goto finish;
        av_packet_unref(packet);
    }
    if (status!=AVERROR_EOF || avcodec_send_packet(decoder,NULL)<0 || drain(decoder,frame,&wave)<0 || wave.bytes==0) goto finish;
    uint8_t size[4]; AV_WL32(size,(uint32_t)wave.bytes+60);
    if (FILE_SEEK(wave.file,4,SEEK_SET) || fwrite(size,1,4,wave.file)!=4) goto finish;
    AV_WL32(size,(uint32_t)wave.bytes);
    if (FILE_SEEK(wave.file,64,SEEK_SET) || fwrite(size,1,4,wave.file)!=4) goto finish;
    result=DECODED;
finish:
    av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&decoder);
    avformat_close_input(&fmt);
    if (io) av_freep(&io->buffer);
    avio_context_free(&io);
    if (input) fclose(input);
    if (wave.file && fclose(wave.file)) result=INVALID;
    if (output_created && result!=DECODED) DELETE_PATH(argv[2]);
    return result;
}
