import Cocoa
import ApplicationServices

// MARK: - Accessibility helpers

func findDjayPID() -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "com.algoriddim.djay-iphone-free" })?
        .processIdentifier
}

func getChildren(_ element: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
          let children = ref as? [AXUIElement] else { return [] }
    return children
}

func getAttribute(_ element: AXUIElement, _ attr: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
    if let str = ref as? String { return str }
    if let num = ref as? NSNumber { return num.stringValue }
    return nil
}

func getValue(_ el: AXUIElement) -> String? { getAttribute(el, kAXValueAttribute) }
func getDescription(_ el: AXUIElement) -> String? { getAttribute(el, kAXDescriptionAttribute) }
func getRole(_ el: AXUIElement) -> String? { getAttribute(el, kAXRoleAttribute) }
func getIdentifier(_ el: AXUIElement) -> String? { getAttribute(el, "AXIdentifier") }
func getLabel(_ el: AXUIElement) -> String? { getAttribute(el, "AXLabel") }
func getTitle(_ el: AXUIElement) -> String? { getAttribute(el, kAXTitleAttribute) }

func getPosition(_ element: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
          let axVal = ref else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(axVal as! AXValue, .cgPoint, &point)
    return point
}

func getSize(_ element: AXUIElement) -> CGSize? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
          let axVal = ref else { return nil }
    var size = CGSize.zero
    AXValueGetValue(axVal as! AXValue, .cgSize, &size)
    return size
}

// MARK: - Watched element: a cached AXUIElement ref + its description label

struct WatchedElement {
    let ref: AXUIElement
    let descriptionLabel: String // e.g. "Title", "Gain", or "_bpm:98.4"
    let deck: Int // 1 or 2
}

/// Labels we want to find and cache element refs for
let wantedLabels: Set<String> = [
    "Title", "Artist", "Remaining time", "Key",
    "Gain", "Line volume", "High EQ", "Mid EQ", "Low EQ", "Filter", "Tempo"
]

/// Walk the tree once and collect refs to elements we care about.
/// For BPM/tempo-offset (where the label IS the value), we tag them specially.
func discoverElements(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 12) -> [WatchedElement] {
    if depth > maxDepth { return [] }
    var results: [WatchedElement] = []

    let desc = getDescription(element) ?? ""

    if !desc.isEmpty {
        let isDeck1 = desc.hasSuffix(", Deck 1")
        let isDeck2 = desc.hasSuffix(", Deck 2")

        if isDeck1 || isDeck2 {
            let deck = isDeck1 ? 1 : 2
            let label = String(desc.dropLast(8)) // strip ", Deck N"

            // Only take visible elements (non-zero size)
            let size = getSize(element) ?? .zero
            let isVisible = size.width > 0 && size.height > 0

            if isVisible {
                if wantedLabels.contains(label) {
                    results.append(WatchedElement(ref: element, descriptionLabel: label, deck: deck))
                }
                // BPM: description is like "98.4, Deck 1"
                else if let bpm = Double(label), bpm >= 20, bpm <= 300 {
                    results.append(WatchedElement(ref: element, descriptionLabel: "_bpm", deck: deck))
                }
                // Tempo offset: description is like "0.0%, Deck 1"
                else if label.hasSuffix("%"), let pct = Double(label.dropLast(1)), abs(pct) < 100 {
                    results.append(WatchedElement(ref: element, descriptionLabel: "_tempoOffset", deck: deck))
                }
            }
        }
    }

    for child in getChildren(element) {
        results.append(contentsOf: discoverElements(child, depth: depth + 1, maxDepth: maxDepth))
    }
    return results
}

/// Deduplicate: keep only the first match per (label, deck) pair
func dedup(_ elements: [WatchedElement]) -> [WatchedElement] {
    var seen = Set<String>()
    return elements.filter { elem in
        let key = "\(elem.deck):\(elem.descriptionLabel)"
        if seen.contains(key) { return false }
        seen.insert(key)
        return true
    }
}

// MARK: - Deck state

