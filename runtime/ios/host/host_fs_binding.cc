#include "host_fs_binding.h"

#include <node.h>
#include <node_api.h>

#include <array>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace {

// Bounds exist so a hostile or confused caller cannot make the engine allocate
// without limit or wait forever. They are generous for real work and small enough
// to fail fast.
constexpr size_t kMaxReadBytes = 8 * 1024 * 1024;
constexpr size_t kMaxWriteBytes = 16 * 1024 * 1024;
constexpr size_t kMaxListEntries = 20000;
constexpr size_t kMaxCaptureBytes = 1024 * 1024;
constexpr int kDefaultTimeoutMs = 30000;
constexpr int kMaxTimeoutMs = 300000;

struct Failure {
  const char* code;
  std::string message;
};

bool Absolute(const std::string& path) {
  return !path.empty() && path[0] == '/' && path.find('\0') == std::string::npos;
}

std::string Errno(int value) {
  return std::string(strerror(value)) + " (errno " + std::to_string(value) + ")";
}

napi_value Throw(napi_env env, const char* code, const std::string& message) {
  napi_throw_error(env, code, message.c_str());
  return nullptr;
}

bool StringArg(napi_env env, napi_value value, std::string* out) {
  size_t size = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) return false;
  out->resize(size);
  if (size == 0) return true;
  size_t written = 0;
  if (napi_get_value_string_utf8(env, value, out->data(), size + 1, &written) != napi_ok) return false;
  out->resize(written);
  return true;
}

bool IntArg(napi_env env, napi_value value, int64_t* out) {
  return napi_get_value_int64(env, value, out) == napi_ok;
}

napi_value SetString(napi_env env, napi_value object, const char* key, const std::string& value) {
  napi_value text;
  if (napi_create_string_utf8(env, value.c_str(), value.size(), &text) != napi_ok) return nullptr;
  if (napi_set_named_property(env, object, key, text) != napi_ok) return nullptr;
  return object;
}

napi_value SetNumber(napi_env env, napi_value object, const char* key, double value) {
  napi_value number;
  if (napi_create_double(env, value, &number) != napi_ok) return nullptr;
  if (napi_set_named_property(env, object, key, number) != napi_ok) return nullptr;
  return object;
}

napi_value SetBool(napi_env env, napi_value object, const char* key, bool value) {
  napi_value boolean;
  if (napi_get_boolean(env, value, &boolean) != napi_ok) return nullptr;
  if (napi_set_named_property(env, object, key, boolean) != napi_ok) return nullptr;
  return object;
}

// What a caller needs to decide what to do next, without exposing the raw struct.
const char* Kind(mode_t mode) {
  if (S_ISDIR(mode)) return "directory";
  if (S_ISLNK(mode)) return "symlink";
  if (S_ISREG(mode)) return "file";
  return "other";
}

napi_value StatObject(napi_env env, const struct stat& info) {
  napi_value object;
  if (napi_create_object(env, &object) != napi_ok) return nullptr;
  if (!SetString(env, object, "kind", Kind(info.st_mode))) return nullptr;
  if (!SetNumber(env, object, "size", static_cast<double>(info.st_size))) return nullptr;
  if (!SetNumber(env, object, "mode", static_cast<double>(info.st_mode & 07777))) return nullptr;
  if (!SetNumber(env, object, "mtimeMs", static_cast<double>(info.st_mtimespec.tv_sec) * 1000.0 +
                                          static_cast<double>(info.st_mtimespec.tv_nsec) / 1e6)) {
    return nullptr;
  }
  if (!SetNumber(env, object, "uid", static_cast<double>(info.st_uid))) return nullptr;
  if (!SetNumber(env, object, "gid", static_cast<double>(info.st_gid))) return nullptr;
  return object;
}

// `stat(path)` → {kind, size, mode, mtimeMs, uid, gid}. Symlinks are followed,
// because callers ask "what will I read", not "what is the link".
napi_value Stat(napi_env env, napi_callback_info info) {
  size_t count = 1;
  napi_value argument;
  std::string path;
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok || count != 1 ||
      !StringArg(env, argument, &path)) {
    return Throw(env, "ERR_HOST_PATH", "stat(path): expected one string");
  }
  if (!Absolute(path)) return Throw(env, "ERR_HOST_PATH", "stat: path must be absolute: " + path);
  struct stat value;
  if (stat(path.c_str(), &value) != 0) return Throw(env, "ERR_HOST_STAT", path + ": " + Errno(errno));
  return StatObject(env, value);
}

