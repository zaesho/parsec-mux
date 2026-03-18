/// Log — Simple file logger since GUI apps can't reliably write to stdout.

import Foundation

enum Log {
    private static let logPath = NSHomeDirectory() + "/.parsec-mux/viewer.log"
    private static var handle: FileHandle? = {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        return FileHandle(forWritingAtPath: logPath)
    }()

    static func write(_ msg: String) {
        let line = msg + "\n"
        handle?.write(line.data(using: .utf8) ?? Data())
        Swift.print(msg)
    }
}

func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let msg = items.map { "\($0)" }.joined(separator: separator)
    Log.write(msg)
}