struct DeckState {
    var trackName: String = "—"
    var artist: String = "—"
    var bpm: String = "—"
    var tempo: String = "—"
    var timeRemaining: String = "—"
    var key: String = "—"
    var gain: String = "—"
    var volume: String = "—"
    var highEQ: String = "—"
    var midEQ: String = "—"
    var lowEQ: String = "—"
    var filter: String = "—"
}

/// Fast poll: just read value + description from cached refs
func pollDeckStates(_ watched: [WatchedElement]) -> (DeckState, DeckState) {
    var deck1 = DeckState()
    var deck2 = DeckState()

    for elem in watched {
        let label = elem.descriptionLabel
        let deck = elem.deck

        // For BPM and tempo offset, the value is in the description itself (it changes!)
        if label == "_bpm" || label == "_tempoOffset" {
            let desc = getDescription(elem.ref) ?? ""
            guard desc.hasSuffix(", Deck \(deck)") else { continue }
            let val = String(desc.dropLast(8))

            if label == "_bpm" {
                if deck == 1 { deck1.bpm = val } else { deck2.bpm = val }
            } else {
                if deck == 1 { deck1.tempo = val } else { deck2.tempo = val }
            }
            continue
        }

        let val = getValue(elem.ref) ?? "—"

        switch label {
        case "Title":         if deck == 1 { deck1.trackName = val } else { deck2.trackName = val }
        case "Artist":        if deck == 1 { deck1.artist = val } else { deck2.artist = val }
        case "Remaining time":if deck == 1 { deck1.timeRemaining = val } else { deck2.timeRemaining = val }
        case "Key":           if deck == 1 { deck1.key = val } else { deck2.key = val }
        case "Gain":          if deck == 1 { deck1.gain = val } else { deck2.gain = val }
        case "Line volume":   if deck == 1 { deck1.volume = val } else { deck2.volume = val }
        case "High EQ":       if deck == 1 { deck1.highEQ = val } else { deck2.highEQ = val }
        case "Mid EQ":        if deck == 1 { deck1.midEQ = val } else { deck2.midEQ = val }
        case "Low EQ":        if deck == 1 { deck1.lowEQ = val } else { deck2.lowEQ = val }
        case "Filter":        if deck == 1 { deck1.filter = val } else { deck2.filter = val }
        case "Tempo":         if deck == 1 { deck1.tempo = val } else { deck2.tempo = val }
        default: break
        }
    }

    return (deck1, deck2)
}

// MARK: - Display

func clearScreen() {
    print("\u{1B}[2J\u{1B}[H", terminator: "")
}

let dim = "\u{1B}[2m"
let reset = "\u{1B}[0m"
let bold = "\u{1B}[1m"
let cyan = "\u{1B}[36m"
let yellow = "\u{1B}[33m"
let green = "\u{1B}[32m"

func pad(_ str: String, _ width: Int) -> String {
    if str.count >= width { return String(str.prefix(width)) }
    return str + String(repeating: " ", count: width - str.count)
}

func renderDeck(_ deck: DeckState, number: Int) -> String {
    let w = 44
    let bar = String(repeating: "─", count: w)
    let header = " Deck \(number) "

    return """
    \(dim)┌\(bar)┐\(reset)
    \(dim)│\(reset)\(bold)\(cyan)\(pad(header, w))\(reset)\(dim)│\(reset)
    \(dim)├\(bar)┤\(reset)
    \(dim)│\(reset) \(bold)Track:\(reset)  \(pad(deck.trackName, w - 9))\(dim)│\(reset)
    \(dim)│\(reset) \(bold)Artist:\(reset) \(pad(deck.artist, w - 9))\(dim)│\(reset)
    \(dim)├\(bar)┤\(reset)
    \(dim)│\(reset) BPM: \(yellow)\(pad(deck.bpm, 8))\(reset) Key: \(green)\(pad(deck.key, 4))\(reset) Time: \(pad(deck.timeRemaining, w - 31))\(dim)│\(reset)
    \(dim)│\(reset) Tempo: \(pad(deck.tempo, w - 8))\(dim)│\(reset)
    \(dim)├\(bar)┤\(reset)
    \(dim)│\(reset) Gain: \(pad(deck.gain, 6)) Vol: \(pad(deck.volume, 6)) Filter: \(pad(deck.filter, w - 29))\(dim)│\(reset)
    \(dim)│\(reset) EQ  H: \(pad(deck.highEQ, 5)) M: \(pad(deck.midEQ, 5)) L: \(pad(deck.lowEQ, w - 24))\(dim)│\(reset)
    \(dim)└\(bar)┘\(reset)
    """
}

