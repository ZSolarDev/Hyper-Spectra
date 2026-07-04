package;

/**
 * Dead-simple raw file logger for 3DS debugging.
 * Bypasses Log.trace / sys.io.File entirely - writes directly via fopen/fprintf/fclose.
 * Usage: Debug.print("something happened");
 */
class Debug {
	public static function print(msg:String) {
		untyped __cpp__('
			FILE* f = fopen("sdmc:/trace.log", "a");
			if (f) {
				fprintf(f, "%s\\n", {0}.c_str());
				fclose(f);
			}
		', msg);
	}
}
