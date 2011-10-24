/****
* Copyright 2011 Massive Interactive. All rights reserved.
* 
* Redistribution and use in source and binary forms, with or without modification, are
* permitted provided that the following conditions are met:
* 
*    1. Redistributions of source code must retain the above copyright notice, this list of
*       conditions and the following disclaimer.
* 
*    2. Redistributions in binary form must reproduce the above copyright notice, this list
*       of conditions and the following disclaimer in the documentation and/or other materials
*       provided with the distribution.
* 
* THIS SOFTWARE IS PROVIDED BY MASSIVE INTERACTIVE ``AS IS'' AND ANY EXPRESS OR IMPLIED
* WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
* FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL MASSIVE INTERACTIVE OR
* CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
* CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
* SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
* ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
* NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
* ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
* 
* The views and conclusions contained in the software and documentation are those of the
* authors and should not be interpreted as representing official policies, either expressed
* or implied, of Massive Interactive.
****/

package massive.mcover.macro;
#if macro
import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.Compiler;
#end
import massive.mcover.data.Coverage;
import massive.mcover.data.Package;
import massive.mcover.data.File;
import massive.mcover.data.Clazz;
import massive.mcover.data.Method;
import massive.mcover.data.AbstractBlock;
import massive.mcover.data.Statement;
import massive.mcover.data.Branch;


