import AppKit
import Carbon.HIToolbox
import WebKit

/// chrome.debugger for the extensions that drive pages (Claude, to see and act on the page it is
/// asked about): the few Chrome DevTools Protocol commands they send, done on the tab's web view.
/// Only an extension that asked for the "debugger" permission, only in normal windows. The tab is
/// brought to the front first: the user sees what is done, and a page out of sight can't be drawn.
///
/// The pointer and the keyboard go to the web view as real events, the way they would come from
/// the Mac: a page can't tell them from the user's. A wheel is a scroll of the element under it.
@available(macOS 15.4, *)
@MainActor
enum ExtensionDebugger {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handle(_ body: [String: Any], from context: WKWebExtensionContext) async -> Any {
        guard (context.webExtension.manifest["permissions"] as? [String])?.contains("debugger") == true else {
            return ["error": "Missing \"debugger\" permission."]
        }
        let target = (body["attach"] ?? body["target"]) as? [String: Any] ?? [:]
        guard let tab = tab(for: target) else {
            return ["error": "No tab with given id \(target["tabId"].map { "\($0)" } ?? "")."]
        }
        if body["attach"] != nil { return [:] }
        guard let method = body["command"] as? String else { return [:] }
        do {
            return ["result": try await run(method, body["params"] as? [String: Any] ?? [:], on: tab)]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - Which tab

    /// The tab WebKit calls `tabId`, from what the extension was told of it: its place in its
    /// window, its address and its window's frame (WebKit's identifiers aren't Nuri's).
    static func tab(for target: [String: Any]) -> Tab? {
        let address = target["url"] as? String ?? ""
        let index = number(target["index"])
        let frame = target["frame"] as? [String: Any]
        let windows = BrowserWindows.shared.all.filter { !$0.isPrivate && $0.window != nil }
        let shows = { (tab: Tab) in address.isEmpty || tab.url?.absoluteString == address }
        for browser in windows where sameFrame(browser, frame) {
            let tabs = browser.allTabs
            if let index, tabs.indices.contains(index), shows(tabs[index]) { return tabs[index] }
        }
        let showing = windows.flatMap(\.allTabs).filter { !address.isEmpty && $0.url?.absoluteString == address }
        return showing.count == 1 ? showing[0] : nil
    }

    private static func sameFrame(_ browser: BrowserModel, _ frame: [String: Any]?) -> Bool {
        guard let frame, let window = browser.window else { return true }
        let height = NSScreen.screens.first?.frame.height ?? 0
        let own = window.frame
        let expected = [own.minX, height - own.maxY, own.width, own.height]
        let given = ["left", "top", "width", "height"].map { decimal(frame[$0]) }
        return zip(expected, given).allSatisfy { pair in pair.1.map { abs($0 - pair.0) <= 2 } ?? true }
    }

    /// The tab on screen, with its page drawn.
    private static func shown(_ tab: Tab) async throws -> WKWebView {
        guard let browser = tab.browser else { throw Failure(message: "No tab with given id.") }
        if !browser.visibleTabs.contains(where: { $0 === tab }) {
            browser.select(tab)
            browser.window?.orderFront(nil)
        }
        _ = tab.ensureWebView()
        for _ in 0..<40 where tab.webView?.window == nil || tab.webView?.bounds.isEmpty == true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let webView = tab.webView, webView.window != nil else { throw Failure(message: "The page isn't shown.") }
        return webView
    }

    // MARK: - Commands

    private static func run(_ method: String, _ params: [String: Any], on tab: Tab) async throws -> [String: Any] {
        switch method {
        case "Page.captureScreenshot": return try await screenshot(params, on: tab)
        case "Input.dispatchMouseEvent": try await mouse(params, on: tab)
        case "Input.dispatchKeyEvent": try await key(params, on: tab)
        case "Input.insertText":
            let webView = try await shown(tab)
            webView.window?.makeFirstResponder(webView)
            webView.insertText(params["text"] as? String ?? "")
        case "Runtime.evaluate": return try await evaluate(params, on: tab)
        case "Page.getFrameTree": return frameTree(of: tab)
        case "Page.navigate":
            guard let address = params["url"] as? String, let url = URL(string: address) else { throw Failure(message: "Invalid URL.") }
            tab.load(url)
            return ["frameId": "main", "loaderId": loader(of: tab)]
        case "Page.reload": tab.webView?.reload()
        case "Page.handleJavaScriptDialog", "Input.cancelDragging", "Page.bringToFront": break
        default:
            let quiet = method.hasSuffix(".enable") || method.hasSuffix(".disable") || method.hasPrefix("Emulation.")
                || method.hasPrefix("Network.") || method.hasPrefix("Log.")
            guard quiet else { throw Failure(message: "'\(method)' wasn't found") }
        }
        return [:]
    }

    private static func loader(of tab: Tab) -> String {
        tab.webView?.backForwardList.currentItem.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 36) } ?? "0"
    }

