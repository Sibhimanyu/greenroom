// usage: post key=value ... (cmd=goto page=home dir=...)
import Foundation
var info: [String: String] = [:]
for a in CommandLine.arguments.dropFirst() {
    if let i = a.firstIndex(of: "=") { info[String(a[..<i])] = String(a[a.index(after: i)...]) }
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.greenroom.debug.tour"), object: nil, userInfo: info, deliverImmediately: true)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
