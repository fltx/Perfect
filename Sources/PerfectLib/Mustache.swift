//
//  Mustache.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 7/7/15.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

let mustacheExtension = "mustache"

private var mustacheTemplateCache = [String: (Int, MustacheTemplate)]()
private let mustacheTemplateCacheLock = Threading.RWLock()

private func getTemplateFromCache(_ path: String) throws -> MustacheTemplate {
	let file = File(path)
	var template: MustacheTemplate?
	let modDate = file.modificationTime()
	
	mustacheTemplateCacheLock.doWithReadLock {
		if let fnd = mustacheTemplateCache[path] where fnd.0 == modDate {
			template = fnd.1.clone() as? MustacheTemplate
		}
	}
	if let templateW = template?.clone() as? MustacheTemplate {
		return templateW
	}
	try mustacheTemplateCacheLock.doWithWriteLock {
		if let fnd = mustacheTemplateCache[path] where fnd.0 == modDate {
			template = fnd.1.clone() as? MustacheTemplate
		} else {
			try file.openRead()
			defer { file.close() }
			let bytes = try file.readSomeBytes(count: file.size())
			
			let parser = MustacheParser()
			let str = UTF8Encoding.encode(bytes: bytes)
			let templateW = try parser.parse(string: str)
			mustacheTemplateCache[path] = (modDate, templateW)
			template = templateW.clone() as? MustacheTemplate
		}
	}
	guard let templateW = template else {
		throw PerfectError.SystemError(404, "The file \"\(path)\" was not found")
	}
	return templateW
}


//private let mustacheTemplateCacheLock = Threading.Lock()

//private func getTemplateFromCache(_ path: String) throws -> MustacheTemplate {
//	let file = File(path)
//	var template: MustacheTemplate?
//	let modDate = file.modificationTime()
//	
//	try mustacheTemplateCacheLock.doWithLock {
//		if let fnd = mustacheTemplateCache[path] where fnd.0 == modDate {
//			template = fnd.1.clone() as? MustacheTemplate
//		} else {
//			try file.openRead()
//			defer { file.close() }
//			let bytes = try file.readSomeBytes(count: file.size())
//			
//			let parser = MustacheParser()
//			let str = UTF8Encoding.encode(bytes: bytes)
//			let templateW = try parser.parse(string: str)
//			mustacheTemplateCache[path] = (modDate, templateW)
//			template = templateW.clone() as? MustacheTemplate
//		}
//	}
//	guard let templateW = template else {
//		throw PerfectError.SystemError(404, "The file \"\(path)\" was not found")
//	}
//	return templateW
//}

//private func getTemplateFromCache(_ path: String) throws -> MustacheTemplate {
//	let file = File(path)
//	
//	try file.openRead()
//	defer { file.close() }
//	let bytes = try file.readSomeBytes(count: file.size())
//	
//	let parser = MustacheParser()
//	let str = UTF8Encoding.encode(bytes: bytes)
//	let template = try parser.parse(string: str)
//	
//	return template
//}

enum MustacheTagType {
	
	case Plain // plain text
	case Tag // some tag. not sure which yet
	case Hash
	case Slash
	case Amp
	case Caret
	case Bang
	case Partial
	case Delims
	case UnescapedName
	case Name
	case UnencodedName
	case Pragma
	case None
	
}

/// This enum type represents the parsing and the runtime evaluation exceptions which may be generated.
public enum MustacheError : ErrorProtocol {
	/// The mustache template was malformed.
	case SyntaxError(String)
	/// An exception occurred while evaluating the template.
	case EvaluationError(String)
}

/// This class represents an individual scope for mustache template values.
/// A mustache template handler will return a `MustacheEvaluationContext.MapType` object as a result from its `PageHandler.valuesForResponse` function.
public class MustacheEvaluationContext {
	
	public typealias MapType = [String:Any]
	public typealias SequenceType = [MapType]
	