// `list(path)` → [{name, kind, size}], directories first, then names, so the model
// reads a directory the way a person would.
napi_value List(napi_env env, napi_callback_info info) {
  size_t count = 1;
  napi_value argument;
  std::string path;
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok || count != 1 ||
      !StringArg(env, argument, &path)) {
    return Throw(env, "ERR_HOST_PATH", "list(path): expected one string");
  }
  if (!Absolute(path)) return Throw(env, "ERR_HOST_PATH", "list: path must be absolute: " + path);
  DIR* directory = opendir(path.c_str());
  if (!directory) return Throw(env, "ERR_HOST_LIST", path + ": " + Errno(errno));

  struct Entry {
    std::string name;
    napi_value object;
  };
  std::vector<Entry> entries;
  struct dirent* item = nullptr;
  while ((item = readdir(directory)) != nullptr) {
    if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0) continue;
    if (entries.size() >= kMaxListEntries) break;
    std::string child = path == "/" ? "/" + std::string(item->d_name) : path + "/" + item->d_name;
    struct stat value;
    if (lstat(child.c_str(), &value) != 0) continue;  // vanished between readdir and lstat
    napi_value object;
    if (napi_create_object(env, &object) != napi_ok) {
      closedir(directory);
      return nullptr;
    }
    if (!SetString(env, object, "name", item->d_name) ||
        !SetString(env, object, "kind", Kind(value.st_mode)) ||
        !SetNumber(env, object, "size", static_cast<double>(value.st_size))) {
      closedir(directory);
      return nullptr;
    }
    entries.push_back({item->d_name, object});
  }
  closedir(directory);

  napi_value result;
  if (napi_create_array_with_length(env, entries.size(), &result) != napi_ok) return nullptr;
  for (size_t i = 0; i < entries.size(); ++i) {
    if (napi_set_element(env, result, i, entries[i].object) != napi_ok) return nullptr;
  }
  return result;
}

// `read(path, maxBytes?)` → {data, bytes, truncated}. Text is returned as UTF-8;
// binary content survives as-is only up to the first NUL, so callers that need
// bytes should ask for a size first and read a slice.
napi_value Read(napi_env env, napi_callback_info info) {
  size_t count = 2;
  std::array<napi_value, 2> arguments{};
  std::string path;
  if (napi_get_cb_info(env, info, &count, arguments.data(), nullptr, nullptr) != napi_ok || count < 1 ||
      !StringArg(env, arguments[0], &path)) {
    return Throw(env, "ERR_HOST_PATH", "read(path): expected a path");
  }
  if (!Absolute(path)) return Throw(env, "ERR_HOST_PATH", "read: path must be absolute: " + path);
  size_t limit = kMaxReadBytes;
  if (count >= 2) {
    int64_t requested = 0;
    if (!IntArg(env, arguments[1], &requested) || requested <= 0) {
      return Throw(env, "ERR_HOST_SIZE", "read: maxBytes must be a positive integer");
    }
    limit = static_cast<size_t>(requested) < kMaxReadBytes ? static_cast<size_t>(requested) : kMaxReadBytes;
  }

  int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return Throw(env, "ERR_HOST_READ", path + ": " + Errno(errno));
  struct stat value;
  if (fstat(fd, &value) != 0) {
    int reason = errno;
    close(fd);
    return Throw(env, "ERR_HOST_READ", path + ": " + Errno(reason));
  }
  if (S_ISDIR(value.st_mode)) {
    close(fd);
    return Throw(env, "ERR_HOST_READ", path + ": is a directory, use list()");
  }

  size_t want = static_cast<size_t>(value.st_size) < limit ? static_cast<size_t>(value.st_size) : limit;
  std::string data(want, '\0');
  ssize_t got = want == 0 ? 0 : read(fd, data.data(), want);
  if (got < 0) {
    int reason = errno;
    close(fd);
    return Throw(env, "ERR_HOST_READ", path + ": " + Errno(reason));
  }
  close(fd);
  data.resize(static_cast<size_t>(got));

  napi_value result;
  if (napi_create_object(env, &result) != napi_ok) return nullptr;
  napi_value text;
  if (napi_create_string_utf8(env, data.data(), data.size(), &text) != napi_ok) return nullptr;
  if (napi_set_named_property(env, result, "data", text) != napi_ok) return nullptr;
  if (!SetNumber(env, result, "bytes", static_cast<double>(data.size()))) return nullptr;
  if (!SetBool(env, result, "truncated", static_cast<size_t>(value.st_size) > limit)) return nullptr;
  return result;
}

