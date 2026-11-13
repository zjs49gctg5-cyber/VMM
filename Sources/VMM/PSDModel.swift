import Foundation

struct PSDLayer: Codable, Equatable, Identifiable {
    var id: Int
    var parent: Int?
    var name: String
    var group: Bool
    var visible: Bool
    var opacity: Double
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var file: String?
    var blend = "norm"
    var forced: Bool { name.hasPrefix("!") }
    var radio: Bool { name.hasPrefix("*") }
    var label: String { (forced || radio) ? String(name.dropFirst()) : name }
}

struct PSDDocument: Codable, Equatable {
    var width: Int
    var height: Int
    // Front-to-back order, including groups, with stable record IDs.
    var layers: [PSDLayer]
    var readme: String?
    var favorites: [PSDFavorite] = []
    var files: [String] { layers.compactMap(\.file) }
    func validate() throws {
        guard (1...16384).contains(width), (1...16384).contains(height), width * height <= 32_000_000, layers.count <= 2000,
              Set(layers.map(\.id)).count == layers.count else { throw VMMError.message("PSDのサイズ・レイヤー情報が不正です。") }
        var seen = Set<Int>()
        for layer in layers {
            guard layer.parent == nil || (seen.contains(layer.parent!) && layers.contains { $0.id == layer.parent && $0.group }),
                  layer.opacity.isFinite, (0...1).contains(layer.opacity), (0...16384).contains(layer.width), (0...16384).contains(layer.height),
                  (-32768...32768).contains(layer.x), (-32768...32768).contains(layer.y), ["norm", "pass"].contains(layer.blend),
                  layer.file == nil || (layer.file == URL(fileURLWithPath: layer.file!).lastPathComponent && ![".", "..", ""].contains(layer.file!) && !layer.file!.contains("/")) else { throw VMMError.message("PSDのレイヤー情報が不正です。") }
            seen.insert(layer.id)
        }
    }
    var defaults: [Int] { normalized(Set(layers.filter(\.visible).map(\.id))).sorted() }
    func isFlipVariant(_ layer: PSDLayer) -> Bool {
        var parts = layer.name.components(separatedBy: ":")
        var found = false
        while let last = parts.last, ["flipx", "flipy", "flipxy"].contains(last) { parts.removeLast(); found = true }
        return found && layers.contains { $0.parent == layer.parent && $0.name == parts.joined(separator: ":") }
    }
    func normalized(_ selected: Set<Int>) -> Set<Int> {
        var result = selected.intersection(Set(layers.map(\.id)))
        for layer in layers where isFlipVariant(layer) { result.remove(layer.id) }
        for layer in layers where layer.forced && !isFlipVariant(layer) { result.insert(layer.id) }
        let parents = Set(layers.filter { $0.radio && !isFlipVariant($0) }.map(\.parent))
        for parent in parents {
            let siblings = layers.filter { $0.parent == parent && $0.radio && !isFlipVariant($0) }
            let choice = siblings.first { result.contains($0.id) } ?? siblings.first
            for sibling in siblings { result.remove(sibling.id) }
            if let choice { result.insert(choice.id) }
        }
        return result
    }
    func selecting(_ id: Int, enabled: Bool, in selected: [Int]) -> [Int] {
        guard let layer = layers.first(where: { $0.id == id }) else { return selected }
        var result = Set(selected)
        if enabled {
            var current: PSDLayer? = layer
            while let node = current {
                if node.radio {
                    for sibling in layers where sibling.parent == node.parent && sibling.radio { result.remove(sibling.id) }
                }
                result.insert(node.id)
                current = node.parent.flatMap { parent in layers.first { $0.id == parent } }
            }
        } else if !layer.forced && !layer.radio { result.remove(id) }
        return normalized(result).sorted()
    }
    func flippedVisibility(_ selected: Set<Int>, x: Bool, y: Bool) -> Set<Int> {
        var result = selected
        let suffix = x && y ? "flipxy" : x ? "flipx" : y ? "flipy" : ""
        func baseAndModes(_ name: String) -> (String, Set<String>) {
            var parts = name.components(separatedBy: ":"), modes = Set<String>()
            while let last = parts.last, ["flipx", "flipy", "flipxy"].contains(last) { modes.insert(parts.removeLast()) }
            return (parts.joined(separator: ":"), modes)
        }
        func copyChildren(_ source: Int, _ target: Int) {
            let sourceChildren = layers.filter { $0.parent == source }
            let targetChildren = layers.filter { $0.parent == target }
            for child in targetChildren {
                let matches = sourceChildren.filter { $0.name == child.name }
                let ordinal = targetChildren.filter { $0.name == child.name }.firstIndex { $0.id == child.id } ?? 0
                if matches.indices.contains(ordinal) {
                    let original = matches[ordinal]
                    if selected.contains(original.id) { result.insert(child.id) } else { result.remove(child.id) }
                    if child.group { copyChildren(original.id, child.id) }
                } else { result.remove(child.id) }
            }
        }
        for layer in layers where baseAndModes(layer.name).1.isEmpty {
            let variants = layers.filter { other in
                let pair = baseAndModes(other.name)
                return other.parent == layer.parent && pair.0 == layer.name && !pair.1.isEmpty
            }
            for variant in variants { result.remove(variant.id) }
            if !suffix.isEmpty, let variant = variants.first(where: { baseAndModes($0.name).1.contains(suffix) }) {
                result.remove(layer.id)
                if selected.contains(layer.id) { result.insert(variant.id) }
                if layer.group { copyChildren(layer.id, variant.id) }
            }
        }
        return result
    }
    func isVisible(_ id: Int, in selected: Set<Int>) -> Bool {
        var current = layers.first { $0.id == id }
        while let layer = current {
            if !selected.contains(layer.id) { return false }
            current = layer.parent.flatMap { parent in layers.first { $0.id == parent } }
        }
        return true
    }
    func path(for id: Int) -> String {
        guard let layer = layers.first(where: { $0.id == id }) else { return "" }
        let siblings = layers.filter { $0.parent == layer.parent && $0.name == layer.name }.reversed()
        let ordinal = Array(siblings).firstIndex { $0.id == id } ?? 0
        let segment = PFV.encode(layer.name) + (ordinal > 0 ? "\\\(ordinal)" : "")
        return layer.parent.map { path(for: $0) + "/" + segment } ?? segment
    }
    func resolve(_ path: String) -> Int? {
        var parent: Int?
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            let parts = segment.split(separator: "\\", omittingEmptySubsequences: false)
            guard parts.count <= 2, let name = String(parts[0]).removingPercentEncoding else { return nil }
            let ordinal = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
            let siblings = Array(layers.filter { $0.parent == parent && $0.name == name }.reversed())
            guard siblings.indices.contains(ordinal) else { return nil }
            parent = siblings[ordinal].id
        }
        return parent
    }
    func depth(_ layer: PSDLayer) -> Int {
        var result = 0, parent = layer.parent
        while let id = parent {
            result += 1; parent = layers.first { $0.id == id }?.parent
        }
        return result
    }
    func applying(_ favorite: PSDFavorite, to selected: [Int]) throws -> [Int] {
        let selectedIDs = try favorite.paths.map { path -> Int in
            guard let id = resolve(path) else { throw VMMError.message("PFVのレイヤーがPSDに見つかりません：\(path)") }
            return id
        }
        let filters = try favorite.filters.map { paths in
            try paths.map { path -> Int in
                guard let id = resolve(path) else { throw VMMError.message("PFVのフィルターがPSDに見つかりません：\(path)") }
                return id
            }
        }
        func inside(_ id: Int, _ roots: [Int]) -> Bool {
            var current: Int? = id
            while let node = current {
                if roots.contains(node) { return true }
                current = layers.first { $0.id == node }?.parent
            }
            return false
        }
        var targets = Set(selectedIDs)
        for id in selectedIDs {
            var parent = layers.first { $0.id == id }?.parent
            while let node = parent { targets.insert(node); parent = layers.first { $0.id == node }?.parent }
        }
        var result = Set(selected)
        for layer in layers where filters.allSatisfy({ inside(layer.id, $0) }) {
            if targets.contains(layer.id) { result.insert(layer.id) } else { result.remove(layer.id) }
        }
        return normalized(result).sorted()
    }
}

