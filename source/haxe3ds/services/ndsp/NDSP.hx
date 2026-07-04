package haxe3ds.services.ndsp;

import sys.thread.Thread;
import haxe.exceptions.NotImplementedException;
import haxe3ds.services.CFG.CFGSoundOutput;
import haxe3ds.types.Result;

/**
 * The NDSP Result enum when called `init()`
 * @since 1.10.0
 */
enum NDSPResult {
	/**
	 * NDSP Returned a Basic Error Code.
	 */
	NDSP_RESULT(CODE:Result);

	/**
	 * The special file `sdmc:/3ds/dspfirm.cdc` was not found.
	 */
	NDSP_CDC_NOT_FOUND;

	/**
	 * NDSP Was already initialized!
	 */
	NDSP_ALREADY_INIT;
}

/**
 * Format for the NDSP Output Format.
 */
enum abstract NDSPFormat(cpp.UInt16) {
	/**
	 * Mono Channel (Use this if the audio has *1* channel)
	 */
	var MONO = 5;

	/**
	 * Stereo Channel (Use this if the audio has *2* channels)
	 */
	var STEREO = 6;
}

/**
 * Class that is an alias of DSP, used for playing sounds from your 3DS.
 * 
 * This class is easy to use, as You'll need to use the Built-In NDSP Players to play audio sounds directly from your 3DS.
 * 
 * NDSP also requires a special file to actually play sounds, being `sdmc:/3ds/dspfirm.cdc`, without this, you cannot play sounds.
 * 
 * This class uses `4` Wave Buffers as their Default to not Sound like Artifacts, It would be pretty noticeable at `2` Wave Buffers.
 * Even tho this allocates some Linear Memory (for example: `2` Sound Channels * `4` Wave Buffers * `24` NDSP Channels * `4096` Bytes of Linear Memory * `2` for `int16` == `1572` KB),
 * The Linear Memory has a total of `32` MB, so this should still be fine for the 3DS.
 * 
 * Depending on what you're loading, it could take a lot of CPU power to just load blocks of Audio data to be sent on the 3DS Sounds.
 * 
 * Since NDSP has 24 channels, a Big O(C) Notation means where C is 24, which should be faster than a frame.
 * 
 * # `==== READ THIS!!!====`
 * If you initialize NDSP before CFG, CFG's Service is Exited Out, make sure NDSP is initialized AFTER CFG. Example:
 * ```
 * // BAD: NDSP calls ndspInitMaster, which also inits CFG and then EXITS if finished.
 * CFG.init();
 * NDSP.init();
 * 
 * // GOOD:
 * NDSP.init();
 * CFG.init();
 * ```
 */