	/// The parent of this context
	public var parent: MustacheEvaluationContext? = nil
	/// Provides access to the current WebResponse object
	public weak var webResponse: WebResponse?
	/// Provides access to the current WebRequest object
	public var webRequest: WebRequest? {
		if let w = self.webResponse {
			return w.request
		}
		return nil
	}
	
	/// Complete path to the file being processed
	/// Potentially nil in cases of dynamic file generation(?)
	public var filePath: String?
	
	/// Returns the name of the current template file.
	public var templateName: String {
		let nam = filePath?.lastPathComponent ?? ""
		return nam
	}
	
	var mapValues: MapType
	
	init(webResponse: WebResponse?) {
		self.webResponse = webResponse
		mapValues = MapType()
	}
	
	init(webResponse: WebResponse?, map: MapType) {
		self.webResponse = webResponse
		mapValues = map
	}
	
	/// Initialize a new context given the map of values.
	public init(map: MapType) {
		self.webResponse = nil
		mapValues = map
	}
	
	func newChildContext() -> MustacheEvaluationContext {
		let cc = MustacheEvaluationContext(webResponse: webResponse)
		cc.parent = self
		return cc
	}
	
	func newChildContext(withMap with: MapType) -> MustacheEvaluationContext {
		let cc = MustacheEvaluationContext(webResponse: webResponse, map: with)
		cc.parent = self
		return cc
	}
	
	/// Search for a value starting from the current context. If not found in the current context, the parent context will be searched, etc.
	/// - parameter named: The name of the value to find
	/// - returns: The value, if found, or nil
	public func getValue(named nam: String) -> MapType.Value? {
		let v = mapValues[nam]
		if v == nil && parent != nil {
			return parent?.getValue(named: nam)
		}
		return v
	}
	
	/// Extends the current values with those from the parameter.
	/// - parameter with: The new values to add
	public func extendValues(with wit: MapType) {
		for (key, value) in wit {
			mapValues[key] = value
		}
	}
	
	func getCurrentFilePath() -> String? {
		if self.filePath != nil {
			return self.filePath!
		}
		if self.parent != nil {
			return self.parent!.getCurrentFilePath()
		}
		return nil
	}
}

/// An instance of this class will collect all output data generated by mustache tags during evaluation.
/// Call the `asString()` function to retreive the resulting data.
public class MustacheEvaluationOutputCollector {
	var output = [String]()
	
	var defaultEncodingFunc: (String) -> String = { $0.stringByEncodingHTML }
	
	/// Empty public initializer.
	public init() {
		
	}
	
	/// Append a new string value to the collected output.
	/// - parameter s: The string value which will be appended.
	/// - parameter encoded: If true, the string value will be HTML encoded as it is appended. Defaults to true.
	public func append(_ s: String, encoded: Bool = true) -> MustacheEvaluationOutputCollector {
		if encoded {
			output.append(self.defaultEncodingFunc(s))
		} else {
			output.append(s)
		}
		return self
	}
	
	/// Joins all the collected output into one string and returns this value.
	public func asString() -> String {
		return output.joined(separator: "")
	}
}

/// An individual mustache tag or plain-text section
public class MustacheTag {
	var type = MustacheTagType.None
	var tag = ""
	weak var parent: MustacheGroupTag?
	
	// only used for debug purposes
	var openD: [UnicodeScalar]?
	var closeD: [UnicodeScalar]?
	
	func clone() -> MustacheTag {
		let s = MustacheTag()
		self.populateClone(s)
		return s
	}
	
	func populateClone(_ tag: MustacheTag) {
		tag.type = self.type
		tag.tag = self.tag
		// parent sets our parent
	}
	
