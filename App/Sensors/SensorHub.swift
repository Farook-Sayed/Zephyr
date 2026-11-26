import Foundation

/// Owns every low-level reader and produces one `Snapshot` per poll. Runs off the main thread.
actor SensorHub {
    private let smc = SMCSensors()
    private let hid = HIDTemperatures()
    private let energy = IOReportEnergy()
    private let storage = StorageReader()
    private let memory = MemoryReader()
    private let network = NetworkReader()

    var hasSMC: Bool { smc != nil }
    var fanLimitsKnown: Bool { !(smc?.fans().isEmpty ?? true) }

    func sample(detailed: Bool) -> Snapshot {
        var s = Snapshot()
        s.fans = smc?.fans() ?? []

        var temps = smc?.temps(detailed: detailed) ?? []
        // HID die sensors are comparatively expensive and duplicate the SMC core sensors; dashboard only.
        if detailed, let hidTemps = hid?.read() { temps.append(contentsOf: hidTemps) }
        s.temps = temps

        let (battery, adapter) = BatteryReader.read()
        s.battery = battery
        s.adapter = adapter

        var power = PowerReading()
        if let smc {
            let p = smc.systemPower()
            power.systemW = p.system
            power.dcInW = p.dcIn
            power.packageW = p.package
            power.cpuW = p.cpu
        }
        if let w = energy?.read() {
            // On this OS the CPU energy channels read zero for unprivileged processes; keep the SMC value then.
            if w.cpu > 0.01 { power.cpuW = w.cpu }
            power.gpuW = w.gpu; power.aneW = w.ane; power.dramW = w.dram
        }
        if let v = battery.voltage, let a = battery.amperage { power.batteryW = v * a }
        s.power = power

        s.storage = storage.read()
        s.gpu = GPUReader.read()
        s.memory = memory.read(includeProcesses: detailed)
        s.network = network.read(includeWifi: detailed)
        s.pressure = ThermalPressure(ProcessInfo.processInfo.thermalState)
        return s
    }

    func energyChannelNames() -> [String] { energy?.debugDeltas() ?? [] }
}