// MARK: - Dump mode (full tree walk for debugging)

struct ElementInfo {
    let role: String
    let value: String
    let description: String
    let identifier: String
    let label: String
    let title: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

func collectElements(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 12) -> [ElementInfo] {
    if depth > maxDepth { return [] }
    var results: [ElementInfo] = []

    let desc = getDescription(element) ?? ""
    let value = getValue(element) ?? ""
    let label = getLabel(element) ?? ""
    let title = getTitle(element) ?? ""

    if !desc.isEmpty || !value.isEmpty || !label.isEmpty || !title.isEmpty {
        let role = getRole(element) ?? ""
        let ident = getIdentifier(element) ?? ""
        let pos = getPosition(element) ?? .zero
        let size = getSize(element) ?? .zero
        results.append(ElementInfo(
            role: role, value: value, description: desc,
            identifier: ident, label: label, title: title,
            x: pos.x, y: pos.y, width: size.width, height: size.height
        ))
    }

    for child in getChildren(element) {
        results.append(contentsOf: collectElements(child, depth: depth + 1, maxDepth: maxDepth))
    }
    return results
}

// MARK: - Main

let args = CommandLine.arguments
let dumpMode = args.contains("--dump")
let onceMode = args.contains("--once")

guard AXIsProcessTrusted() else {
    print("Accessibility permission required!")
    print("Go to: System Settings > Privacy & Security > Accessibility")
    print("Add your terminal app (Terminal.app, iTerm, etc.)")
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
    exit(1)
}

guard let pid = findDjayPID() else {
    print("djay Pro is not running.")
    exit(1)
}

let app = AXUIElementCreateApplication(pid)

func getWindow() -> AXUIElement? {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
    return (ref as? [AXUIElement])?.first
}

guard let window = getWindow() else {
    print("No djay Pro window found")
    exit(1)
}

if dumpMode {
    print("Scanning djay Pro accessibility tree (pid: \(pid))...")
    let elements = collectElements(window)
    print("Found \(elements.count) elements with content:\n")

    for (i, elem) in elements.enumerated() {
        let loc = String(format: "(%.0f, %.0f  %.0fx%.0f)", elem.x, elem.y, elem.width, elem.height)
        print("[\(i)] \(elem.role) \(loc)")
        if !elem.value.isEmpty { print("     value: \"\(elem.value)\"") }
        if !elem.description.isEmpty { print("     desc:  \"\(elem.description)\"") }
        if !elem.label.isEmpty { print("     label: \"\(elem.label)\"") }
        if !elem.title.isEmpty { print("     title: \"\(elem.title)\"") }
        if !elem.identifier.isEmpty { print("     id:    \"\(elem.identifier)\"") }
        print()
    }
    exit(0)
}

// Discover phase: walk tree once to find and cache element refs
print("Discovering djay Pro elements (pid: \(pid))...")
var watched = dedup(discoverElements(window))
print("Cached \(watched.count) elements. Starting live poll.\n")

let pollInterval: useconds_t = 100_000 // 0.1s

func renderState() {
    let (deck1, deck2) = pollDeckStates(watched)

    if !onceMode { clearScreen() }
    print("  \(bold)djay Pro \(dim)— Live State Monitor\(reset)")
    print("  \(dim)\(String(repeating: "═", count: 44))\(reset)")
    print()
    print(renderDeck(deck1, number: 1))
    print()
    print(renderDeck(deck2, number: 2))
    print()
    if !onceMode {
        print("  \(dim)\(watched.count) elements · polling every 100ms · Ctrl+C to quit\(reset)")
    }
    fflush(stdout)
}

if onceMode {
    renderState()
    exit(0)
}

while true {
    renderState()
    usleep(pollInterval)
}