	/// Evaluate the tag within the given context.
	public func evaluate(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector) {
		
		switch type {
		case .Plain:
			let _ = collector.append(tag, encoded: false)
		case .UnescapedName:
			let _ = collector.append(tag, encoded: false)
		case .Name:
			if let value = contxt.getValue(named: tag) {
				let _ = collector.append(String(value))
			}
		case .UnencodedName:
			if let value = contxt.getValue(named: tag) {
				let _ = collector.append(String(value), encoded: false)
			}
		case .Pragma, .Bang:
			() // ignored
		default:
			print("Unhandled mustache tag type \(type)")
		}
	}
	
	func delimOpen() -> String {
		var s = "".unicodeScalars
		s.append(contentsOf: openD!)
		return String(s)
	}
	
	func delimClose() -> String {
		var s = "".unicodeScalars
		s.append(contentsOf: closeD!)
		return String(s)
	}
	
	/// Reconstitutes the tag into its original source string form.
	/// - returns: The resulting string, including the original delimiters and tag-type marker.
	public func description() -> String {
		
		guard type != .Plain else {
			return tag
		}
		
		var s = delimOpen()
		switch type {
		case .Name:
			s.append(" ")
		case .UnencodedName:
			s.append("{ ")
		case .Hash:
			s.append("# ")
		case .Caret:
			s.append("^ ")
		case .Bang:
			s.append("! ")
		case .Partial:
			s.append("> ")
		case .UnescapedName:
			s.append("& ")
		case .Pragma:
			s.append("% ")
		default:
			()
		}
		s.append(tag)
		if type == .UnencodedName {
			s.append(" }" + delimClose())
		} else {
			s.append(" " + delimClose())
		}
		return s
	}
}

/// A sub-class of MustacheTag which represents a mustache "partial" tag.
public class MustachePartialTag : MustacheTag {
	
	override func clone() -> MustacheTag {
		let s = MustachePartialTag()
		self.populateClone(s)
		return s
	}
	
	/// Override for evaluating the partial tag.
	public override func evaluate(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector) {
		
		guard let page = contxt.getCurrentFilePath() else {
			print("Exception while executing partial \(tag): unable to find template root directory")
			return
		}
		
		let pageDir = page.stringByDeletingLastPathComponent
		let fullPath = pageDir + "/" + self.tag + "." + mustacheExtension
		
		let file = File(fullPath)
		guard file.exists() else {
			print("Exception while executing partial \(tag): file not found")
			return
		}
		do {
			try file.openRead()
			defer { file.close() }
			let bytes = try file.readSomeBytes(count: file.size())
			
			// !FIX! cache parsed mustache files
			// check mod dates for recompilation
			
			let parser = MustacheParser()
			let str = UTF8Encoding.encode(bytes: bytes)
			let template = try parser.parse(string: str)
			
			try template.evaluatePragmas(context: contxt, collector: collector, requireHandler: false)
			
			let newContext = contxt.newChildContext()
			newContext.filePath = fullPath
			template.evaluate(context: newContext, collector: collector)
			
		} catch let e {
			print("Exception while executing partial \(tag): \(e)")
		}
	}
}

/// A sub-class of MustacheTag which represents a pragma tag.
/// Pragma tags are "meta" tags which influence template evaluation but likely do not output any data.
public class MustachePragmaTag : MustacheTag {
	
	override func clone() -> MustacheTag {
		let s = MustachePragmaTag()
		self.populateClone(s)
		return s
	}
	
	/// Parse the pragma. Pragmas should be in the format: A:B,C:D,E,F:G.
	/// - returns: A Dictionary containing the pragma names and values.
	public func parsePragma() -> Dictionary<String, String> {
		var d = Dictionary<String, String>()
		let commaSplit = tag.characters.split() { $0 == Character(",") }.map { String($0) }
		for section in commaSplit {
			let colonSplit = section.characters.split() { $0 == Character(":") }.map { String($0) }
			if colonSplit.count == 1 {
				d[colonSplit[0]] = ""
			} else if colonSplit.count > 1 {
				d[colonSplit[0]] = colonSplit[1]
			}
		}
		return d
	}
	
}

