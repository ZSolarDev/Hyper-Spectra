package haxe3ds.macro;

import haxe.macro.PositionTools;
import haxe.macro.Expr;
import haxe.macro.Context;

class CPP {
	public static macro function lines(code:Expr, args:Array<Expr>):Expr {
		var codeStr = switch (code.expr) {
			case EConst(CString(s)): s;
			default: Context.error("CPP.lines requires a constant string literal", code.pos);
		}

		var finalCode = codeStr;
		if (codeStr.indexOf("\n") != -1) {
			var buf = new StringBuf(), pos = PositionTools.toLocation(Context.currentPos()).range.start.line + 1;
			for (line => content in codeStr.split("\n").filter(f -> StringTools.trim(f).length != 0)) {
				buf.add('\nHXLINE(${line + pos})$content');
			}
			finalCode = buf.toString();
		}

		var callArgs:Array<Expr> = [macro $v{finalCode}].concat(args);
		return { expr: ECall(macro untyped __cpp__, callArgs), pos: Context.currentPos() };
	}
}