import Darwin
import Foundation

final class Sampler {
    private struct Previous {
        let time: Double
        let ticks: [[UInt32]]
        let disk: (read: UInt64, write: UInt64)
        let net: (rx: UInt64, tx: UInt64)
        let cpuSeconds: [Int32: Double]
    }

    let host = Machine.readHost()
    private var previous: Previous?
    private var history: [HistoryPoint] = []
    private var launches: [Int32: (path: String, launch: ProcessReader.Launch?)] = [:]
    private let encoder = JSONEncoder()

    func sample() -> Payload {
        let now = Date().timeIntervalSince1970
        var procs = ProcessReader.read()
        let ticks = Machine.coreTicks()
        let mem = Machine.readMemory()
        let disk = Machine.diskBytes()
        let net = Machine.netBytes()
        let space = Machine.diskSpace()
        let gpu = Machine.readGPU()
        let prev = previous
        let dt = prev.map { now - $0.time } ?? 0

        var cores: [Double] = []
        var total = [UInt64](repeating: 0, count: Int(CPU_STATE_MAX))
        for (i, cur) in ticks.enumerated() {
            let old = prev?.ticks[safe: i] ?? cur.map { _ in 0 }
            let d = zip(cur, old).map { UInt64($0 &- $1) }
            for s in d.indices { total[s] += d[s] }
            let span = max(d.reduce(0, +), 1)
            cores.append(round1(Double(d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]) / Double(span) * 100))
        }
        let span = Double(max(total.reduce(0, +), 1))
        let busy = Double(total[Int(CPU_STATE_USER)] + total[Int(CPU_STATE_SYSTEM)] + total[Int(CPU_STATE_NICE)]) / span
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let cpu = CPUInfo(
            total: round1(busy * 100),
            user: round1(Double(total[Int(CPU_STATE_USER)] + total[Int(CPU_STATE_NICE)]) / span * 100),
            sys: round1(Double(total[Int(CPU_STATE_SYSTEM)]) / span * 100),
            cores: cores, load: load.map { ($0 * 100).rounded() / 100 }, thermal: Machine.thermal()
        )

        var measuredCPU = 0.0
        for (pid, p) in procs {
            if let last = prev?.cpuSeconds[pid], dt > 0 {
                procs[pid]?.cpu = round1(max(p.cpuSeconds - last, 0) / dt * 100)
                measuredCPU += procs[pid]?.cpu ?? 0
            }
            if p.measured {
                if launches[pid]?.path != p.path { launches[pid] = (p.path, ProcessReader.launch(pid: pid)) }
                if let launch = launches[pid]?.launch {
                    if launch.exec.hasPrefix("/") { procs[pid]?.path = launch.exec }
                    procs[pid]?.script = launch.script
                    procs[pid]?.argv0 = launch.argv0
                }
            }
        }
        launches = launches.filter { procs[$0.key] != nil }
        let unmeasuredCPU = prev == nil ? 0 : max(busy * Double(ticks.count) * 100 - measuredCPU, 0)

        func rate(_ cur: UInt64, _ old: UInt64?) -> Double {
            guard let old, dt > 0, cur >= old else { return 0 }
            return Double(cur - old) / dt
        }

        let groups = Grouping.build(procs, wired: mem.wired, unmeasuredCPU: unmeasuredCPU)
        let payload = Payload(
            ts: now, live: true, host: host, cpu: cpu, mem: mem, gpu: gpu, battery: Machine.readBattery(),
            disk: DiskInfo(total: space.total, free: space.free, readRate: rate(disk.read, prev?.disk.read), writeRate: rate(disk.write, prev?.disk.write)),
            net: NetInfo(inRate: rate(net.rx, prev?.net.rx), outRate: rate(net.tx, prev?.net.tx), inTotal: net.rx, outTotal: net.tx),
            procs: ProcCounts(count: procs.count, unmeasured: procs.values.filter { !$0.measured }.count),
            groups: groups, recs: Grouping.recommend(groups), history: []
        )

        previous = Previous(time: now, ticks: ticks, disk: disk, net: net, cpuSeconds: procs.mapValues(\.cpuSeconds))
        if prev != nil {
            history.append(HistoryPoint(t: now, cpu: cpu.total, mem: mem.used, gpu: gpu?.util,
                                        netIn: payload.net.inRate, netOut: payload.net.outRate,
                                        diskR: payload.disk.readRate, diskW: payload.disk.writeRate))
            if history.count > 150 { history.removeFirst(history.count - 150) }
        }
        var withHistory = payload
        withHistory.history = history
        return withHistory
    }

    func encode(_ payload: Payload) -> Data {
        (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
