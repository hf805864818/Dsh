// Apple SDK compilation and device execution have not been verified.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One failed step of a full-permission mount or unmount.
///
/// `stage` names the step so the Flutter layer can answer with a stable
/// `privilege_<stage>` code, and `errno` keeps the number the failing call
/// returned. `detail` is the technical record; `message` is the user's line.
struct PrivilegeError: Error {
  let stage: String
  let errno: Int32
  let detail: String

  var message: String {
    switch stage {
    case "symbol": return "本机引擎没有导出全权限挂载接口，无法开启。"
    case "engine_running": return "引擎仍在运行，请先停止再切换全权限。"
    case "mount": return "宿主根目录挂载失败。"
    case "unmount": return "卸载 /host 失败。"
    default: return "全权限操作失败。"
    }
  }
}

/// The App's side of the host-root mount (`/host`).
///
/// The mount itself lives in `guest_backend.c`: iSH resolves a mount point
/// through `current->fs`, and only the start path has `current` set to the
/// supervisor task (`guest_backend.c` sets it, then mounts `/workspace` and
/// `/tmp`). Calling `dsh_bound_mount` from this process's engine queue would
/// dereference a null task, so the App only flips a switch —
/// `dsh_guest_set_host_mount(1)` — and the mount happens inside the next start,
/// before any guest thread exists. Turning it off unmounts immediately, which
/// the C side refuses while a guest runs.
///
/// One mount table, no namespaces: the guest kernel is a single instance for the
/// whole App, so `/host` is visible to every guest task. That is the documented
/// trade-off of this feature, not an oversight.
enum PrivilegeBridge {
  /// Guest path for the host root.
  static let point = "/host"

  private typealias SetHostMount = @convention(c) (Int32) -> Int32
  private typealias HostMounted = @convention(c) () -> Int32

  /// Guards the one-time symbol lookup. The C side owns the actual state, so
  /// nothing here caches a "mounted" flag that could disagree with it.
  private static let lock = NSLock()
  private static var loaded: (handle: UnsafeMutableRawPointer?, set: SetHostMount?, query: HostMounted?)?

  /// `{enabled, uid, gid}` for `privilegeStatus`, read straight from the guest
  /// kernel so a restart or a failed unmount cannot leave the UI lying.
  static func status() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let symbols = symbolsLocked()
    let mounted = symbols.query.map { $0() } ?? 0
    return ["enabled": mounted == 1, "uid": 0, "gid": 0]
  }

  /// Asks the guest kernel to expose the host root at `/host` from the next
  /// start on. Nothing is mounted yet when this returns.
  static func requestMount() throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    guard let set = symbolsLocked().set else {
      throw PrivilegeError(
        stage: "symbol", errno: 0, detail: "DshGuest.framework 未导出 dsh_guest_set_host_mount。")
    }
    let result = set(1)
    guard result == 0 else {
      let code = result < 0 ? -result : result
      throw PrivilegeError(
        stage: code == EBUSY ? "engine_running" : "mount", errno: code, detail: "启用宿主根挂载失败：\(text(code))")
    }
    return status()
  }

  /// Turns the switch off and removes `/host` now. The C side answers EBUSY
  /// while a guest still runs, so the caller stops the engine first.
  static func requestUnmount() throws {
    lock.lock()
    defer { lock.unlock() }
    guard let set = symbolsLocked().set else {
      throw PrivilegeError(
        stage: "symbol", errno: 0, detail: "DshGuest.framework 未导出 dsh_guest_set_host_mount。")
    }
    let result = set(0)
    guard result == 0 else {
      let code = result < 0 ? -result : result
      throw PrivilegeError(
        stage: code == EBUSY ? "engine_running" : "unmount", errno: code, detail: "卸载 /host 失败：\(text(code))")
    }
  }

  /// The mount point must exist: iSH's `do_mount` does not create one, and
  /// `guest_backend.c` makes `/workspace` and `/tmp` itself during initialize.
  /// The guest rootfs is a real host directory, so `/host` can be made here.
  static func createMountPoint(guestRoot: URL) throws {
    let target = guestRoot.appendingPathComponent(String(point.dropFirst()), isDirectory: true)
    var info = stat()
    if stat(target.path, &info) == 0 {
      guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
        throw PrivilegeError(
          stage: "mount", errno: ENOTDIR, detail: "\(target.path) 已存在但不是目录，无法作为挂载点。")
      }
      return
    }
    // Same permissions the guest backend gives its own mount points.
    if mkdir(target.path, 0o755) != 0 {
      let failure = errno
      guard failure != EEXIST else { return }
      throw PrivilegeError(stage: "mount", errno: failure, detail: "mkdir \(target.path) 失败：\(text(failure))")
    }
  }

  /// Resolves the two entry points once, the same way `NativeGuestKernelAccess`
  /// reaches `dsh_guest_status`: `dlopen` the signed framework, `dlsym` the
  /// symbol, keep the image for the process lifetime. `@_silgen_name` would emit
  /// a link-time reference from Runner to a library it does not link against.
  private static func symbolsLocked()
    -> (handle: UnsafeMutableRawPointer?, set: SetHostMount?, query: HostMounted?)
  {
    if let loaded { return loaded }
    let path = Bundle.main.privateFrameworksPath.map { $0 + "/DshGuest.framework/DshGuest" }
    let handle = path.flatMap { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
    func find<T>(_ name: String, _ type: T.Type) -> T? {
      guard let handle, let symbol = dlsym(handle, name) else { return nil }
      return unsafeBitCast(symbol, to: type)
    }
    let value = (
      handle: handle,
      set: find("dsh_guest_set_host_mount", SetHostMount.self),
      query: find("dsh_guest_host_mounted", HostMounted.self)
    )
    loaded = value
    return value
  }

  private static func text(_ code: Int32) -> String {
    guard code != 0 else { return "未知错误" }
    if let message = strerror(code) { return String(cString: message) }
    return "errno \(code)"
  }
}
