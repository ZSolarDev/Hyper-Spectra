import haxe3ds.SVC;
import haxe.Log;
import citro.CitroGame;
import haxe3ds.services.HID;
import haxe3ds.services.APT;
import haxe3ds.Console;
import haxe3ds.services.GFX;

class Main {
    static function main() {
        CitroGame.start(new GameState());
    }
}