@:keep class CoverClassMacro
{
	#if macro

	static var statementCount:Int = 0;
	static var branchCount:Int = 0;
	static var coverage = new Coverage();
	
	/**
	* Inserts reference to all identified code coverage blocks into a haxe.Resource file called 'MCover'.
	* This resource is used by MCoverRunner to determine code coverage results
	*/
	static public function onGenerate(types:Array<haxe.macro.Type>):Void
	{
       	var serializedData = haxe.Serializer.run(coverage);
        Context.addResource(MCover.RESOURCE_DATA, haxe.io.Bytes.ofString(serializedData));
	}

	/**
	* Inserts code coverage into the specified class.
	* This is injected into each class at runtime via MCover.include
	* Recursively steps through class and inserts calls to MCoverRunner in each code block.
	**/
	@:macro public static function build():Array<Field>
	{
		var fields = Context.getBuildFields();
		var type = Context.getLocalType();
		
		switch(type)
		{
			case TInst(t, params):
			{
				currentClassName = Std.string(t).split(".").pop();
			}
			default: null;
		}

		#if MCOVER_IGNORE_CLASS
			//Disable by default as getting classType can occassionally cause compilation failure
			//with generic type references (e.g. class Foo<T:Bar>)
			var classType = Context.getLocalClass().get();
			var meta = classType.meta;
			if(meta.has(META_TAG_IGNORE)) return null;
		#end

		fields = parseFields(fields);
		return fields;
	}

	static inline var META_TAG_IGNORE:String = "IgnoreCover";
	static var currentClassName:String;
	static var currentMethodName:String;

	static function parseFields(fields:Array<Field>):Array<Field>
	{
		for(field in fields)
        {
        	//debug(field);
        	field = parseField(field);  	
        }
        return fields;
	}

	static function parseField(field:Field):Field
	{
		for(item in field.meta)
		{
			if(item.name == META_TAG_IGNORE)
			{	
				return field;
			}
		}

		switch(field.kind)
    	{
    		case FFun(f):
    		{	
    			currentMethodName = field.name == "new" ? "constructor" : field.name;
    			if(f.expr != null )
				{
					f.expr = parseExpression(f.expr);
				}
    		}
    		default: null;
    	}

    	return field;
	}

	static function parseExpressions(exprs:Array<Expr>)
	{
		for(expr in exprs)
		{
			expr = parseExpression(expr);
		}
		return exprs;
	}

	static function parseExpression(expr:Expr):Expr
	{
		var tmp:Array<Expr> = [];
		
		//debug(expr.expr);
		switch(expr.expr)
		{
			case EContinue: null;
			case EBreak: null;
			case EConst(c): null;
			case EFunction(name, f): 
			{
				tmp = [f.expr];
				//e.g. var f = function()
			}
			case EDisplayNew(t): null;  //no idea what this is??
			case EDisplay(e, isCall): tmp = [e];//no idea what this is???
			

			case ECast(e, t): tmp = [e];// case(foo, Foo);
			case EIf(econd, eif, eelse):
			{
				econd = createBranchCoverageExpr(econd);
				//e.g. if(){}else{}
				tmp = [econd, eif];
				if(eelse!=null) tmp.push(eelse);
			}
		
			case ESwitch(e, cases, edef):
			{	
				parseSwitch(expr, e, cases, edef);
			}
			case ETry(e, catches):
			{
				//e.g. try{...}catch(){}
				tmp = [e];
				for(c in catches)
				{
					tmp.push(c.expr);
				}
			}
			case EThrow(e): tmp = [e];//e.g. throw "foo";
			case EWhile(econd, e, normalWhile):
			{
				econd = createBranchCoverageExpr(econd);
				tmp = [econd, e];//e.g. while(i<2){}
			}
			case EField(e, field):tmp = [e];//e.g. Sdt.string()
			case EParenthesis(e):tmp = [e];//e.g. {}
			case ENew(t, params): tmp = params;
			case EType(e, field):tmp = [e];
			case ECall(e, params):
			{
				//e.g. method(); 
				tmp = [e];
				tmp = tmp.concat(params);
			}
			case EReturn(e): tmp = [e];//e.g. return foo;
			case EVars(vars):
			{
				//e.g. var i=0;
				for(v in vars)
				{
					if(v.expr != null) tmp.push(v.expr);
				}
			}
			case EBinop(op, e1, e2):
			{
				//e.g. i<2; a||b, i==b
				expr = parseBinop(expr, op, e1, e2);
			}
			case EUnop(op,postFix,e): tmp = [e];//e.g. i++;
			case ETernary(econd, eif, eelse): 
			{
				econd = createBranchCoverageExpr(econd);
				tmp = [econd, eif, eelse];
				//e.g. var n = (1 + 1 == 2) ? 4 : 5;
			}
			case EObjectDecl(fields):
			{
				//e.g. var o = { a:"a", b:"b" }
				for(f in fields)
				{
					tmp.push(f.expr);
				}
			}

			case EFor(it, e):tmp = [it, e];//e.g. for(i in 0...5){}
			case EIn(e1, e2):
			{
			
				tmp = [e1, e2];//e.g. for(i in 0...5){}
			}
			case EArrayDecl(values):
			{
				//e.g. a = [1,2,3];
				for(v in values)
				{
					tmp.push(v);
				}
			}
			case EArray(e1, e2):
			{
				tmp = [e1,e2];//not sure
			}
			case EBlock(exprs): 
			{
				if(exprs.length > 0)
				{
					expr = parseBlock(expr, exprs);//e.g. {...}
				}
			}
			default: debug(expr.expr);
		}

		if(tmp.length > 0)
		{
			expr = parseGenericExprDef(expr, tmp);
		}
		return expr;
	}


	static function parseGenericExprDef(expr:Expr, exprs:Array<Expr>):Expr
	{
		for(e in exprs)
		{
			if(e == null) continue;
			e = parseExpression(e);
		}
		return expr;
	}

	static function parseSwitch(expr:Expr, e:Expr, cases: Array<{ values : Array<Expr>, expr : Expr }>, edef:Null<Expr>):Expr
	{
		e = parseExpression(e);

		for(c in cases)
		{
			for(v in c.values)
			{
				v = parseExpression(v);
			}
			c.expr = parseExpression(c.expr);	
		}

		if(edef != null)
		{
			edef = parseExpression(edef);
		}
		return expr;
	}


	static function parseWhile(expr:Expr, econd:Expr, e:Expr, normalWhile:Bool)
	{
		econd = parseExpression(econd);
		e = parseExpression(e);
		return expr;
	}


	//e.g. i<2; a||b, i==b
	static function parseBinop(expr:Expr, op:Binop, e1:Expr, e2:Expr):Expr
	{
		//debug(expr);
		
		switch(op)
		{
			case OpAssignOp(op): null;//
			case OpBoolOr:
				
				e1 = createBranchCoverageExpr(e1);
				e2 = createBranchCoverageExpr(e2);
			
			default: null;//debug(expr);
		}


		//expr.expr = EBinop(op, e1, e2);

		//debug(expr);

		//expr = parseGenericExprDef(expr, [e1, e2]);
		return expr;
	}



	static function parseBlock(expr:Expr, exprs:Array<Expr>):Expr
	{
		parseExpressions(exprs);

		var pos:Position = (exprs.length == 0) ? expr.pos : exprs[0].pos;

		var coverageExpr = createBlockCoverageExpr(expr, pos);

		exprs.unshift(coverageExpr);

		return expr;
	}


	static function createBaseExpr(pos:Position):Expr
	{
		var cIdent = EConst(CIdent("massive"));
		pos = incrementPos(pos, 7);
		var identExpr = {expr:cIdent, pos:pos};

		var eIdentField = EField(identExpr, "mcover");
		pos = incrementPos(pos, 7);
		var identFieldExpr = {expr:eIdentField, pos:pos};

		var eType = EType(identFieldExpr, "MCover");
		pos = incrementPos(pos, 5);
		var typeExpr = {expr:eType, pos:pos};

		var eField = EField(typeExpr, "getLogger");
		pos = incrementPos(pos, 9);
		var fieldExpr = {expr:eField, pos:pos};

		pos = incrementPos(pos, 2);
		return {expr:ECall(fieldExpr, []), pos:pos};
	}



	/**
	* generates a call to the runner to insert into the code block containing a unique id
	*		mcover.MCoverRunner.log(id)
	* @see createCodeBlock for key format
	**/
	static function createBlockCoverageExpr(expr:Expr, pos:Position):Expr
	{
		var block = createCodeBlockReference(pos);
		var blockId = Std.string(block.id);
		
		var baseExpr = createBaseExpr(pos);
		pos = baseExpr.pos;

		var eField = EField(baseExpr, "logStatement");
		pos = incrementPos(pos, 13);
		var fieldExpr = {expr:eField, pos:pos};
		
		pos = incrementPos(pos, blockId.length);
		var arg1 = {expr:EConst(CInt(blockId)), pos:pos};

		pos = incrementPos(pos, 2);
		
		return {expr:ECall(fieldExpr, [arg1]), pos:pos};
	}

	/**
	* wraps a boolean value within a branch in a call to MCover.getLogger.logBranch(id, value, compareValue);
	**/
	static function createBranchCoverageExpr(expr:Expr, ?compareExpr:Expr = null):Expr
	{
		var pos = expr.pos;
		var block = createCodeBlockReference(pos, true);
		var blockId = Std.string(block.id);

		var baseExpr = createBaseExpr(pos);
		pos = baseExpr.pos;

		var eField = EField(baseExpr, "logBranch");
		pos = incrementPos(pos, 4);
		var fieldExpr = {expr:eField, pos:pos};
		
		var args:Array<Expr> = [];

		pos = incrementPos(pos, blockId.length);
	
		args.push({expr:EConst(CInt(blockId)), pos:pos});

		pos = incrementPos(pos, 5);
		args.push({expr:expr.expr, pos:pos});

		if(compareExpr != null)
		{
			pos = incrementPos(pos, 5);
			args.push({expr:compareExpr.expr, pos:pos});
		}
		
		expr.expr = ECall(fieldExpr, args);
		
		return expr;
	}

	static function createCodeBlockReference(pos:Position, ?isBranch:Bool = false):AbstractBlock
	{
		var posInfo = Context.getPosInfos(pos);
		var file:String = posInfo.file;

		for (cp in MCover.classPathHash)
		{
			//trace(cp + ", " + file);
			if(file.indexOf(cp) == 0)
			{	
				return createReference(cp, file, pos, isBranch);
			}
		}
		throw "Invalid coverage position " + Std.string(pos);
		return null;
	}


	static function createReference(cp:String, file:String, pos:Position, isBranch:Bool):AbstractBlock
	{
		var block:AbstractBlock;
		
		if(isBranch)
		{
			block = new Branch();
			block.id = branchCount ++;
		}
		else
		{
			block = new Statement();
			block.id = statementCount++;
		}

		block.file = file;

		var filePath = file.substr(cp.length+1, file.length-cp.length-4);
		var parts = filePath.split("/");
		parts.pop();

		block.packageName = (parts.length > 0) ? parts.join(".") : "";
		block.className = currentClassName;
		block.qualifiedClassName = (block.packageName != "") ? block.packageName + "." + block.className : block.className;
		block.methodName = currentMethodName;


		var posInfo = Context.getPosInfos(pos);

		block.min = posInfo.min;
		block.max = posInfo.max;

		var posString = Std.string(pos);

		block.location = posString.substr(5, posString.length-6);
		block.location = block.location.split(" characters ").join(" chars ");

		if(isBranch)
		{
			coverage.addBranch(cast(block, Branch));
		}
		else
		{
			coverage.addStatement(cast(block, Statement));
		}
		return block;
	}

	static function incrementPos(pos:Position, length:Int):Position
	{
		var posInfos = Context.getPosInfos(pos);
		posInfos.max = posInfos.min + length;
		return Context.makePosition(posInfos);
	}

	static function debug(value:Dynamic, ?posInfos:haxe.PosInfos)
	{
		#if MCOVER_DEBUG
			neko.Lib.println(posInfos.fileName+ ":" + posInfos.lineNumber + ": " + value);
		#end
	}
	#end
}