@:headerCode('
#include "haxe3ds_Utils.h"
#include <functional>

#define MAX_WAVE_BUFS 4
#define MAX_BUF_READ 4096

namespace Helper::NDSP {
typedef struct {
	u8 channels;
	Float length;
	std::function<size_t(s16*)> audioLoading;
	std::function<void()> cleanup;
	std::function<Float(Float, bool)> time;
	bool playing;
	u32* audioBuf;
	ndspWaveBuf waveBuf[MAX_WAVE_BUFS];
} NDSP_CH;

void resetCH(int chn);
void setupCH(int channelID, NDSP_CH* structure);
}')
@:cppFileCode('
namespace Helper::NDSP {
NDSP_CH chh[24];
void setupCH(int channelID, NDSP_CH* structure) {
	NDSP_CH* ch = &chh[channelID];
	memcpy(ch, structure, sizeof(*ch));

	if (!ch->audioBuf) {
		const int bufSize = MAX_BUF_READ * ch->channels;
		ch->audioBuf = (u32*)linearAlloc(MAX_WAVE_BUFS * bufSize);
		for (int i = 0; i < MAX_WAVE_BUFS; i++) {
			ndspWaveBuf* buf = &ch->waveBuf[i];
			buf->data_vaddr = ch->audioBuf + i * bufSize;
			buf->status = NDSP_WBUF_DONE;
		}
	}
}

bool running;
void AudioCallback() {
	running = true;
	while (running) {
		for (u8 i = 0; i < 24; i++) {
			NDSP_CH* ch = &chh[i];
			if (!ch->playing || !(ch->audioBuf && ch->audioLoading && ch->cleanup)) {
				continue;
			}

			for (u8 j = 0; j < MAX_WAVE_BUFS; j++) {
				ndspWaveBuf* buf = &ch->waveBuf[j];
				if (buf->status == NDSP_WBUF_DONE) {
					size_t s = ch->audioLoading(buf->data_pcm16);
					if (s == 0) {
						ch->playing = false;
						break;
					}

					buf->nsamples = s / sizeof(u16);
					ndspChnWaveBufAdd(i, buf);
				}
			}
		}
	}
}
}
')
@:headerClassCode('Helper::NDSP::NDSP_CH* ch;')
class NDSP {
	static var thread:Thread;

	/**
	 * A Read Only Array of NDSP Channels (Length = 24), Where there's all the channel properties that you can set.
	 * 
	 * This is more so if you want to check channels on their behavior.
	 * 
	 * Attempting to modify the channels array will cause Unimaginable Stuff to happen.
	 */
	public static var channels(default, null):Array<NDSP> = [];

	/**
	 * Initializes NDSP so you can play sounds on your 3DS.
	 * @see `NDSPResult` enum
	 * @return See above.
	 */
	public static function init():NDSPResult {
		if (thread != null) {
			return NDSP_ALREADY_INIT;
		}

		var res:Result = untyped __cpp__('ndspInit()');
		if (res == 0xD880A7FA) {
			return NDSP_CDC_NOT_FOUND;
		} else if (res.isSuccess()) {
			channels = [for (i in 0...24) new NDSP(i)];
			thread = Thread.create(() -> untyped __cpp__('Helper::NDSP::AudioCallback()'));
		}

		return NDSP_RESULT(res);
	}

	/**
	 * Exits NDSP, and Frees up channels.
	 */
	public static function exit() {
		untyped __cpp__('
			Helper::NDSP::running = false;
			ndspExit();
		');
		for (channel in channels) {
			channel.reset();
		}
		channels.splice(0, 24);
		thread = null;
	}

	/**
	 * The concurrent Master Volume. This does not have a clamp limit, you can set to anything.
	 * 
	 * Default: `1f`
	 */
	public static var masterVolume(get, set):Float;
	static function get_masterVolume() {
		return untyped __cpp__('ndspGetMasterVol()');
	}
	static function set_masterVolume(masterVolume) {
		untyped __cpp__('ndspSetMasterVol({0})', masterVolume);
		return masterVolume;
	}

	/**
	 * The current Output Mode, Depending on which you would want to play.
	 * 
	 * Default: Current Output Mode you've picked in System Settings, OR `CFGSoundOutput.SURROUND` if CFG failed.
	 */
	public static var outputMode(get, set):CFGSoundOutput;
	static function get_outputMode() {
		return untyped __cpp__('ndspGetOutputMode()');
	}
	static function set_outputMode(outputMode) {
		untyped __cpp__('ndspSetOutputMode((ndspOutputMode){0})', outputMode);
		return outputMode;
	}

	/**
	 * Function that does an O(C) loop to find a free channel that isn't currently playing.
	 * 
	 * @return `null` if all channels has been used, or the first channel that isn't playing.
	 */
	public static function getFirstFree():Null<NDSP> {
		return Lambda.find(channels, channel -> !channel.playing);
	}

	/**
	 * Function that loads an audio file and returns the NDSP channel with that audio loaded.
	 * 
	 * The following formats are currently supported, and more support will come soon:
	 * - `MP3`
	 * - `OGG`
	 * 
	 * Beware, `audioFile` should not be null, and should have an extension, and should exist, and one channel is free.
	 * If any doesn't match, it either `throws` or returns `null` as the channel.
	 * 
	 * @param audioFile The audio file that should be loaded in the NDSP channel.
	 * @return A NDSP Channel if that is successfully loaded, or `null` if it didn't load.
	 */
	public static function loadFile(audioFile:String):Null<NDSP> {
		if (audioFile == null || !sys.FileSystem.exists(audioFile)) {
			return null;
		}

		var channel = getFirstFree();
		if (channel == null) {
			return null;
		}
		channel.reset();

		return switch haxe.io.Path.extension(audioFile) {
			case "mp3":
				MP3.load(audioFile, channel);
			case "ogg":
				OGG.load(audioFile, channel);
			default:
				throw new NotImplementedException('File Format ($audioFile) not Implemented');
		}
	}

	/**
	 * A helper function that cleans up unused channels if they're paused or unloaded.
	 * 
	 * This goes through a O(C) loop, looking through every channel to get rid of, and making it be able to play again for other files.
	 */
	public static function cleanupChannels() {
		for (channel in channels) {
			if (!channel.playing) {
				channel.reset();
			}
		}
	}

	function new(channel:Int) {
		channelID = channel;
		reset();
	}

	/**
	 * The current default channel that cannot be modified.
	 * 
	 * Note: Using `NDSP.channels[{code}].channelID` is meaningless because you already have the index as the channel, use that index instead of wasting CPU cycles.
	 */
	public var channelID(default, null):Int;

	/**
	 * Resets the entire channel, cleaning up resources, freeing linear allocations, and making it reusable again.
	 */
	public function reset() {
		untyped __cpp__('
			ch = &Helper::NDSP::chh[{0}];
			if (ch->cleanup) {
				ch->cleanup();
				ch->cleanup = nullptr;
			}

			if (ch->audioBuf) {
				linearFree(ch->audioBuf);
				ch->audioBuf = nullptr;
			}

			memset(ch, 0, sizeof(*ch));
			ndspChnReset({0});
		', channelID);
	}

	/**
	 * Variable that checks if you're playing the audio, this can be set to pause the audio.
	 */
	public var playing(get, null):Bool;
	function get_playing() {
		return untyped __cpp__('ch->playing');
	}

	/**
	 * Variable for the Current Format, this can only be set by the same format for the audio.
	 * 
	 * @see `NDSPFormat` enum
	 */
	public var format(get, set):NDSPFormat;
	function get_format() {
		return untyped __cpp__('ndspChnGetFormat({0})', channelID);
	}
	function set_format(format) {
		untyped __cpp__('ndspChnSetFormat({0}, {1})', channelID, format);
		return format;
	}

	/**
	 * Variable for the current HERTZ rate, this can be set to update the hertz/playback rate.
	 * 
	 * Upon Setting the Rate, It will divide the rate to keep sounding what you usually hear from the rate itself (which is `SYSCLOCK_SOC / 512.0`)
	 */
	public var rate(get, set):Float;
	function get_rate() {
		return untyped __cpp__('ndspChnGetRate({0})', channelID) * 32728.497678125931; // Magic float, this turns 0,97774... to 32000hz
	}
	function set_rate(rate) {
		untyped __cpp__('ndspChnSetRate({0}, {1})', channelID, rate);
		return rate;
	}

	/**
	 * Starts playing the loaded Wave Buffer, this will run in a NDSP Thread to load other blocks inside the files.
	 * 
	 * @param position Beginning position to place the buffer at, if it's -1 then it stays exactly where its pointing at.
	 */
	public function play(position:Float = -1) {
		if (position != -1) {
			time = position;
		}
		untyped __cpp__('ch->playing = true');
	}

	/**
	 * Pauses the playback, halting any progress on this channel if there's any buffers in this channel.
	 */
	public function pause() {
		untyped __cpp__('ch->playing = false');
	}

	/**
	 * A getter and setter variable that gets the current time of this channel in seconds.
	 */
	public var time(get, set):Float;
	function get_time() {
		return untyped __cpp__('ch->time(0, true)');
	}
	function set_time(time) {
		untyped __cpp__('ch->time({0}, false)', time);
		return time;
	}

	/**
	 * A getter variable that gets the length of this channel in seconds.
	 */
	public var length(get, null):Float;
	function get_length() {
		return untyped __cpp__('ch->length');
	}
}