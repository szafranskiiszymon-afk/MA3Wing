import Foundation
import Network

/// One OSC argument as text (the page works with text values).
struct OSCMessage {
    let address: String
    let args: [String]
}

enum OSC {
    private static func pad(_ d: inout Data) { d.append(contentsOf: [UInt8](repeating: 0, count: 4 - d.count % 4)) }

    private static func string(_ s: String) -> Data {
        var d = Data(s.utf8)
        pad(&d)          // always at least one 0 byte
        return d
    }

    /// type: "i", "f" or "s"
    static func encode(address: String, type: String, value: String) -> Data {
        var d = string(address)
        let t = ["i", "f", "s"].contains(type) ? type : "s"
        d.append(string("," + t))
        switch t {
        case "i":
            var v = Int32(clamping: Int((Double(value) ?? 0).rounded())).bigEndian
            d.append(Data(bytes: &v, count: 4))
        case "f":
            var v = Float(Double(value) ?? 0).bitPattern.bigEndian
            d.append(Data(bytes: &v, count: 4))
        default:
            d.append(string(value))
        }
        return d
    }

    /// Decodes a packet (message or #bundle) into messages.
    static func decode(_ data: Data) -> [OSCMessage] {
        let b = [UInt8](data)
        var out: [OSCMessage] = []
        parse(b, 0, b.count, &out)
        return out
    }

    private static func readString(_ b: [UInt8], _ p: inout Int, _ end: Int) -> String? {
        var e = p
        while e < end && b[e] != 0 { e += 1 }
        guard e < end else { return nil }
        let s = String(decoding: b[p..<e], as: UTF8.self)
        p = (e + 4) & ~3
        return s
    }

    private static func int32(_ b: [UInt8], _ p: Int) -> UInt32 {
        return UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }

    private static func parse(_ b: [UInt8], _ start: Int, _ end: Int, _ out: inout [OSCMessage]) {
        var p = start
        guard let addr = readString(b, &p, end) else { return }
        if addr == "#bundle" {
            p += 8                                    // timetag
            while p + 4 <= end {
                let size = Int(int32(b, p)); p += 4
                if size <= 0 || p + size > end { break }
                parse(b, p, p + size, &out)
                p += size
            }
            return
        }
        var args: [String] = []
        if p < end, b[p] == 44, let tags = readString(b, &p, end) {          // ","
            for t in tags.dropFirst() {
                switch t {
                case "i":
                    guard p + 4 <= end else { break }
                    args.append(String(Int32(bitPattern: int32(b, p)))); p += 4
                case "f":
                    guard p + 4 <= end else { break }
                    let f = Float(bitPattern: int32(b, p)); p += 4
                    args.append(String(format: "%.3f", f))
                case "s":
                    if let s = readString(b, &p, end) { args.append(s) }
                case "T": args.append("1")
                case "F": args.append("0")
                default: break
                }
            }
        }
        out.append(OSCMessage(address: addr, args: args))
    }
}

/// UDP link to grandMA3: sends to ip:sendPort, listens on recvPort (MA's OSC "Send" line points to the iPad).
final class OSCLink {
    var onMessage: ((OSCMessage) -> Void)?
    var onState: ((String) -> Void)?

    private let queue = DispatchQueue(label: "ma3wing.osc")
    private var connection: NWConnection?
    private var listener: NWListener?
    private var inbound: [NWConnection] = []

    func start(host: String, sendPort: UInt16, recvPort: UInt16) {
        stop()
        guard let sp = NWEndpoint.Port(rawValue: sendPort) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: sp, using: .udp)
        c.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.onState?("OSC: \(e)") }
        }
        c.start(queue: queue)
        connection = c

        guard let rp = NWEndpoint.Port(rawValue: recvPort) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: rp)
            l.newConnectionHandler = { [weak self] nc in
                guard let self = self else { return }
                self.inbound.append(nc)
                nc.start(queue: self.queue)
                self.receive(nc)
            }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { self?.onState?("port \(recvPort): \(e)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onState?("nie moge otworzyc portu \(recvPort): \(error)")
        }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let d = data, !d.isEmpty {
                for m in OSC.decode(d) { self?.onMessage?(m) }
            }
            if error == nil { self?.receive(c) }
        }
    }

    func send(address: String, type: String, value: String) {
        connection?.send(content: OSC.encode(address: address, type: type, value: value),
                         completion: .contentProcessed { _ in })
    }

    func stop() {
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        inbound.forEach { $0.cancel() }; inbound = []
    }
}