/// A sub-class of MustacheTag which represents a group of child tags.
public class MustacheGroupTag : MustacheTag {
	var children = [MustacheTag]()
	
	override func clone() -> MustacheTag {
		let s = MustacheGroupTag()
		self.populateClone(s)
		return s
	}
	
	override func populateClone(_ tag: MustacheTag) {
		super.populateClone(tag)
		if let groupTag = tag as? MustacheGroupTag {
			groupTag.children = self.children.map { $0.clone() }
		}
	}
	
	func evaluatePos(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector) {
		let cValue = contxt.getValue(named: tag)
		if let value = cValue {
			// if it is a dictionary, then eval children with it as the new context
			// otherwise, it must be an array with elements which are dictionaries
			switch value {
			case let v as MustacheEvaluationContext.MapType:
				let newContext = contxt.newChildContext(withMap: v)
				for child in children {
					child.evaluate(context: newContext, collector: collector)
				}
			// case let v as [String:String]:
			// 	let newContext = context.newChildContext(v)
			// 	for child in children {
			// 		child.evaluate(newContext, collector: collector)
			// 	}
			case let sequence as MustacheEvaluationContext.SequenceType:
				for item in sequence {
					let newContext = contxt.newChildContext(withMap: item)
					for child in children {
						child.evaluate(context: newContext, collector: collector)
					}
				}
			case let lambda as (String, MustacheEvaluationContext) -> String:
				let _ = collector.append(lambda(bodyText(), contxt), encoded: false)
			case let stringValue as String where stringValue.characters.count > 0:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			case let booleanValue as Bool where booleanValue == true:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			case let intValue as Int where intValue != 0:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			case let decValue as Double where decValue != 0.0:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			default:
				()
			}
		}
	}

	func evaluateNeg(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector) {
		let cValue = contxt.getValue(named: tag)
		if let value = cValue {
			switch value {
			case let v as MustacheEvaluationContext.MapType where v.count == 0:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			case let v as [String:String] where v.count == 0:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			case let sequence as MustacheEvaluationContext.SequenceType where sequence.count == 0:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			case let booleanValue as Bool where booleanValue == false:
				for child in children {
					child.evaluate(context: contxt, collector: collector)
				}
			default:
				()
			}
		} else {
			for child in children {
				child.evaluate(context: contxt, collector: collector)
			}
		}
	}
	
	/// Evaluate the tag in the given context.
	public override func evaluate(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector) {
		if type == .Hash {
			self.evaluatePos(context: contxt, collector: collector)
		} else if type == .Caret {
			self.evaluateNeg(context: contxt, collector: collector)
		} else {
			// optionally a warning?
			// otherwise this is a perfectly valid situation
		}
	}
	
	func bodyText() -> String {
		var s = ""
		for child in children {
			s.append(child.description())
		}
		return s
	}
	
	/// Returns a String containing the reconstituted tag, including all children.
	override public func description() -> String {
		var s = super.description()
		for child in children {
			s.append(child.description())
		}
		s.append(delimOpen() + "/ " + tag + " " + delimClose())
		return s
	}
}

/// This class represents a mustache template which has been parsed and is ready to evaluate.
/// It contains a series of "out of band" pragmas which can influence the evaluation, and a 
/// series of children which constitute the body of the template itself.
public class MustacheTemplate : MustacheGroupTag {
	
	var pragmas = [MustachePragmaTag]()
	var templateName: String = ""
	
	override func clone() -> MustacheTag {
		let s = MustacheTemplate()
		self.populateClone(s)
		return s
	}
	
	override func populateClone(_ tag: MustacheTag) {
		super.populateClone(tag)
		if let template = tag as? MustacheTemplate {
			template.pragmas = self.pragmas.flatMap { $0.clone() as? MustachePragmaTag }
			self.templateName = template.templateName
		}
	}
	
