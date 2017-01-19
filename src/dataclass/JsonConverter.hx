package dataclass;

import haxe.DynamicAccess;
import haxe.ds.ObjectMap;

using Lambda;
using StringTools;
using DateTools;

typedef JsonConverterOptions = {
	?nullifyCircular : Bool,
	?dateFormat : String
}

// TODO: Date and circular reference options
class JsonConverter implements Converter
{
	public static function fromJson<T : DataClass>(cls : Class<T>, json : Dynamic) : T {
		return current.toDataClass(cls, json);
	}

	public static function toJson(cls : DataClass) : DynamicAccess<Dynamic> {
		return current.fromDataClass(cls);
	}
	
	public static var current(default, default) : JsonConverter = new JsonConverter();
	
	///////////////////////////////////////////////////////////////////////////
	
	static var directConversions = ['Int', 'Bool', 'Float', 'String'];
	
	public var valueConverters(default, null) : Map<String, Converter.ValueConverter<Dynamic, Dynamic>>;
	
	var nullifyCircularReferences : Bool;
	
	public function new(?options : JsonConverterOptions) {
		if (options == null) options = {};

		valueConverters = new Map<String, Converter.ValueConverter<Dynamic, Dynamic>>();

		valueConverters.set('Date', new DateValueConverter(
			Reflect.hasField(options, 'dateFormat') ? options.dateFormat : null
		));
		
		nullifyCircularReferences = Reflect.hasField(options, 'nullifyCircular') 
			? options.nullifyCircular : false;
	}	
	
	public function toDataClass<T : DataClass>(cls : Class<T>, json : Dynamic) : T {
		var rtti = Converter.Rtti.rttiData(cls);
		var inputData : DynamicAccess<Dynamic> = json;
		var outputData : DynamicAccess<Dynamic> = {};
		
		for (field in rtti.keys()) {
			var input = inputData.get(field);
			var output = convertFromJsonField(rtti[field], input);
			
			//trace(field + ': ' + input + ' -[' + rtti[field] + ']-> ' + output);
			outputData.set(field, output);
		}

		return Type.createInstance(cls, [outputData]);
	}
	
	function convertFromJsonField(data : String, value : Dynamic) : Dynamic {
		if (value == null) return value;

		if (valueConverters.exists(data)) {
			return valueConverters.get(data).input(value);
		}
		// Check reserved structures
		else if (directConversions.has(data)) {
			return value;
		}
		else if (data.startsWith("Array<")) {
			var arrayType = data.substring(6, data.length - 1);
			return [for (v in cast(value, Array<Dynamic>)) convertFromJsonField(arrayType, v)];
		}
		else if (data.startsWith("Enum<")) {
			var enumT = enumType(data.substring(5, data.length - 1));
			return Type.createEnum(enumT, value);
		}
		else if (data.startsWith("DataClass<")) {
			var classT = classType(data.substring(10, data.length - 1));
			return toDataClass(cast classT, value);
		}
		else 
			throw "Unsupported DataClass converter: " + data;
	}

	///////////////////////////////////////////////////////////////////////////
	
	public function fromDataClass(cls : DataClass) : DynamicAccess<Dynamic> {
		return _fromDataClass(cls, []);
	}
		
	function _fromDataClass(cls : DataClass, refs : Array<Dynamic>) : DynamicAccess<Dynamic> {
		if (refs.has(cls)) {
			if (nullifyCircularReferences) return null 
			else throw "Converting circular structure to JSON.";
		}
		
		var rtti = Converter.Rtti.rttiData(Type.getClass(cls));
		var outputData : DynamicAccess<Dynamic> = {};
		var newRefs = refs.concat([cls]);
		
		for (field in rtti.keys()) {
			var input = Reflect.getProperty(cls, field);
			// TODO: Move refs array above loop?
			var output = convertToJsonField(rtti[field], input, newRefs);
			
			//trace(field + ': ' + input + ' -[' + rtti[field] + ']-> ' + output);
			outputData.set(field, output);
		}

		return outputData;
	}
	
	function convertToJsonField(data : String, value : Dynamic, refs : Array<Dynamic>) : Dynamic {
		if (value == null) return value;

		if (valueConverters.exists(data)) {
			return valueConverters.get(data).output(cast value);
		}
		else if (directConversions.has(data)) {
			return value;
		}
		else if (data.startsWith("Array<")) {
			var arrayType = data.substring(6, data.length - 1);
			return [for (v in cast(value, Array<Dynamic>)) convertToJsonField(arrayType, v, refs)];
		}
		else if (data.startsWith("Enum<")) {
			return Std.string(value);
		}
		else if (data.startsWith("DataClass<")) {
			return _fromDataClass(cast value, refs);
		}
		else 
			throw "Unsupported DataClass converter: " + data;
	}
	
	///// Type retrieval /////
	
	static var enumCache = new Map<String, Enum<Dynamic>>();
	static var classCache = new Map<String, Class<Dynamic>>();
	
	static function enumType(name : String) : Enum<Dynamic> {
		if (enumCache.exists(name)) return enumCache.get(name);
		
		var output = Type.resolveEnum(name);
		if (output == null) throw "Enum not found: " + name;

		enumCache.set(name, output);
		return output;
	}

	static function classType(name : String) : Class<Dynamic> {
		if (classCache.exists(name)) return classCache.get(name);
		
		var output = Type.resolveClass(name);
		if (output == null) throw "Class not found: " + name;

		classCache.set(name, output);
		return output;
	}
}

class DateValueConverter
{
	var format : String;
	
	public function new(format : Null<String>) {
		this.format = format == null ? "%Y-%m-%dT%H:%M:%SZ" : format;
	}

	public function input(input : String) : Date {
		var s = input.trim();
		
		if (s.endsWith('Z')) {
			#if js
			return untyped __js__('new Date({0})', s);
			#else
			var isoZulu = ~/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/;
			inline function d(pos : Int) return Std.parseInt(isoZulu.matched(pos));
			if (isoZulu.match(s)) {
				var hours = Std.int(Math.round(getTimeZone() / 1000 / 60 / 60));
				var minutes = hours * 60 - Std.int(Math.round(getTimeZone() / 1000 / 60));
				return new Date(d(1), d(2) - 1, d(3), d(4) + hours, d(5) + minutes, d(6));
			}
			#end
		}
		
		return Date.fromString(s);
	}
	
	public function output(input : Date) : String {
		var time = format.endsWith("Z") ? DateTools.delta(input, -getTimeZone()) : input;
		return DateTools.format(time, format);
	}
	
	// Thanks to https://github.com/HaxeFoundation/haxe/issues/3268#issuecomment-52960338
	static function getTimeZone() {
		var now = Date.now();
		now = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0);
		return (24. * 3600 * 1000 * Math.round(now.getTime() / 24 / 3600 / 1000) - now.getTime());
	}
}