// `write(path, data)` → {bytes}. Written to a sibling temporary and renamed, so a
// crash mid-write cannot leave a half file where a whole one used to be.
napi_value Write(napi_env env, napi_callback_info info) {
  size_t count = 2;
  std::array<napi_value, 2> arguments{};
  std::string path;
  std::string data;
  if (napi_get_cb_info(env, info, &count, arguments.data(), nullptr, nullptr) != napi_ok || count != 2 ||
      !StringArg(env, arguments[0], &path) || !StringArg(env, arguments[1], &data)) {
    return Throw(env, "ERR_HOST_PATH", "write(path, data): expected two strings");
  }
  if (!Absolute(path)) return Throw(env, "ERR_HOST_PATH", "write: path must be absolute: " + path);
  if (data.size() > kMaxWriteBytes) {
    return Throw(env, "ERR_HOST_SIZE", "write: refusing " + std::to_string(data.size()) + " bytes");
  }

  std::string temporary = path + ".dsh-" + std::to_string(getpid()) + ".tmp";
  int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return Throw(env, "ERR_HOST_WRITE", temporary + ": " + Errno(errno));
  size_t written = 0;
  while (written < data.size()) {
    ssize_t count_written = write(fd, data.data() + written, data.size() - written);
    if (count_written <= 0) {
      int reason = errno;
      close(fd);
      unlink(temporary.c_str());
      return Throw(env, "ERR_HOST_WRITE", path + ": " + Errno(reason));
    }
    written += static_cast<size_t>(count_written);
  }
  if (fsync(fd) != 0) {
    int reason = errno;
    close(fd);
    unlink(temporary.c_str());
    return Throw(env, "ERR_HOST_WRITE", path + ": fsync: " + Errno(reason));
  }
  close(fd);
  if (rename(temporary.c_str(), path.c_str()) != 0) {
    int reason = errno;
    unlink(temporary.c_str());
    return Throw(env, "ERR_HOST_WRITE", path + ": rename: " + Errno(reason));
  }

  napi_value result;
  if (napi_create_object(env, &result) != napi_ok) return nullptr;
  if (!SetNumber(env, result, "bytes", static_cast<double>(data.size()))) return nullptr;
  return result;
}

// Reads a pipe until EOF, capped so a chatty child cannot exhaust memory.
std::string Drain(int fd) {
  std::string out;
  std::array<char, 4096> buffer{};
  while (out.size() < kMaxCaptureBytes) {
    ssize_t got = read(fd, buffer.data(), buffer.size());
    if (got <= 0) break;
    out.append(buffer.data(), static_cast<size_t>(got));
  }
  return out;
}