	/// Evaluate any pragmas which were found in the template. These pragmas may alter the given `MustacheEvaluationContext` parameter.
	/// - parameter context: The `MustacheEvaluationContext` object which will be used to further evaluate the template.
	/// - parameter collector: The `MustacheEvaluationOutputCollector` object which will collect all output from the template evaluation.
	/// - parameter requireHandler: If true, the pragmas must contain a PageHandler pragma which must indicate a previously registered handler object. If a global page handler has been registered then it will be utilized. If `requireHandler` is false, the global handler will NOT be sought.
	/// - throws: If `requireHandler` is true and the a handler pragma does not exist or does not indicate a properly registered handler object, then this function will throw `MustacheError.EvaluationError`.
	public func evaluatePragmas(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector, requireHandler: Bool = true) throws {
//		for pragma in pragmas {
//			let d = pragma.parsePragma()
//			...
//		}
	}
	
	/// Evaluate the template using the given context and output collector.
	/// - parameter context: The `MustacheEvaluationContext` object which holds the values used for evaluating the template.
	/// - parameter collector: The `MustacheEvaluationOutputCollector` object which will collect all output from the template evaluation. `MustacheEvaluationOutputCollector.asString()` can be called to retreive the resulting output data.
	override public func evaluate(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector) {
		for child in children {
			child.evaluate(context: contxt, collector: collector)
		}
		contxt.webResponse = nil
	}
	
	/// Returns a String containing the reconstituted template, including all children.
	override public func description() -> String {
		var s = ""
		for child in children {
			s.append(child.description())
		}
		return s
	}
}

/// This object will parse templates written in the mustache markup language.
/// Calling `parse` with the path to a file will return the resulting parsed and ready to evaluate template.
public class MustacheParser {
	
	var activeList: MustacheGroupTag?
	var pragmas = [MustachePragmaTag]()
	var openDelimiters: [UnicodeScalar] = ["{", "{"]
	var closeDelimiters: [UnicodeScalar] = ["}", "}"]
	var handlingUnencodedName = false
	var testingPutback: String?
	
	typealias UGen = String.UnicodeScalarView.Generator
	
	var g: UGen?
	var offset = -1
	
	/// Empty public initializer.
	public init() {
		
	}
	
	/// Parses a string containing mustache markup and returns the `MustacheTemplate` object.
	/// - throws: `MustacheError.SyntaxError`
	/// - returns: A `MustacheTemplate` object which can be evaluated.
	public func parse(string strng: String) throws -> MustacheTemplate {
		
		let t = MustacheTemplate()
		self.activeList = t
		self.g = strng.unicodeScalars.makeIterator()
		
		try consumeLoop()
		
		t.pragmas = pragmas
		
		return t
	}
	
	func next() -> UnicodeScalar? {
		offset += 1
		return g!.next()
	}
	
	func consumeLoop() throws {
		var type = MustacheTagType.Plain
		repeat {
			type = try consumeType(type)
			// just loop it
		} while type != .None
	}
	
	func consumeType(_ t: MustacheTagType) throws -> MustacheTagType {
		switch t {
		case .Plain:
			return consumePlain()
		case .Tag:
			return try consumeTag()
		default:
			throw MustacheError.SyntaxError("Bad parsing logic in consumeType \(t)")
		}
	}
	
	func addChild(_ t: MustacheTag) {
		self.activeList!.children.append(t)
		t.parent = self.activeList!
		
		t.openD = openDelimiters
		t.closeD = closeDelimiters
	}
	
	// Read until delimiters are encountered
	func consumePlain() -> MustacheTagType {
		
		let currTag = MustacheTag()
		currTag.type = .Plain
		
		addChild(currTag)
		
		while true {
			guard let e = next() else {
				return .None
			}
			
			if e == openDelimiters[0] {
				testingPutback = String(e)
				if consumePossibleOpenDelimiter(index: 1) {
					return .Tag
				}
				currTag.tag.append(testingPutback!)
			} else {
				currTag.tag.append(e)
			}
		}
	}
	
