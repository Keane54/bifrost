// The state of the Mac for the Performance panel: memory pressure, swap, CPU load, thermal state
// and battery. Safety: the system reads only read the counters of the kernel and the power
// sources. They change nothing.
import Foundation
import Testing

@testable import BifrostHealth

@Suite("performance mac state")
struct MacStateTests {
    @Test func theLoadComesFromTheTicksBetweenTwoReads() {
        let first = CPUTicks(busy: 1000, idle: 3000)
        let second = CPUTicks(busy: 1600, idle: 3400)
        // 600 busy ticks of 1000 ticks in all.
        #expect(MacState.load(from: first, to: second) == 0.6)
        // No ticks between the reads give no load.
        #expect(MacState.load(from: first, to: first) == nil)
        // A counter that went down gives no load.
        #expect(MacState.load(from: second, to: first) == nil)
    }

    @Test func thePressureLevelsOfTheKernel() {
        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warning)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure(kernelLevel: 0) == nil)
        #expect(MemoryPressure(kernelLevel: 3) == nil)
    }

    @Test func theBatteryComesFromThePowerSource() {
        let charging = BatteryState(
            description: [
                "Type": "InternalBattery", "Current Capacity": 41, "Max Capacity": 100,
                "Is Charging": true, "Power Source State": "AC Power",
            ])
        #expect(charging == BatteryState(percent: 41, power: .charging))
        let full = BatteryState(
            description: [
                "Type": "InternalBattery", "Current Capacity": 100, "Max Capacity": 100,
                "Is Charging": false, "Power Source State": "AC Power",
            ])
        #expect(full == BatteryState(percent: 100, power: .pluggedIn))
        let draining = BatteryState(
            description: [
                "Type": "InternalBattery", "Current Capacity": 18, "Max Capacity": 50,
                "Is Charging": false, "Power Source State": "Battery Power",
            ])
        #expect(draining == BatteryState(percent: 36, power: .onBattery))
        // A source that is not the battery of the Mac, and a source with no capacity.
        #expect(BatteryState(description: ["Type": "UPS", "Current Capacity": 50]) == nil)
        #expect(BatteryState(description: ["Type": "InternalBattery"]) == nil)
    }

    @Test func theSystemReadsGiveValues() throws {
        let mac = MacState.system
        #expect(mac.pressure() != nil)
        let swap = try #require(mac.swap())
        #expect(swap.used <= swap.total)
        let first = try #require(mac.cpuTicks())
        #expect(first.busy + first.idle > 0)
    }
}