struct PSDSelectionKeyframe:Codable,Equatable,Identifiable {
    var id=UUID()
    var time:Double
    var name:String
    var selected:[Int]
}

struct PSDState: Codable, Equatable {
    var selected: [Int]
    var selectionKeys:[PSDSelectionKeyframe]?
    var mouthClosed: Int?
    var mouthOpen: Int?
    var mouthAnimation = false
    var vowelAnimation:Bool?
    var vowelLayers:[String:Int]?
    var eyeClosed: Int?
    var blink = false
    var blinkInterval: Double = 3
    var flipX = false
    var flipY = false
    var favorites: [PSDFavorite] = []
    static func initial(_ document: PSDDocument) -> PSDState {
        var state = PSDState(selected: document.defaults)
        state.favorites = document.favorites
        let mouth = document.layers.first { $0.group && $0.label == "口" && document.isVisible($0.id, in: Set(document.defaults)) }
        if let mouth {
            state.mouthClosed = document.layers.first { $0.parent == mouth.id && ["むふ", "ん", "閉じ", "閉じ口"].contains($0.label) }?.id
            state.mouthOpen = document.layers.first { $0.parent == mouth.id && ["ほあ", "あ", "開き", "開き口"].contains($0.label) }?.id
        }
        state.eyeClosed = document.layers.first { layer in
            !layer.group && layer.label == "閉じ目" && layer.parent.map { document.isVisible($0, in: Set(document.defaults)) } == true
        }?.id
        return state
    }
    func selection(at time:Double)->[Int] {
        selectionKeys?.filter{$0.time<=time}.max(by:{$0.time<$1.time})?.selected ?? selected
    }
    func visibility(document: PSDDocument, speaking: Bool, time: Double, selectionTime:Double? = nil, mouthCue:ProjectMouthCue? = nil) -> Set<Int> {
        var result = selection(at:selectionTime ?? time)
        if mouthAnimation {
            var id = speaking ? mouthOpen : mouthClosed
            if vowelAnimation == true,let cue=mouthCue {
                if let vowel=cue.vowel {id=vowelLayers?[vowel.rawValue] ?? id}
                else {id=mouthClosed}
            }
            if let id {result = document.selecting(id, enabled:true,in:result)}
        }
        let phase = max(0, time).truncatingRemainder(dividingBy: max(0.5, blinkInterval))
        if blink, phase >= max(0.5, blinkInterval) - 0.14, let id = eyeClosed {
            result = document.selecting(id, enabled: true, in: result)
        }
        return document.flippedVisibility(document.normalized(Set(result)), x: flipX, y: flipY)
    }
}