	func consumePossibleOpenDelimiter(index idx: Int) -> Bool {
		if idx == openDelimiters.count { // we successfully encountered a full delimiter sequence
			return true
		}
		if let e = next() {
			testingPutback!.append(e)
			if e == openDelimiters[idx] {
				return consumePossibleOpenDelimiter(index: 1 + idx)
			}
		}
		return false
	}
	
	func consumePossibleCloseDelimiter(index idx: Int) -> Bool {
		if idx == closeDelimiters.count { // we successfully encountered a full delimiter sequence
			return true
		}
		if let e = next() {
			if e == closeDelimiters[idx] {
				testingPutback!.append(e)
				return consumePossibleCloseDelimiter(index: 1 + idx)
			}
		}
		return false
	}
	
	// Read until delimiters are encountered
	func consumeTag() throws -> MustacheTagType {
		
		if let e = skipWhiteSpace() {
			// e is first non-white character
			// # ^ ! >
			switch e {
			
			case "%": // pragma
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				let newTag = MustachePragmaTag()
				newTag.tag = tagName
				newTag.type = .Pragma
				addChild(newTag)
				pragmas.append(newTag)
				
			case "#": // group
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				let newTag = MustacheGroupTag()
				newTag.tag = tagName
				newTag.type = .Hash
				addChild(newTag)
				activeList = newTag
				
			case "^": // inverted group
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				let newTag = MustacheGroupTag()
				newTag.tag = tagName
				newTag.type = .Caret
				addChild(newTag)
				activeList = newTag
				
			case "!": // comment COULD discard but I add it for debugging purposes. skipped during eval
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				let newTag = MustacheTag()
				newTag.tag = tagName
				newTag.type = .Bang
				addChild(newTag)
				
			case "&": // unescaped name
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				let newTag = MustacheTag()
				newTag.tag = tagName
				newTag.type = .UnescapedName
				addChild(newTag)
				
			case ">": // partial
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				let newTag = MustachePartialTag()
				newTag.tag = tagName
				newTag.type = .Partial
				addChild(newTag)
				
			case "/": // pop group. ensure names match
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				guard tagName == activeList!.tag else {
					throw MustacheError.SyntaxError("The closing tag /" + tagName + " did not match " + activeList!.tag)
				}
				activeList = activeList!.parent
			
			case "=": // set delimiters
				try consumeSetDelimiters()
			
			case "{": // unencoded name
				handlingUnencodedName = true
				let tagName = consumeTagName(firstChar: skipWhiteSpace())
				let newTag = MustacheTag()
				newTag.tag = tagName
				newTag.type = .UnencodedName
				addChild(newTag)
				guard !handlingUnencodedName else {
					throw MustacheError.SyntaxError("The unencoded tag " + tagName + " did not proper closing delimiters")
				}
			default:
				let tagName = consumeTagName(firstChar: e)
				let newTag = MustacheTag()
				newTag.tag = tagName
				newTag.type = .Name
				addChild(newTag)
			}
		}
		return .Plain
	}
	
	// reads until closing delimiters
	// read and discard closing delimiters leaving us things at .Plain
	func consumeTagName() -> String {
		var s = ""
		return consumeTagName(into: &s)
	}
	
	// reads until closing delimiters
	// firstChar was read as part of previous step and should be added to the result
	func consumeTagName(firstChar first: UnicodeScalar?) -> String {
		
		guard let f = first else {
			return ""
		}
		
		var s = String(f)
		return consumeTagName(into: &s)
	}
	
