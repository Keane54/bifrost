import Darwin
import Foundation
import IOKit.ps

// The memory pressure level of the kernel (kern.memorystatus_vm_pressure_level).
package enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical

    // The kernel gives 1, 2 or 4. Another value gives nil.
    package init?(kernelLevel: Int32) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }
}

// The swap: the used and the total size in bytes.
package struct SwapUse: Sendable, Equatable {
    package var used: UInt64
    package var total: UInt64
}

// The CPU ticks of all cores since the start of the Mac: the busy ticks (user, system and nice)
// and the idle ticks. The load comes from two reads.
package struct CPUTicks: Sendable, Equatable {
    package var busy: UInt64
    package var idle: UInt64

    package init(busy: UInt64, idle: UInt64) {
        self.busy = busy
        self.idle = idle
    }
}

// Where the power of the Mac comes from.
package enum PowerState: Sendable, Equatable {
    case charging
    // On the power adapter and not charging, for example with a full battery.
    case pluggedIn
    case onBattery
}

package struct BatteryState: Sendable, Equatable {
    package var percent: Int
    package var power: PowerState

    package init(percent: Int, power: PowerState) {
        self.percent = percent
        self.power = power
    }

    // The state from the description of a power source (IOPSGetPowerSourceDescription). nil for a
    // source that is not the internal battery, and for a source with no capacity.
    package init?(description: [String: Any]) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
            let current = description[kIOPSCurrentCapacityKey] as? Int,
            let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
        else { return nil }
        percent = Int((Double(current) * 100 / Double(max)).rounded())
        if description[kIOPSIsChargingKey] as? Bool == true {
            power = .charging
        } else if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
            power = .pluggedIn
        } else {
            power = .onBattery
        }
    }
}

// The values of the section "Your Mac" of the panel. A value is nil when its read failed, or when
// the Mac has no such part (no battery). The load needs two reads.
package struct MacValues: Sendable, Equatable {
    package var pressure: MemoryPressure?
    package var swap: SwapUse?
    // The load of all cores, from 0 to 1.
    package var load: Double?
    package var thermal: ProcessInfo.ThermalState
    package var battery: BatteryState?
}

// The reads of the state of the Mac (docs/behaviour/health.md, "Performance"): system calls only,
// no program. The app uses MacState.system. A test gives its own reads.
package struct MacState: Sendable {
    package var pressure: @Sendable () -> MemoryPressure?
    package var swap: @Sendable () -> SwapUse?
    package var cpuTicks: @Sendable () -> CPUTicks?
    package var thermal: @Sendable () -> ProcessInfo.ThermalState
    package var battery: @Sendable () -> BatteryState?

    package init(
        pressure: @escaping @Sendable () -> MemoryPressure?,
        swap: @escaping @Sendable () -> SwapUse?,
        cpuTicks: @escaping @Sendable () -> CPUTicks?,
        thermal: @escaping @Sendable () -> ProcessInfo.ThermalState,
        battery: @escaping @Sendable () -> BatteryState?
    ) {
        self.pressure = pressure
        self.swap = swap
        self.cpuTicks = cpuTicks
        self.thermal = thermal
        self.battery = battery
    }

    // The reads of the system: sysctl for the memory pressure and the swap, host_statistics for
    // the CPU ticks, ProcessInfo for the thermal state and the power sources of IOKit for the
    // battery.
    package static let system = MacState(
        pressure: readPressure, swap: readSwap, cpuTicks: readTicks,
        thermal: { ProcessInfo.processInfo.thermalState }, battery: readBattery)

    // The load of all cores between two reads of the ticks, from 0 to 1. nil when no tick passed,
    // or when a counter went down.
    package static func load(from earlier: CPUTicks, to later: CPUTicks) -> Double? {
        guard later.busy >= earlier.busy, later.idle >= earlier.idle else { return nil }
        let busy = later.busy - earlier.busy
        let total = busy + (later.idle - earlier.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }

    private static func readPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return nil }
        return MemoryPressure(kernelLevel: level)
    }

    private static func readSwap() -> SwapUse? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUse(used: usage.xsu_used, total: usage.xsu_total)
    }

    // The host port of the app. One port serves all reads.
    private static let host = mach_host_self()

    private static func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let busy =
            UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)  // user, system, nice
        return CPUTicks(busy: busy, idle: UInt64(ticks.2))
    }

    // The internal battery, or nil when the Mac has none.
    private static func readBattery() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                let battery = BatteryState(description: description)
            else { continue }
            return battery
        }
        return nil
    }
}
