// rusage PID... : "pid name cpu_ms child_cpu_ms wakeups energy_mJ child_energy?" per pid
import Foundation
func name(_ pid: Int32) -> String {
  var buf = [CChar](repeating: 0, count: 256)
  proc_name(pid, &buf, 256)
  return String(cString: buf)
}
let tb: Double = { var i = mach_timebase_info(); mach_timebase_info(&i); return Double(i.numer) / Double(i.denom) }()
for a in CommandLine.arguments.dropFirst() {
  guard let pid = Int32(a) else { continue }
  var ri = rusage_info_v6()
  let r = withUnsafeMutablePointer(to: &ri) { p in
    p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
  }
  if r != 0 { print(pid, name(pid), "ERR"); continue }
  let cpu = Double(ri.ri_user_time + ri.ri_system_time) * tb / 1e6
  let ccpu = Double(ri.ri_child_user_time + ri.ri_child_system_time) * tb / 1e6
  let wk = ri.ri_pkg_idle_wkups + ri.ri_interrupt_wkups
  let cwk = ri.ri_child_pkg_idle_wkups + ri.ri_child_interrupt_wkups
  print(pid, name(pid), String(format: "%.1f %.1f %llu %llu %.1f", cpu, ccpu, wk, cwk, Double(ri.ri_energy_nj) / 1e6))
}