    private static func frameTree(of tab: Tab) -> [String: Any] {
        let address = tab.webView?.url?.absoluteString ?? tab.url?.absoluteString ?? ""
        let origin = URL(string: address).flatMap { url in url.host().map { "\(url.scheme ?? "https")://\($0)\(url.port.map { ":\($0)" } ?? "")" } } ?? ""
        return ["frameTree": ["frame": ["id": "main", "loaderId": loader(of: tab), "url": address, "securityOrigin": origin,
                                        "domainAndRegistry": "", "mimeType": "text/html", "secureContextType": "Secure",
                                        "crossOriginIsolatedContextType": "NotIsolated", "gatedAPIFeatures": [String]()],
                              "childFrames": [[String: Any]]()]]
    }

    // MARK: Screenshot

    /// The visible page, in the screen's pixels (CSS pixels × devicePixelRatio, as Chrome's).
    private static func screenshot(_ params: [String: Any], on tab: Tab) async throws -> [String: Any] {
        let webView = try await shown(tab)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let zoom = webView.pageZoom * webView.magnification
        if let clip = params["clip"] as? [String: Any], let x = decimal(clip["x"]), let y = decimal(clip["y"]),
           let width = decimal(clip["width"]), let height = decimal(clip["height"]) {
            // Chrome's clip is in the document's coordinates.
            let scroll = await webView.nuriCall("return [window.scrollX, window.scrollY];", world: .page, timeout: 2) as? [Double] ?? [0, 0]
            configuration.rect = CGRect(x: (x - scroll[0]) * zoom, y: (y - scroll[1]) * zoom, width: width * zoom, height: height * zoom)
        }
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) } else {
                    continuation.resume(throwing: error ?? Failure(message: "Unable to capture screenshot"))
                }
            }
        }
        guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure(message: "Unable to capture screenshot") }
        let bitmap = NSBitmapImageRep(cgImage: picture)
        let format = params["format"] as? String ?? "png"
        let data: Data?
        if format == "jpeg" || format == "webp" {
            let quality = min(100, max(0, decimal(params["quality"]) ?? 80)) / 100
            data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        } else {
            data = bitmap.representation(using: .png, properties: [:])
        }
        guard let data else { throw Failure(message: "Unable to capture screenshot") }
        return ["data": data.base64EncodedString()]
    }

    // MARK: Pointer

    /// Chrome's mouse event at (x, y) in the page's CSS pixels, as an event of the Mac's. A wheel
    /// scrolls what is under it; a right click opens no menu (it would hold everything until
    /// closed), the page gets its contextmenu event.
    private static func mouse(_ params: [String: Any], on tab: Tab) async throws {
        let webView = try await shown(tab)
        guard let window = webView.window else { return }
        let x = decimal(params["x"]) ?? 0, y = decimal(params["y"]) ?? 0
        let type = params["type"] as? String ?? ""
        let button = params["button"] as? String ?? "none"
        if type == "mouseWheel" {
            return await scroll(webView, x: x, y: y, dx: decimal(params["deltaX"]) ?? 0, dy: decimal(params["deltaY"]) ?? 0)
        }
        if button == "right" {
            if type == "mousePressed" {
                _ = await webView.nuriCall("""
                    const target = document.elementFromPoint(x, y) || document.body;
                    target.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2 }));
                    """, arguments: ["x": x, "y": y], world: .page, timeout: 2)
            }
            return
        }
        let zoom = webView.pageZoom * webView.magnification
        let local = NSPoint(x: x * zoom, y: webView.isFlipped ? y * zoom : webView.bounds.height - y * zoom)
        let location = webView.convert(local, to: nil)
        let flags = modifierFlags(params["modifiers"])
        let clicks = max(1, number(params["clickCount"]) ?? 1)
        let pressed = (number(params["buttons"]) ?? 0) & 1 != 0
        let kind: NSEvent.EventType
        switch (type, button) {
        case ("mousePressed", "middle"): kind = .otherMouseDown
        case ("mousePressed", _): kind = .leftMouseDown
        case ("mouseReleased", "middle"): kind = .otherMouseUp
        case ("mouseReleased", _): kind = .leftMouseUp
        default: kind = pressed ? .leftMouseDragged : .mouseMoved
        }
        guard let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                             pressure: kind == .leftMouseDown ? 1 : 0) else { return }
        switch kind {
        case .leftMouseDown, .otherMouseDown:
            // As a real click would: the page has the keyboard afterwards.
            if window.firstResponder !== webView { window.makeFirstResponder(webView) }
            kind == .leftMouseDown ? webView.mouseDown(with: event) : webView.otherMouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        default: webView.mouseMoved(with: event)
        }
    }

    private static func scroll(_ webView: WKWebView, x: Double, y: Double, dx: Double, dy: Double) async {
        _ = await webView.nuriCall("""
            const scrolls = (element) => {
              const style = getComputedStyle(element);
              const can = (overflow, size, client) => /(auto|scroll|overlay)/.test(overflow) && size > client;
              return (dy && can(style.overflowY, element.scrollHeight, element.clientHeight)) || (dx && can(style.overflowX, element.scrollWidth, element.clientWidth));
            };
            let element = document.elementFromPoint(x, y);
            if (element) element.dispatchEvent(new WheelEvent("wheel", { bubbles: true, cancelable: true, clientX: x, clientY: y, deltaX: dx, deltaY: dy, deltaMode: 0 }));
            while (element && element !== document.body && element !== document.documentElement && !scrolls(element)) element = element.parentElement;
            const scroller = element && element !== document.body && element !== document.documentElement ? element : (document.scrollingElement || document.documentElement);
            scroller.scrollBy({ left: dx, top: dy, behavior: "instant" });
            """, arguments: ["x": x, "y": y, "dx": dx, "dy": dy], world: .page, timeout: 2)
    }

    // MARK: Keyboard

    /// A key as the Mac's keyboard would send it, to the page made first responder. Editing
    /// commands Chrome sends with a shortcut (⌘A: selectAll) go to the page as the menu would.
    private static func key(_ params: [String: Any], on tab: Tab) async throws {
        let webView = try await shown(tab)
        guard let window = webView.window else { return }
        if window.firstResponder !== webView { window.makeFirstResponder(webView) }
        let type = params["type"] as? String ?? "keyDown"
        let commands = params["commands"] as? [String] ?? []
        if type != "keyUp", !commands.isEmpty {
            for command in commands { NSApp.sendAction(Selector(command + ":"), to: webView, from: nil) }
            return
        }
        let name = params["key"] as? String ?? ""
        let code = params["code"] as? String ?? ""
        var flags = modifierFlags(params["modifiers"])
        let (keyCode, special) = Self.keyCode(code: code, key: name)
        var text = params["text"] as? String ?? ""
        if text.isEmpty { text = special ?? (name.count == 1 ? name : "") }
        if type == "char" { return webView.insertText(text) }
        if special != nil, special!.unicodeScalars.first.map({ $0.value >= 0xF700 }) == true { flags.insert(.function) }
        let unmodified = (params["unmodifiedText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.lowercased()
        guard let event = NSEvent.keyEvent(with: type == "keyUp" ? .keyUp : .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                           characters: text, charactersIgnoringModifiers: unmodified, isARepeat: params["autoRepeat"] as? Bool ?? false,
                                           keyCode: keyCode) else { return }
        if type == "keyUp" { webView.keyUp(with: event) } else { webView.keyDown(with: event) }
    }

    /// The Mac's key code for Chrome's `code` (or `key`), and the character AppKit gives the keys
    /// that type none.
    private static func keyCode(code: String, key: String) -> (UInt16, String?) {
        let function = { (value: Int) in String(Character(UnicodeScalar(UInt32(value))!)) }
        let named: [String: (Int, String?)] = [
            "Enter": (kVK_Return, "\r"), "NumpadEnter": (kVK_ANSI_KeypadEnter, "\u{3}"), "Tab": (kVK_Tab, "\t"),
            "Backspace": (kVK_Delete, "\u{7F}"), "Delete": (kVK_ForwardDelete, function(NSDeleteFunctionKey)),
            "Escape": (kVK_Escape, "\u{1B}"), "Space": (kVK_Space, " "), " ": (kVK_Space, " "),
            "ArrowUp": (kVK_UpArrow, function(NSUpArrowFunctionKey)), "ArrowDown": (kVK_DownArrow, function(NSDownArrowFunctionKey)),
            "ArrowLeft": (kVK_LeftArrow, function(NSLeftArrowFunctionKey)), "ArrowRight": (kVK_RightArrow, function(NSRightArrowFunctionKey)),
            "Home": (kVK_Home, function(NSHomeFunctionKey)), "End": (kVK_End, function(NSEndFunctionKey)),
            "PageUp": (kVK_PageUp, function(NSPageUpFunctionKey)), "PageDown": (kVK_PageDown, function(NSPageDownFunctionKey)),
            "F1": (kVK_F1, function(NSF1FunctionKey)), "F2": (kVK_F2, function(NSF2FunctionKey)), "F3": (kVK_F3, function(NSF3FunctionKey)),
            "F4": (kVK_F4, function(NSF4FunctionKey)), "F5": (kVK_F5, function(NSF5FunctionKey)), "F6": (kVK_F6, function(NSF6FunctionKey)),
            "F7": (kVK_F7, function(NSF7FunctionKey)), "F8": (kVK_F8, function(NSF8FunctionKey)), "F9": (kVK_F9, function(NSF9FunctionKey)),
            "F10": (kVK_F10, function(NSF10FunctionKey)), "F11": (kVK_F11, function(NSF11FunctionKey)), "F12": (kVK_F12, function(NSF12FunctionKey)),
            "ShiftLeft": (kVK_Shift, ""), "ShiftRight": (kVK_RightShift, ""), "ControlLeft": (kVK_Control, ""), "ControlRight": (kVK_RightControl, ""),
            "AltLeft": (kVK_Option, ""), "AltRight": (kVK_RightOption, ""), "MetaLeft": (kVK_Command, ""), "MetaRight": (kVK_RightCommand, ""),
        ]
        if let found = named[code] ?? named[key] { return (UInt16(found.0), found.1) }
        let letters: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
            "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
        ]
        var character: Character?
        if code.hasPrefix("Key"), code.count == 4 { character = code.last.map { Character($0.lowercased()) } }
        else if code.hasPrefix("Digit"), code.count == 6 { character = code.last }
        else if key.count == 1 { character = Character(key.lowercased()) }
        return (UInt16(character.flatMap { letters[$0] } ?? 0), nil)
    }

    /// Chrome's bits: 1 Alt, 2 Control, 4 Meta (⌘), 8 Shift.
    private static func modifierFlags(_ value: Any?) -> NSEvent.ModifierFlags {
        let bits = number(value) ?? 0
        var flags: NSEvent.ModifierFlags = []
        if bits & 1 != 0 { flags.insert(.option) }
        if bits & 2 != 0 { flags.insert(.control) }
        if bits & 4 != 0 { flags.insert(.command) }
        if bits & 8 != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: Script

    /// Runtime.evaluate in the page's own world, its value returned as Chrome would. Tried as an
    /// expression first (its promise awaited), then as statements: `return` and `await` as in a
    /// function's body, else the last statement's value. Never through the page's eval, which its
    /// Content-Security-Policy may forbid. A SyntaxError means nothing ran: the next form is tried.
    private static func evaluate(_ params: [String: Any], on tab: Tab) async throws -> [String: Any] {
        var page: WKWebView? = tab.webView
        if page == nil { page = try await shown(tab) }
        guard let webView = page else { throw Failure(message: "The page isn't shown.") }
        var source = (params["expression"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude wraps its code in a block: its insides are the code.
        if source.hasPrefix("{"), source.hasSuffix("}") { source = String(source.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        let timeout = (decimal(params["timeout"]) ?? 30_000) / 1000
        var outcome = await call(webView, "return (\n\(source)\n);", timeout: timeout)
        if case .failure(let error) = outcome, error.isSyntax {
            if source.range(of: #"\b(return|await)\b"#, options: .regularExpression) != nil {
                outcome = await call(webView, source, timeout: timeout)
            } else {
                outcome = await evaluateScript(webView, source)
            }
        }
        switch outcome {
        case .success(let value): return ["result": remoteObject(value)]
        case .failure(let error):
            if error.unsupported {
                return ["result": ["type": "object", "description": "Object (its value can't be sent back)"]]
            }
            return ["result": ["type": "object", "subtype": "error", "className": error.className, "description": error.text],
                    "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0,
                                         "exception": ["type": "object", "subtype": "error", "className": error.className, "description": error.text]]]
        }
    }

    private struct ScriptError: Error {
        let className: String
        let text: String
        var unsupported = false
        var isSyntax: Bool { className == "SyntaxError" }

        init(_ error: Error?) {
            let ns = error as NSError?
            if ns?.domain == WKError.errorDomain, ns?.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                unsupported = true
            }
            let message = ns?.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ns?.localizedDescription ?? "Error"
            text = message
            if let colon = message.firstIndex(of: ":"), message[..<colon].hasSuffix("Error"), !message[..<colon].contains(" ") {
                className = String(message[..<colon])
            } else {
                className = "Error"
            }
        }

        init(timeout: Double) {
            className = "Error"
            text = "Error: evaluation timed out after \(Int(timeout * 1000))ms"
        }
    }

    private static func call(_ webView: WKWebView, _ body: String, timeout: Double) async -> Result<Any?, ScriptError> {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish = { (value: Result<Any?, ScriptError>) in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): finish(.success(value))
                case .failure(let error): finish(.failure(ScriptError(error)))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, timeout)) { finish(.failure(ScriptError(timeout: timeout))) }
        }
    }

    private static func evaluateScript(_ webView: WKWebView, _ source: String) async -> Result<Any?, ScriptError> {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(source, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: .success(value))
                case .failure(let error): continuation.resume(returning: .failure(ScriptError(error)))
                }
            }
        }
    }

    /// Chrome's RemoteObject for a value WebKit gives back.
    private static func remoteObject(_ value: Any?) -> [String: Any] {
        switch value {
        case nil: return ["type": "undefined"]
        case is NSNull: return ["type": "object", "subtype": "null", "value": NSNull()]
        case let text as String: return ["type": "string", "value": text]
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return ["type": "boolean", "value": number.boolValue] }
            return ["type": "number", "value": number, "description": number.stringValue]
        case let list as [Any]: return ["type": "object", "subtype": "array", "value": list, "description": "Array(\(list.count))"]
        case let object as [String: Any]: return ["type": "object", "value": object, "description": "Object"]
        case let date as Date: return ["type": "object", "subtype": "date", "description": date.description]
        default: return ["type": "object", "description": String(describing: value!)]
        }
    }

    // MARK: -

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        return (value as? NSNumber)?.intValue
    }

    private static func decimal(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return (value as? NSNumber)?.doubleValue
    }
}
