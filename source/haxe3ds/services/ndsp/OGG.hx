package haxe3ds.services.ndsp;

@:buildXml("
<target id='haxe'>
	<compiler id='haxe'>
		<flag value='-IC:/devkitPro/portlibs/3ds/include' />
	</compiler>
</target>
")
@:cppFileCode('#include <tremor/ivorbisfile.h>')
class OGG {
	public static function load(audio:String, channel:NDSP):Null<NDSP> {
		untyped __cpp__('
			OggVorbis_File* ogg = (OggVorbis_File*)malloc(sizeof(OggVorbis_File));
			FILE* f = fopen({0}.__s, "rb");
			if (!f || !ogg || ov_open(f, ogg, NULL, 0)) {
				if (f) fclose(f);
				if (ogg) free(ogg);
				return null();
			}
		', audio);

		channel.rate = untyped __cpp__('ogg->vi->rate');
		channel.format = untyped __cpp__('ogg->vi->channels') == 2 ? STEREO : MONO;

		untyped __cpp__('
        Helper::NDSP::NDSP_CH _tmp_ch = {
            ogg->vi->channels,
            (Float)ov_pcm_total(ogg, -1) / (Float)ogg->vi->rate,
            [=](s16* buf) {
                size_t done = 0;
                while (done < MAX_BUF_READ) {
                    int recv = ov_read(ogg, (char*)buf + done, MAX_BUF_READ - done, NULL);
                    if (recv < 1) {
                        break;
                    }
                    done += recv;
                }
                return done / ogg->vi->channels;
            },
            [=]() {
                ov_clear(ogg);
                free(ogg);
                fclose(f);
            },
            [=](Float secs, bool getter) {
                if (getter) {
                    return (Float)ov_pcm_tell(ogg) / (Float)ogg->vi->rate;
                }
                ov_pcm_seek(ogg, ogg->vi->rate * secs);
                return 0.0;
            }
        };
        Helper::NDSP::setupCH(channel->channelID, &_tmp_ch);
        ');

		return channel;
	}
}