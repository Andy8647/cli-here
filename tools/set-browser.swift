// Reset the system default browser and the http/https handlers.
// Usage: swift set-browser.swift <bundle-id>
import Foundation
import CoreServices

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: swift set-browser.swift <bundle-id>\n".data(using: .utf8)!)
    exit(2)
}
let bundle = args[1] as CFString

for scheme in ["http", "https"] {
    let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundle)
    print("\(scheme) -> \(status == noErr ? "ok" : "error \(status)")")
}

let htmlStatus = LSSetDefaultRoleHandlerForContentType(
    "public.html" as CFString,
    LSRolesMask.all,
    bundle
)
print("public.html -> \(htmlStatus == noErr ? "ok" : "error \(htmlStatus)")")
