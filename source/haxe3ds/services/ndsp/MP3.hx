package haxe3ds.services.ndsp;

@:buildXml("
<target id='haxe'>
	<compiler id='haxe'>
		<flag value='-IC:/devkitPro/portlibs/3ds/include' />
	</compiler>
</target>
")
@:cppInclude("mpg123.h")
class MP3 {
	public static function load(audio:String, channel:NDSP):Null<NDSP> {
		var channels = 0;

		untyped __cpp__('
			mpg123_handle* mh = mpg123_new(NULL, NULL);
			if (!mh || mpg123_open(mh, {0}.c_str()) != MPG123_OK) {
				if (mh) {
					mpg123_delete(mh);
				}
				return null();
			}

			long rate;
			if (mpg123_getformat(mh, &rate, &{1}, NULL) != MPG123_OK) {
				mpg123_close(mh);
				mpg123_delete(mh);
				return null();
			}
		', audio, channels);

		channel.rate = untyped __cpp__('rate');
		channel.format = channels == 2 ? STEREO : MONO;

		untyped __cpp__('
        Helper::NDSP::NDSP_CH _tmp_ch = {
            channels,
            (Float)mpg123_length(mh) / (Float)rate,
            [=](s16* buf) {
                size_t done;
                mpg123_read(mh, buf, MAX_BUF_READ, &done);
                return done / channels;
            },
            [=]() {
                mpg123_close(mh);
                mpg123_delete(mh);
            },
            [=](Float secs, bool getter) {
                if (getter) {
                    return (Float)mpg123_tell(mh) / (Float)rate;
                }
                mpg123_seek(mh, rate * (off_t)secs, SEEK_SET);
                return 0.0;
            }
        };
        Helper::NDSP::setupCH(channel->channelID, &_tmp_ch);
        ');

		return channel;
	}
}