// `exec(path, argv, {timeoutMs, cwd})` → {code, signal, stdout, stderr, timedOut}.
// Runs a host binary directly; the guest's shell cannot, because iSH executes ELF
// and every iOS binary here is Mach-O.
napi_value Exec(napi_env env, napi_callback_info info) {
  size_t count = 3;
  std::array<napi_value, 3> arguments{};
  std::string path;
  if (napi_get_cb_info(env, info, &count, arguments.data(), nullptr, nullptr) != napi_ok || count < 2 ||
      !StringArg(env, arguments[0], &path)) {
    return Throw(env, "ERR_HOST_EXEC", "exec(path, argv): expected a path");
  }
  if (!Absolute(path)) return Throw(env, "ERR_HOST_EXEC", "exec: path must be absolute: " + path);

  bool is_array = false;
  uint32_t length = 0;
  if (napi_is_array(env, arguments[1], &is_array) != napi_ok || !is_array ||
      napi_get_array_length(env, arguments[1], &length) != napi_ok || length == 0 || length > 64) {
    return Throw(env, "ERR_HOST_EXEC", "exec: argv must be an array of 1..64 strings");
  }
  std::vector<std::string> storage;
  storage.reserve(length);
  for (uint32_t i = 0; i < length; ++i) {
    napi_value element;
    std::string text;
    if (napi_get_element(env, arguments[1], i, &element) != napi_ok || !StringArg(env, element, &text)) {
      return Throw(env, "ERR_HOST_EXEC", "exec: argv entries must be strings");
    }
    storage.push_back(text);
  }

  int timeout_ms = kDefaultTimeoutMs;
  std::string cwd;
  if (count >= 3) {
    napi_valuetype kind = napi_undefined;
    if (napi_typeof(env, arguments[2], &kind) == napi_ok && kind == napi_object) {
      napi_value value;
      if (napi_get_named_property(env, arguments[2], "timeoutMs", &value) == napi_ok) {
        int64_t requested = 0;
        if (IntArg(env, value, &requested) && requested > 0) {
          timeout_ms = requested > kMaxTimeoutMs ? kMaxTimeoutMs : static_cast<int>(requested);
        }
      }
      if (napi_get_named_property(env, arguments[2], "cwd", &value) == napi_ok) {
        std::string requested;
        if (StringArg(env, value, &requested) && Absolute(requested)) cwd = requested;
      }
    }
  }

  // iOS has no `posix_spawn_file_actions_addchdir_np`, so a working directory
  // cannot be set for the child. Refusing is clearer than silently running in the
  // App's own directory: a caller that asked for `cwd` is probably about to use
  // relative paths.
  if (!cwd.empty()) {
    return Throw(env, "ERR_HOST_EXEC_CWD", "exec: cwd is not supported on iOS; use absolute paths");
  }

  int out_pipe[2] = {-1, -1};
  int err_pipe[2] = {-1, -1};
  if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
    return Throw(env, "ERR_HOST_EXEC", std::string("exec: pipe: ") + Errno(errno));
  }
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO);
  posix_spawn_file_actions_addclose(&actions, out_pipe[0]);
  posix_spawn_file_actions_addclose(&actions, err_pipe[0]);
  posix_spawn_file_actions_addclose(&actions, out_pipe[1]);
  posix_spawn_file_actions_addclose(&actions, err_pipe[1]);


  std::vector<char*> argv;
  argv.reserve(storage.size() + 2);
  argv.push_back(const_cast<char*>(path.c_str()));
  for (const std::string& item : storage) argv.push_back(const_cast<char*>(item.c_str()));
  argv.push_back(nullptr);

  pid_t pid = 0;
  int spawned = posix_spawn(&pid, path.c_str(), &actions, nullptr, argv.data(), environ);
  posix_spawn_file_actions_destroy(&actions);
  close(out_pipe[1]);
  close(err_pipe[1]);
  if (spawned != 0) {
    close(out_pipe[0]);
    close(err_pipe[0]);
    return Throw(env, "ERR_HOST_EXEC", path + ": " + Errno(spawned));
  }

  // Poll rather than block so a hung child cannot hold the engine's thread for
  // longer than the deadline the caller asked for.
  bool timed_out = false;
  int status = 0;
  int waited_ms = 0;
  for (;;) {
    pid_t done = waitpid(pid, &status, WNOHANG);
    if (done == pid) break;
    if (done < 0 && errno != EINTR) break;
    if (waited_ms >= timeout_ms) {
      timed_out = true;
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      break;
    }
    usleep(20 * 1000);
    waited_ms += 20;
  }

  std::string out = Drain(out_pipe[0]);
  std::string err = Drain(err_pipe[0]);
  close(out_pipe[0]);
  close(err_pipe[0]);

  int code = -1;
  int signal_number = 0;
  if (WIFEXITED(status)) code = WEXITSTATUS(status);
  if (WIFSIGNALED(status)) signal_number = WTERMSIG(status);

  napi_value result;
  if (napi_create_object(env, &result) != napi_ok) return nullptr;
  if (!SetNumber(env, result, "code", code)) return nullptr;
  if (!SetNumber(env, result, "signal", signal_number)) return nullptr;
  if (!SetBool(env, result, "timedOut", timed_out)) return nullptr;
  napi_value out_text;
  napi_value err_text;
  if (napi_create_string_utf8(env, out.data(), out.size(), &out_text) != napi_ok ||
      napi_create_string_utf8(env, err.data(), err.size(), &err_text) != napi_ok) {
    return nullptr;
  }
  if (napi_set_named_property(env, result, "stdout", out_text) != napi_ok) return nullptr;
  if (napi_set_named_property(env, result, "stderr", err_text) != napi_ok) return nullptr;
  if (!SetBool(env, result, "truncated", out.size() >= kMaxCaptureBytes)) return nullptr;
  return result;
}

napi_value Initialize(napi_env env, napi_value exports) {
  struct {
    const char* name;
    napi_callback callback;
  } functions[] = {
      {"stat", Stat},
      {"list", List},
      {"read", Read},
      {"write", Write},
      {"exec", Exec},
  };
  for (const auto& entry : functions) {
    napi_value function;
    if (napi_create_function(env, entry.name, NAPI_AUTO_LENGTH, entry.callback, nullptr, &function) !=
            napi_ok ||
        napi_set_named_property(env, exports, entry.name, function) != napi_ok) {
      return nullptr;
    }
  }
  return exports;
}

napi_module module = {NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
                      "runtime/ios/host/host_fs_binding.cc", Initialize, "dsh_ios_hostfs", nullptr,
                      {nullptr, nullptr, nullptr, nullptr}};

}  // namespace

void RegisterHostFsBinding() {
  napi_module_register(&module);
}
