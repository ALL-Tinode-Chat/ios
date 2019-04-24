//
//  Drafty.swift
//  ios
//
//  Copyright © 2018 Tinode. All rights reserved.
//

import Foundation

public enum DraftyError: Error {
    case illegalArgument(String)
    case invalidIndex(String)
}

public class Drafty: Codable {
    public static let kMimeType = "text/x-drafty"
    public static let kJSONMimeType = "application/json"

    private static let kMaxFormElements = 8

    // Regular expressions for parsing inline formats.
    // Name of the style, regexp start, regexp end
    private static let kInlineStyleName = ["ST", "EM", "DL", "CO"]
    private static let kInlineStyleRE = try! [
        NSRegularExpression(pattern: #"(?<=^|\W)\*([^\s*]+)\*(?=$|\W)"#),     // bold *bo*
        NSRegularExpression(pattern: #"(?<=^|[\W_])_([^\s_]+)_(?=$|[\W_])"#), // italic _it_
        NSRegularExpression(pattern: #"(?<=^|\W)~([^\\s~]+)~(?=$|\W)"#),      // strikethough ~st~
        NSRegularExpression(pattern: #"(?<=^|\W)`([^`]+)`(?=$|\W)"#)          // code/monospace `mono`
    ]

    private static let kEntityName = ["LN", "MN", "HT"]
    private static let kEntityProc = [
        EntityProc(name: "LN",
                   pattern: NSRegularExpression(pattern: #"(?<=^|\W)(https?://)?(?:www\.)?[-a-zA-Z0-9@:%._+~#=]{2,256}\.[a-z]{2,4}\b(?:[-a-zA-Z0-9@:%_+.~#?&/=]*)"#),
                   pack: {(m: Matcher) -> [String:JSONValue] in
                    var data: [String:JSONValue] = [:]
                    data["url"] = m.group(1) == nil ? "http://" + m.group() : m.group()
                    return data
            }),
        EntityProc(name: "MN",
                   pattern: NSRegularExpression(pattern: #"\B@(\w\w+)"#),
                   pack: {(m: Matcher) -> [String:JSONValue] in
                    var data: [String:JSONValue] = [:]
                    data["val"] = m.group()
                    return data
            }),
        EntityProc(name: "HT",
                   pattern: NSRegularExpression(pattern: #"(?<=[\s,.!]|^)#(\w\w+)"#),
                   pack: {(m: Matcher) -> [String:JSONValue] in
                    var data: [String:JSONValue] = [:]
                    data["val"] = m.group()
                    return data
            })
    ]

    public var txt: String?
    public var fmt: [Style]?
    public var ent: [Entity]?

    public init() {
    }

    public init(content: String) {
        let that = Drafty.parse(content: content)

        self.txt = that.txt
        self.fmt = that.fmt
        self.ent = that.ent
    }

    init(text: String, fmt: [Style], ent: [Entity]) {
        self.txt = text
        self.fmt = fmt
        self.ent = ent
    }

    // Detect starts and ends of formatting spans. Unformatted spans are
    // ignored at this stage.
    private static func spannify(original: String, re: NSRegularExpression, type: String) -> [Span] {
        var spans: [Span] = []
        let matches = re.matches(in: original, range: NSRange(location: 0, length: original.count)
        while matcher.find() {
            var s = Span()
            s.start = matcher.start(0)  // 'hello *world*'
            // ^ group(zero) -> index of the opening markup character
            s.end = matcher.end(1)      // group(one) -> index of the closing markup character
            s.text = matcher.group(1)          // text without of the markup
            s.type = type
            spans.append(s)
        }
        return spans
    }

    // Take a string and defined earlier style spans, re-compose them into a tree where each leaf is
    // a same-style (including unstyled) string. I.e. 'hello *bold _italic_* and ~more~ world' ->
    // ('hello ', (b: 'bold ', (i: 'italic')), ' and ', (s: 'more'), ' world');
    //
    // This is needed in order to clear markup, i.e. 'hello *world*' -> 'hello world' and convert
    // ranges from markup-ed offsets to plain text offsets.
    private static func chunkify(line: String, start startAt: Int, end: Int, spans: [Span]?) -> [Span]? {
        guard let spans = spans, spans.count > 0 else { return nil }

        var start = startAt
        var chunks: [Span] = []
        for span in spans {
            // Grab the initial unstyled chunk.
            if span.start > start {
                chunks.append(Span(text: line.substring(start, span.start)))
            }

            // Grab the styled chunk. It may include subchunks.
            let chunk = Span()
            chunk.type = span.type

            let chld = chunkify(line: line, start: span.start + 1, end: span.end - 1, spans: span.children)
            if chld != nil {
                chunk.children = chld!
            } else {
                chunk.text = span.text
            }

            chunks.append(chunk)
            start = span.end + 1 // '+1' is to skip the formatting character
        }

        // Grab the remaining unstyled chunk, after the last span
        if start < end {
            chunks.append(Span(text: line.substring(start, end)))
        }

        return chunks
    }

    private static func toTree(spans: [Span]?) -> [Span]? {
        guard let spans = spans, spans.count > 0 else { return nil }

        var tree: [Span] = []

        var last = spans[0]
        tree.append(last)
        for i in 0...spans.count {
            let curr = spans[i]
            // Keep spans which start after the end of the previous span or those which
            // are complete within the previous span.
            if curr.start > last.end {
                // Span is completely outside of the previous span.
                tree.append(curr)
                last = curr
            } else if curr.end < last.end {
                // Span is fully inside of the previous span. Push to subnode.
                if last.children == nil {
                    last.children = []
                }
                last.children!.append(curr)
            }
            // Span could also partially overlap, ignore it as invalid.
        }

        // Recursively rearrange the subnodes.
        for s in tree {
            s.children = toTree(spans: s.children)
        }

        return tree
    }

    // Convert a list of chunks into block.
    private static func draftify(chunks: [Span]?, startAt: Int) -> Block? {
        guard let chunks = chunks else { return nil }

        let block = Block(txt: "")
        var ranges: [Style] = []
        for chunk in chunks {
            if chunk.text == nil {
                if let drafty = draftify(chunks: chunk.children, startAt: block.txt.count + startAt) {
                    chunk.text = drafty.txt
                    if drafty.fmt != nil {
                        ranges.append(contentsOf: drafty.fmt!)
                    }
                }
            }

            if chunk.type != nil {
                ranges.append(Style(tp: chunk.type, at: block.txt.count + startAt, len: chunk.text.count))
            }

            if chunk.text != nil {
                block.txt += chunk.text!
            }
        }

        if ranges.count > 0 {
            block.fmt = ranges
        }

        return block
    }

    // Get a list of entities from a text.
    private static func extractEntities(line: String) -> [ExtractedEnt] {
        var extracted: [ExtractedEnt] = []

        for i in 0...Drafty.kEntityName.count {
            var matcher = kEntityProc[i].re.matcher(line)
            while matcher.find() {
                var ee = ExtractedEnt()
                ee.at = matcher.start(0)
                ee.value = matcher.group(0)
                ee.len = ee.value.count
                ee.tp = kEntityName[i];
                ee.data = kEntityProc[i].pack(matcher)
                extracted.append(ee)
            }
        }

        return extracted;
    }

    public static func parse(content: String) -> Drafty {
        // Break input into individual lines. Format cannot span multiple lines.
        let lines = content.split { $0 == "\n" || $0 == "\r\n" }.map(String.init)
        var blks: [Block] = []
        var refs: [Entity] = []

        var spans: [Span] = []
        var entityMap: [String:JSONValue] = [:]
        var entities: [ExtractedEnt]
        for line in lines {
            spans = []
            // Select styled spans.
            for i in 0...Drafty.kInlineStyleName.count {
                spans.append(contentsOf: spannify(original: line, re: Drafty.kInlineStyleRE[i], type: Drafty.kInlineStyleName[i]))
            }

            let b: Block
            if !spans.isEmpty {
                // Sort styled spans in ascending order by .start
                Collection.sort(spans)

                // Rearrange linear list of styled spans into a tree, throw away invalid spans.
                spans = toTree(spans: spans)

                // Parse the entire string into spans, styled or unstyled.
                spans = chunkify(line: line, start: 0, end: line.count, spans: spans)

                // Convert line into a block.
                b = draftify(chunks: spans, startAt: 0)
            } else {
                b = Block(txt: line)
            }

            // Extract entities from the string already cleared of markup.
            entities = extractEntities(line: b.txt)
            // Normalize entities by splitting them into spans and references.
            for ent in entities {
                // Check if the entity has been indexed already
                var index = entityMap[ent.value]
                if index == nil {
                    index = refs.count;
                    entityMap[ent.value] = index
                    refs.append(Entity(tp: ent.tp, data: ent.data))
                }

                b.addStyle(Style(ent.at, ent.len, index))
            }

            blks.append(b)
        }

        var text: String = ""
        var fmt: [Style] = []
        // Merge lines and save line breaks as BR inline formatting.
        if blks.count > 0 {
            var b = blks[0]
            if let btxt = b.txt {
                text.append(btxt)
            }
            if let bfmt = b.fmt {
                fmt.append(contentsOf: bfmt)
            }
            for i in 0...blks.count {
                let offset = text.count + 1
                fmt.append(Style(tp: "BR", at: offset - 1, len: 1))

                b = blks[i]
                text.append(" ")
                if let btxt = b.txt {
                    text.append(btxt)
                }
                if let bfmt = b.fmt {
                    for s in bfmt {
                        s.at += offset
                        fmt.append(s)
                    }
                }
            }
        }

        return Drafty(text.toString(),
                          fmt.size() > 0 ? fmt.toArray(new Style[0]) : nil,
                          refs.size() > 0 ? refs.toArray(new Entity[0]) : nil)
    }

    public func getStyles() -> [Style]? {
        return fmt
    }

    public func getEntities() -> [Entity]? {
        return ent
    }

    /**
     * Extract attachment references for use in message header.
     *
     * @return string array of attachment references or null if no attachments with references found.
     */
    public func getEntReferences() -> [String]? {
        guard let ent = ent else { return nil }

        var result: [String] = []
        for anEnt in ent {
            if let ref = anEnt.data?["ref"] {
                result.append(ref)
            }
        }
        return result.isEmpty ? nil : result
    }

    public func entityFor(style: Style) -> Entity? {
        let index = style.key ?? 0
        guard let ent = ent, ent.count > index else { return nil }
        return ent[index]
    }

    // Convert Drafty to plain text;
    public var string: String {
        get {
            return txt ?? ""
        }
    }

    // Make sure Drafty is properly initialized for entity insertion.
    private func prepareForEntity(at: Int, len: Int) {
        if fmt == nil {
            fmt = []
        }
        if ent == nil {
            ent = []
        }
        fmt!.append(Style(at: at, len: len, key: ent!.count))
    }
    /**
     * Insert inline image
     *
     * @param at location to insert image at
     * @param mime Content-type, such as 'image/jpeg'.
     * @param bits Content as an array of bytes
     * @param width image width in pixels
     * @param height image height in pixels
     * @param fname name of the file to suggest to the receiver.
     * @return 'this' Drafty object.
     */
    public func insertImage(at: Int, mime: String?, bits: Data, width: Int, height: Int, fname: String?) -> Drafty {
        return try! insertImage(at: at, mime: mime, bits: bits, width: width, height: height, fname: fname, refurl: nil, size: 0)
    }

    /**
     * Insert inline image
     *
     * @param at location to insert image at
     * @param mime Content-type, such as 'image/jpeg'.
     * @param bits Content as an array of bytes
     * @param width image width in pixels
     * @param height image height in pixels
     * @param fname name of the file to suggest to the receiver.
     * @param refurl Reference to full/extended image.
     * @param size file size hint (in bytes) as reported by the client.
     *
     * @return 'this' Drafty object.
     */
    public func insertImage(at: Int, mime: String?, bits: Data?, width: Int, height: Int, fname: String?, refurl: URL?, size: Int) throws -> Drafty {
        guard bits != nil || refurl != nil else {
            throw DraftyError.illegalArgument("Either image bits or reference URL must not be null.")
        }

        guard let txt = txt, txt.count > at && at >= 0 else {
            throw DraftyError.invalidIndex("Invalid insertion position")
        }

        prepareForEntity(at: at, len: 1)

        var data: [String:JSONValue] = [:]
        if let mime = mime, !mime.isEmpty {
            data["mime"] = JSONValue.string(mime)
        }
        if let bits = bits {
            data["val"] = JSONValue.bits(bits)
        }
        data["width"] = JSONValue.int(width)
        data["height"] = JSONValue.int(height)
        if let fname = fname, !fname.isEmpty {
            data["name"] = JSONValue.string(fname)
        }
        if let refurl = refurl {
            data["ref"] = JSONValue.string(refurl.absoluteString)
        }
        if size > 0 {
            data["size"] = JSONValue.int(size)
        }
        ent!.append(Entity(tp: "IM", data: data))

        return self
    }

    /**
     * Attach file to a drafty object in-band.
     *
     * @param mime Content-type, such as 'text/plain'.
     * @param bits Content as an array of bytes.
     * @param fname Optional file name to suggest to the receiver.
     * @return 'this' Drafty object.
     */
    public func attachFile(mime: String?, bits: Data, fname: String?) -> Drafty {
        return try! attachFile(mime: mime, bits: bits, fname: fname, refurl: nil, size: bits.count)
    }

    /**
     * Attach file to a drafty object as a reference.
     *
     * @param mime Content-type, such as 'text/plain'.
     * @param fname Optional file name to suggest to the receiver
     * @param refurl reference to content location. If URL is relative, assume current server.
     * @param size size of the attachment (untrusted).
     * @return 'this' Drafty object.
     */
    public func attachFile(mime: String?, fname: String?, refurl: URL, size: Int) throws -> Drafty {
        return try! attachFile(mime: mime, bits: nil, fname: fname, refurl: refurl, size: size)
    }

    /**
     * Attach file to a drafty object.
     *
     * @param mime Content-type, such as 'text/plain'.
     * @param fname Optional file name to suggest to the receiver.
     * @param bits File content to include inline.
     * @param refurl Reference to full/extended file content.
     * @param size file size hint as reported by the client.
     *
     * @return 'this' Drafty object.
     */
    internal func attachFile(mime: String?, bits: Data?, fname: String?, refurl: URL?, size: Int) throws -> Drafty {
        guard bits != nil || refurl != nil else {
            throw DraftyError.illegalArgument("Either file bits or reference URL must not be nil.")
        }

        prepareForEntity(at: -1, len: 1);

        var data: [String:JSONValue] = [:]
        if let mime = mime, !mime.isEmpty {
            data["mime"] = JSONValue.string(mime)
        }
        if let bits = bits {
            data["val"] = JSONValue.bits(bits)
        }
        if let fname = fname, !fname.isEmpty {
            data["name"] = JSONValue.string(fname)
        }
        if let refurl = refurl {
            data["ref"] = JSONValue.string(refurl.absoluteString)
        }
        if size > 0 {
            data["size"] = JSONValue.int(size)
        }
        ent!.append(Entity(tp: "EX", data: data))

        return self
    }

    /**
     * Attach object as json. Intended to be used as a form response.
     *
     * @param json object to attach.
     * @return 'this' Drafty object.
     */
    public func attachJSON(json: [String:JSONValue]) -> Drafty {
        prepareForEntity(at: -1, len: 1)

        var data: [String:JSONValue] = [:]
        data["mime"] = JSONValue.string(Drafty.kJSONMimeType)
        data["val"] = JSONValue.dict(json)
        ent!.append(Entity(tp: "EX", data: data))

        return self
    }


    /**
     * Insert button into Drafty document.
     * @param at is location where the button is inserted.
     * @param len is the length of the text to be used as button title.
     * @param name is an opaque ID of the button. Client should just return it to the server when the button is clicked.
     * @param actionType is the type of the button, one of 'url' or 'pub'.
     * @param actionValue is the value associated with the action: 'url': URL, 'pub': optional data to add to response.
     * @param refUrl parameter required by URL buttons: url to go to on click.
     *
     * @return 'this' Drafty object.
     */
    internal func insertButton(at: Int, len: Int, name: String?, actionType: String, actionValue: String?, refUrl: URL?) throws -> Drafty {
        prepareForEntity(at: at, len: len)

        guard actionType == "url" || actionType == "pub" else {
            throw DraftyError.illegalArgument("Unknown action type \(actionType)")
        }
        guard actionType == "pub"  || refUrl != nil else {
            throw DraftyError.illegalArgument("URL required for URL buttons")
        }

        var data: [String:JSONValue] = [:]
        data["act"] = JSONValue.string(actionType)
        if let name = name, !name.isEmpty {
            data["name"] = JSONValue.string(name)
        }
        if let actionValue = actionValue, !actionValue.isEmpty {
            data["val"] = JSONValue.string(actionValue)
        }
        if actionType == "url" {
            data["ref"] = JSONValue.string(refUrl!.absoluteString)
        }

        ent!.append(Entity(tp: "BN", data: data))

        return self
    }

    /**
     * Check if the give Drafty can be represented by plain text.
     *
     * @return true if this Drafty has no markup other thn line breaks.
     */
    public func isPlain() -> Bool {
        return ent == nil && fmt == nil
    }

    // Inverse of chunkify. Returns a tree of formatted spans.
    private func forEach<T>(line: String, start: Int, end: Int, spans: [Span]?, formatter: Formatter) -> [T] {
        var result: [T] = []
        guard let spans = spans else {
            if let fs = formatter<T>.apply(nil, nil, line.substring(start, end)) {
                result.append(fs)
            }
            return result
        }

        // Process ranges calling formatter for each range.
        var iter = spans.makeIterator()
        while let span = iter.next() {
            if span.start < 0 && span.type == "EX" {
                // This is different from JS SDK. JS ignores these spans here.
                // JS uses Drafty.attachments() to get attachments.
                if let fs = formatter.apply(span.type, span.data, nil) {
                    result.append(fs)
                }
                continue
            }

            // Add un-styled range before the styled span starts.
            if start < span.start {
                if let fs = formatter.apply(nil, nil, line.substring(start, span.start)) {
                    result.append(fs)
                }
                start = span.start
            }

            // Get all spans which are within the current span.
            var subspans: [Span] = []
            while let inner = iter.next() {
                if inner.start < span.end {
                    subspans.append(inner)
                } else {
                    // Move back.
                    iter.previous();
                    break
                }
            }

            if subspans.isEmpty {
                subspans = nil
            }

            if span.type == "BN" {
                // Make button content unstyled.
                span.data = span.data != nil ? span.data : [:]
                let title = line.substring(span.start, span.end)
                span.data["title"] = JSONValue.string(title)
                if let fs = formatter.apply(span.type, span.data, title) {
                    result.append(fs)
                }
            } else {
                if let fs = formatter.apply(span.type, span.data,
                                            forEach(line, start, span.end, subspans, formatter)) {
                    result.append(fs)
                }
            }

            start = span.end
        }

        // Add the last unformatted range.
        if start < end {
            if let fs = formatter.apply(null, null, line.substring(start, end)) {
                result.append(fs)
            }
        }

        return result
    }

    /**
     * Format converts Drafty object into a collection of formatted nodes.
     * Each node contains either a formatted element or a collection of
     * formatted elements.
     *
     * @param formatter is an interface with an `apply` method. It's iteratively
     *                  applied to every node in the tree.
     * @return a tree of components.
     */
    public func format(formatter: Formatter) -> Any {
        if txt == nil {
            txt = ""
        }

        // Handle special case when all values in fmt are 0 and fmt is therefore was
        // skipped.
        if (fmt == null || fmt.length == 0) {
            if (ent != null && ent.length == 1) {
                fmt = new Style[1];
                fmt[0] = new Style(0, 0, 0);
            } else {
                return formatter.apply(null, null, txt);
            }
        }

        List<Span> spans = new ArrayList<>();
        for (Style aFmt : fmt) {
            if (aFmt.len < 0) {
                aFmt.len = 0;
            }
            if (aFmt.at < -1) {
                aFmt.at = -1;
            }
            if (aFmt.tp == null || "".equals(aFmt.tp)) {
                spans.add(new Span(aFmt.at, aFmt.at + aFmt.len,
                                   aFmt.key != null ? aFmt.key : 0));
            } else {
                spans.add(new Span(aFmt.tp, aFmt.at, aFmt.at + aFmt.len));
            }
        }

        // Sort spans first by start index (asc) then by length (desc).
        Collections.sort(spans, new Comparator<Span>() {
            @Override
            public int compare(Span a, Span b) {
                if (a.start - b.start == 0) {
                    return b.end - a.end; // longer one comes first (<0)
                }
                return a.start - b.start;
            }
        });

        for (Span span : spans) {
            if (ent != null && (span.type == null || "".equals(span.type))) {
                if (span.key >= 0 && span.key < ent.length && ent[span.key] != null) {
                    span.type = ent[span.key].tp;
                    span.data = ent[span.key].data;
                }
            }

            // Is type still undefined? Hide the invalid element!
            if (span.type == null || "".equals(span.type)) {
                span.type = "HD";
            }
        }

        return formatter.apply(nil, nil, forEach(txt, 0, txt.length(), spans, formatter));
    }

    private var plainText: String {
        return "{txt: '\(txt)', fmt: \(fmt),ent: \(ent)}"
    }

    // ================
    // Internal classes

    fileprivate class Block {
        var txt: String
        var fmt: [Style]?

        init(txt: String) {
            self.txt = txt
        }

        func addStyle(s: Style) {
            if fmt == nil {
                fmt = []
            }
            fmt!.append(s)
        }
    }

    fileprivate class Span: Comparable, CustomStringConvertible {
        var start: Int
        var end: Int
        var key: Int
        var text: String?
        var type: String?
        var data: [String:JSONValue]?
        var children: [Span]?

        init() {
        }

        init(text: String) {
            self.text = text
        }

        // Inline style
        init(type: String, start: Int, end: Int) {
            self.type = type
            self.start = start
            self.end = end
        }

        // Entity reference
        init(start: Int, end: Int, index: Int) {
            self.type = nil
            self.start = start
            self.end = end
            self.key = index
        }

        static func < (lhs: Drafty.Span, rhs: Drafty.Span) -> Bool {
            lhs.start < rhs.start
        }

        static func == (lhs: Drafty.Span, rhs: Drafty.Span) -> Bool {
            lhs.start == rhs.start
        }

        public var description: String {
            return """
            {start=\(start),end=\(end),type=\(type ?? "nil"),data=\(data?.description ?? "nil")}
            """
        }
    }

    fileprivate class ExtractedEnt {
        var at: Int
        var len: Int
        var tp: String
        var value: String

        var data: [String:Codable]

        init() {}
    }
}

public class Style: Codable, Comparable, CustomStringConvertible {
    var at: Int?
    var len: Int?
    var tp: String?
    var key: Int?

    public init() {}

    // Basic inline formatting
    public init(tp: String?, at: Int?, len: Int?) {
        self.at = at
        self.len = len
        self.tp = tp
        self.key = nil
    }

    // Entity reference
    public init(at: Int?, len: Int?, key: Int?) {
        self.tp = nil
        self.at = at
        self.len = len
        self.key = key
    }

    public static func < (lhs: Style, rhs: Style) -> Bool {
        if lhs.at == rhs.at {
            return lhs.len < rhs.len // longer one comes first (<0)
        }
        return lhs.at < rhs.at
    }

    public static func == (lhs: Style, rhs: Style) -> Bool {
        return lhs.at == rhs.at && lhs.at == rhs.at
    }

    public var description: String {
        return "{tp:'\(tp ?? "nil")', at:\(at), len:\(len), key:\(key)}";
    }
}

public class Entity: Codable, CustomStringConvertible {
    public var tp: String?
    public var data: [String:JSONValue]?

    public init() {}

    public init(tp: String?, data: [String:JSONValue]?) {
        self.tp = tp
        self.data = data
    }

    public var description: String {
        return "{tp:'\(tp ?? "nil")',data:\(data?.description ?? "nil")}";
    }
}


public protocol Formatter {
    associatedtype T
    func apply(tp: String, attr: [String:Codable], content: Any) -> T
}

fileprivate class EntityProc {
    var name: String
    var re: NSRegularExpression
    var pack: (_ m: Matcher) -> [String:JSONValue]

    init(name: String, pattern: NSRegularExpression, pack: (_ m: Matcher) -> [String:JSONValue]) {
        self.name = name
        self.re = pattern
        self.pack = pack
    }
}
