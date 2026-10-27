import AppKit
import ApplicationServices

extension AXUIElement {
    func attr(_ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }
    var role: String { attr("AXRole") as? String ?? "" }
    var ident: String { attr("AXIdentifier") as? String ?? "" }
    var label: String {
        for a in ["AXTitle", "AXDescription", "AXValue"] {
            if let s = attr(a) as? String, !s.isEmpty { return s }
        }
        return ""
    }
    var kids: [AXUIElement] { attr("AXChildren") as? [AXUIElement] ?? [] }
    @discardableResult func press() -> Bool { AXUIElementPerformAction(self, kAXPressAction as CFString) == .success }
    @discardableResult func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }
    func find(depth: Int = 30, where p: (AXUIElement) -> Bool) -> AXUIElement? {
        if p(self) { return self }
        if depth == 0 { return nil }
        for c in kids { if let r = c.find(depth: depth - 1, where: p) { return r } }
        return nil
    }
}
