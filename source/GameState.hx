package;

import citro.backend.CitroTimer;
import citro.object.CitroVideo;
import haxe3ds.services.ndsp.NDSP;
import citro.object.CitroSprite;
import citro.object.CitroCamera;
import citro.object.CitroText;
import citro.state.CitroState;

class GameState extends CitroState {
    public var topScreen:CitroCamera;
    public var video:CitroVideo;
    public var videoTop:CitroSprite;
    public var mp3:NDSP;

	override function create() {
		super.create();
        topScreen = new CitroCamera();
		add(topScreen);
        video = new CitroVideo();

        if (video.load("romfs:/testSong/いますぐ輪廻 ／ 初音ミク - なきそ (1080p, h264).ogv")) {
            videoTop = new CitroSprite(0, 0);
            topScreen.add(videoTop);
        }

        mp3 = NDSP.loadFile('romfs:/testSong/いますぐ輪廻 ／ 初音ミク - なきそ.mp3');
        mp3.play();
	}

    private var driftTime:Float = 0;
	override function update(delta:Int) {
        super.update(delta);
        if (video == null) return;

        // TODO: Get video seeking functional
        //var videoSecs:Float = video.currentTime;
        //var audioSecs:Float = mp3.time;
        //var diff:Float = videoSecs - audioSecs;

        //driftTime = (Math.abs(diff) > 0.20 ? (driftTime + (delta / 1000)) : 0);

        //if (driftTime >= 5) {
        //    video.currentTime = audioSecs + 0.05;
        //    driftTime = 0;
        //}

        video.tick();
        video.applyTo(videoTop);
    }
}