	#if swift(>=3.0)
	func consumeTagName(into s: inout String) -> String {
		while let e = next() {
			if handlingUnencodedName && e == "}" {
				handlingUnencodedName = false
				continue
			}
			if e == closeDelimiters[0] {
				testingPutback = String(e)
				if consumePossibleCloseDelimiter(index: 1) {
					break
				}
				s.append(testingPutback!)
			} else {
				s.append(e)
			}
		}
		var scalars = s.unicodeScalars
		var idx = scalars.index(before: scalars.endIndex)
		while scalars[idx].isWhiteSpace() {
			scalars.remove(at: idx)
			idx = scalars.index(before: idx)
		}
		return String(scalars)
	}
	#else
	func consumeTagName(inout into s: String) -> String {
		while let e = next() {
			if handlingUnencodedName && e == "}" {
				handlingUnencodedName = false
				continue
			}
			if e == closeDelimiters[0] {
				testingPutback = String(e)
				if consumePossibleCloseDelimiter(index: 1) {
					break
				}
				s.append(testingPutback!)
			} else {
				s.append(e)
			}
		}
		var scalars = s.unicodeScalars
		var idx = scalars.endIndex.predecessor()
		while scalars[idx].isWhiteSpace() {
			scalars.remove(at: idx)
			idx = idx.predecessor()
		}
		return String(scalars)
	}
	#endif
	
	func skipWhiteSpace() -> UnicodeScalar? {
		var e = next()
		while e != nil {
			if !(e!).isWhiteSpace() {
				return e
			}
			e = next()
		}
		return e
	}
	
	func consumeSetDelimiters() throws {
		let errorMsg = "Syntax error while setting delimiters"
		var e = skipWhiteSpace()
		if e != nil {
			
			var openD = String(e!)
			// read until a white space
			while true {
				
				e = next()
				if e != nil && !(e!).isWhiteSpace() {
					openD.append(e!)
				} else {
					break
				}
			}
			
			guard e != nil && (e!).isWhiteSpace() else {
				throw MustacheError.SyntaxError(errorMsg)
			}
			
			e = skipWhiteSpace()
			
			guard e != nil && !(e!).isWhiteSpace() else {
				throw MustacheError.SyntaxError(errorMsg)
			}
			
			var closeD = String(e!)
			// read until a =
			while true {
				
				e = next()
				if e != nil && !(e!).isWhiteSpace() && e! != "=" {
					closeD.append(e!)
				} else {
					break
				}
			}
			
			if e != nil && (e!).isWhiteSpace() {
				e = skipWhiteSpace()
				guard e != nil && e! == "=" else {
					throw MustacheError.SyntaxError(errorMsg)
				}
			}
			
			e = skipWhiteSpace()
			guard e != nil else {
				throw MustacheError.SyntaxError(errorMsg)
			}
			guard e! == closeDelimiters[0] && consumePossibleCloseDelimiter(index: 1) else {
				throw MustacheError.SyntaxError(errorMsg)
			}
			
			setDelimiters(open: Array(openD.unicodeScalars), close: Array(closeD.unicodeScalars))
		}
	}
	
	func setDelimiters(open opn: [UnicodeScalar], close: [UnicodeScalar]) {
		openDelimiters = opn
		closeDelimiters = close
	}
}

public protocol MustachePageHandler {
	func valuesForResponse(context contxt: MustacheEvaluationContext, collector: MustacheEvaluationOutputCollector) throws -> MustacheEvaluationContext.MapType
}

public func mustacheRequest(request req: WebRequest, response: WebResponse, handler: MustachePageHandler, path: String) throws {
	
	let template = try getTemplateFromCache(path)
	
	let context = MustacheEvaluationContext(webResponse: response)
	context.filePath = path
	
	let collector = MustacheEvaluationOutputCollector()
	template.templateName = path.lastPathComponent
	
	try template.evaluatePragmas(context: context, collector: collector)
	
	let values = try handler.valuesForResponse(context: context, collector: collector)
	context.extendValues(with: values)
	
	template.evaluate(context: context, collector: collector)
	
	let fullString = collector.asString()
	response.appendBody(string: fullString)
}


