// Opens a URL in WebKit (WKWebView: the engine of the installed Safari) without showing anything
// or taking focus, for the cross-browser checks. The page reports its results over HTTP (?report=1),
// because a WKWebView's console cannot be read from outside.
// Build: swiftc -O tools/webkit_run.swift -o <somewhere>/webkit_run
// Run:   webkit_run <url> <seconds> [snapshot.png <at seconds> [script.js <at seconds>]]
import Cocoa
import WebKit

let args = CommandLine.arguments
guard args.count >= 3, let url = URL(string: args[1]), let timeout = Double(args[2]) else {
  FileHandle.standardError.write("usage: webkit_run <url> <seconds> [snapshot.png <at>]\n".data(using: .utf8)!)
  exit(2)
}
let shotPath = args.count > 3 ? args[3] : ""
let shotAt = args.count > 4 ? Double(args[4]) ?? 0 : 0

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)          // no Dock icon, never becomes the active app

let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()    // nothing is saved; nothing of Safari's is read
config.mediaTypesRequiringUserActionForPlayback = []
let frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
let web = WKWebView(frame: frame, configuration: config)
// keep rendering while the window is covered (WebKit SPI; ignored if it does not exist)
if web.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
  web.setValue(false, forKey: "windowOcclusionDetectionEnabled")
}
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
window.alphaValue = 0.0                       // invisible
window.ignoresMouseEvents = true
window.setFrameOrigin(NSPoint(x: 0, y: 0))
window.orderBack(nil)
web.load(URLRequest(url: url))
print("webkit: loading \(url.absoluteString.prefix(80))")

if !shotPath.isEmpty {
  DispatchQueue.main.asyncAfter(deadline: .now() + shotAt) {
    let cfg = WKSnapshotConfiguration()
    web.takeSnapshot(with: cfg) { image, error in
      if let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: shotPath))
        print("webkit: snapshot \(shotPath)")
      } else {
        print("webkit: snapshot failed \(String(describing: error))")
      }
    }
  }
}
// optional: a JavaScript file to run in the page at a given time (synthetic events for tests)
if args.count > 6, let js = try? String(contentsOfFile: args[5], encoding: .utf8), let at = Double(args[6]) {
  DispatchQueue.main.asyncAfter(deadline: .now() + at) {
    web.evaluateJavaScript(js) { _, error in
      if let error = error { print("webkit: js error \(error.localizedDescription)") } else { print("webkit: js ran") }
    }
  }
}
DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { exit(0) }
app.run()
