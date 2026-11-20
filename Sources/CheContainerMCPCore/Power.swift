import Foundation
import IOKit
import IOKit.pwr_mgt

/// Holds or releases the idle-sleep assertion (design: job 執行期間持有防閒置睡眠 assertion).
public protocol PowerAssertion: AnyObject, Sendable {
    var isHeld: Bool { get }
    func setHeld(_ held: Bool)
}

/// `kIOPMAssertionTypePreventUserIdleSystemSleep`, the same kind `caffeinate -i` takes. The
/// system drops it when this process exits, so a crash never leaves the machine awake.
public final class IOKitPowerAssertion: PowerAssertion, @unchecked Sendable {
    public static let name = "che-container-mcp: container job running"

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    public init() {}

    public var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }

    public func setHeld(_ wanted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if wanted && !held {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     Self.name as CFString, &id)
            if result == kIOReturnSuccess {
                assertionID = id
                held = true
            } else {
                FileHandle.standardError.write(Data("[che-container-mcp] could not take the sleep assertion (\(result))\n".utf8))
            }
        } else if !wanted && held {
            IOPMAssertionRelease(assertionID)
            held = false
        }
    }

    deinit { if held { IOPMAssertionRelease(assertionID) } }
}

/// Reports system sleep and wake (design: 睡眠紀錄) through `IORegisterForSystemPower`, on a
/// dedicated thread with its own run loop.
public final class SleepObserver: @unchecked Sendable {
    // iokit_common_msg.h values; the C macros do not import into Swift.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let handler: @Sendable (SleepEvent.Kind, Date) -> Void
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private var thread: Thread?

    public init(handler: @escaping @Sendable (SleepEvent.Kind, Date) -> Void) {
        self.handler = handler
    }

    public func start() {
        guard thread == nil else { return }
        let thread = Thread { [self] in
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, argument in
                guard let refcon else { return }
                Unmanaged<SleepObserver>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument)
            }, &notifier)
            guard rootPort != 0, let port else {
                FileHandle.standardError.write(Data("[che-container-mcp] could not register for power notifications\n".utf8))
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            CFRunLoopRun()
        }
        thread.name = "che-container-mcp.power"
        self.thread = thread
        thread.start()
    }

    private func handle(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch UInt32(messageType) {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            handler(.sleep, Date())
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            handler(.wake, Date())
        default:
            break
        }
    }
}
