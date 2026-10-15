import Foundation

let usage = """
usage: macpulse [--port N] [--interval SECONDS] [--no-open]
       macpulse --snapshot FILE

  --port N          port for the local dashboard (default 8765, bound to 127.0.0.1)
  --interval S      seconds between samples (default 2.5)
  --no-open         do not open a browser tab
  --snapshot FILE   write one self-contained HTML file of the current state and exit

Processes owned by root or other users can only be measured when run with sudo.
"""

setvbuf(stdout, nil, _IOLBF, 0)

var port: UInt16 = 8765
var interval = 2.5
var openBrowser = true
var snapshotPath: String?

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--port": port = args.next().flatMap(UInt16.init) ?? port
    case "--interval": interval = args.next().flatMap(Double.init).map { max($0, 0.5) } ?? interval
    case "--no-open": openBrowser = false
    case "--snapshot": snapshotPath = args.next()
    case "-h", "--help": print(usage); exit(0)
    default: FileHandle.standardError.write(Data("unknown option \(arg)\n\n\(usage)\n".utf8)); exit(2)
    }
}

guard let pageURL = Bundle.module.url(forResource: "dashboard", withExtension: "html"),
      let page = try? Data(contentsOf: pageURL) else {
    FileHandle.standardError.write(Data("macpulse: dashboard.html is missing from the resource bundle\n".utf8))
    exit(1)
}

let sampler = Sampler()

if let snapshotPath {
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.5)
    var payload = sampler.sample()
    payload.live = false
    payload.history = []
    let json = String(decoding: sampler.encode(payload), as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    let html = String(decoding: page, as: UTF8.self).replacingOccurrences(of: "/*__MACPULSE_DATA__*/null", with: json)
    do {
        try html.write(toFile: snapshotPath, atomically: true, encoding: .utf8)
        print("Wrote \(snapshotPath)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("macpulse: cannot write \(snapshotPath): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let latestLock = NSLock()
var latest = Data("{}".utf8)
let sampleQueue = DispatchQueue(label: "macpulse.sample", qos: .utility)

func publish() {
    let data = sampler.encode(sampler.sample())
    latestLock.lock()
    latest = data
    latestLock.unlock()
}

_ = sampler.sample()
Thread.sleep(forTimeInterval: 1)
publish()

let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
timer.setEventHandler(handler: publish)
timer.resume()

let server: Server
do {
    server = try Server(port: port, page: page) {
        latestLock.lock()
        defer { latestLock.unlock() }
        return latest
    }
} catch {
    FileHandle.standardError.write(Data("macpulse: \(error)\n".utf8))
    exit(1)
}

server.start {
    let url = "http://127.0.0.1:\(port)/"
    print("Mac Pulse live at \(url)  (Ctrl+C to stop)")
    if openBrowser {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url]
        try? open.run()
    }
}

dispatchMain()