struct PSDFavorite: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var paths: [String]
    var filters: [[String]] = []
}

enum PFV {
    static func encode(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let n = scalar.value
            return n < 32 || [34, 37, 39, 47, 92, 126, 127].contains(n) ? String(format: "%%%02x", n) : String(scalar)
        }.joined()
    }
    static func read(_ text: String) throws -> [PSDFavorite] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).components(separatedBy: "\n")
        guard lines.first == "[PSDToolFavorites-v1]" else { throw VMMError.message("PSDToolFavorites-v1形式のPFVではありません。") }
        var records: [(path: String, kind: String, layers: [String])] = []
        for line in lines.dropFirst() {
            if line.hasPrefix("//") {
                let parts = String(line.dropFirst(2)).components(separatedBy: "~")
                records.append((parts[0], parts.count > 1 ? parts[1] : "", []))
            } else if !line.isEmpty && !records.isEmpty { records[records.count - 1].layers.append(line) }
        }
        return records.filter { $0.kind.isEmpty }.map { record in
            let filters = records.filter { $0.kind == "filter" && record.path.hasPrefix($0.path + "/") }.map(\.layers)
            let name = record.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }.joined(separator: " / ")
            return PSDFavorite(name: name, paths: record.layers, filters: filters)
        }
    }
    static func write(_ favorites: [PSDFavorite]) -> String {
        var output = "[PSDToolFavorites-v1]\nroot-name/VMM\n"
        for (index, favorite) in favorites.enumerated() {
            // Preserve filter intersections in nested folders, without flattening their semantics.
            var prefix = ""
            for (depth, paths) in favorite.filters.enumerated() {
                prefix += "filter-\(index)-\(depth)/"
                output += "\n//\(prefix.dropLast())~filter\n" + paths.joined(separator: "\n") + "\n"
            }
            output += "\n//\(prefix)\(encode(favorite.name))\n" + favorite.paths.joined(separator: "\n") + "\n"
        }
        return output
    }
}
