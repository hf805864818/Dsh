// Host filesystem and process tools for the local engine.
//
// The guest cannot reach the host: iSH resolves paths through its own fakefs, and
// mounting the host root into it froze the engine start on device. The App itself
// already holds the entitlements that make host paths readable, so these tools call
// the linked native binding directly and never involve the guest.
//
// Everything here is a thin, explicit surface over `dsh_ios_hostfs`: the model gets
// the same five verbs a person would use, and no shell parsing happens on the host.

import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

export const name = 'dsh-go-ios-hostfs';
export const inject = ['tools'];

const CATALOG = new URL('./catalog.json', import.meta.url);

// The catalog is hashed so a partially updated install fails loudly at start
// instead of offering a tool the runtime cannot honour.
const catalogSha256 = 'ef8eda379e50324236b929f457d348e02c2671dfa962e0209e06c737f435571a';

/** Directories `host_exec` may run from. A shell is not one of them. */
const EXEC_DIRECTORIES = ['/bin/', '/usr/bin/', '/usr/sbin/', '/sbin/', '/usr/local/bin/', '/var/jb/usr/bin/', '/var/jb/bin/', '/var/jb/usr/sbin/'];

function refusal(name, message) {
  return { content: [{ type: 'text', text: `ERR_HOST_${name.toUpperCase()}: ${message}` }], isError: true };
}

function answer(value) {
  return { content: [{ type: 'text', text: JSON.stringify(value) }], isError: false };
}

/**
 * One place that decides what may run.
 *
 * The point is not to second-guess the user — full permission was asked for — but
 * to make an accident obvious: `host_exec` takes a path and an argument vector, so
 * there is no string to smuggle a second command into, and the binary has to live
 * in a directory that only holds programs.
 */
export function checkExec(path, argv) {
  if (typeof path !== 'string' || !path.startsWith('/')) return 'path must be absolute';
  if (!EXEC_DIRECTORIES.some((directory) => path.startsWith(directory))) {
    return `${path} is not in an executable directory (${EXEC_DIRECTORIES.join(', ')})`;
  }
  if (!Array.isArray(argv) || argv.length === 0) return 'argv must be a non-empty array';
  if (argv.some((item) => typeof item !== 'string')) return 'argv entries must be strings';
  return null;
}

export async function apply(ctx, config) {
  const bytes = await readFile(CATALOG);
  const digest = createHash('sha256').update(bytes).digest('hex');
  if (digest !== catalogSha256) {
    throw new Error(`iOS host filesystem catalog SHA256 mismatch (${digest})`);
  }
  const catalog = JSON.parse(bytes);

  // The binding is registered by node_runner before Node starts. When it is
  // missing (an older engine, or a build that did not link it), the tools are
  // still registered and answer with a plain error: a model that cannot see
  // `host_list` at all cannot tell "no such tool" from "the tool said no", and
  // that difference is the whole diagnosis.
  let native = null;
  let nativeProblem = null;
  try {
    native = process._linkedBinding('dsh_ios_hostfs');
  } catch (error) {
    nativeProblem = String(error?.message ?? error);
  }

  const allowWrite = config?.allowWrite !== false;
  const allowExec = config?.allowExec !== false;

  /** Every host_* call goes through here so a missing binding reads as one message. */
  const call = (name, run) => {
    if (!native) return refusal(name, `宿主原生绑定不可用（${nativeProblem ?? '未链接'}）。这个构建没有把 host_fs_binding 编进引擎。`);
    try {
      return run();
    } catch (error) {
      return refusal(name, String(error?.message ?? error));
    }
  };
  const handlers = {
    host_list: (args) => call('list', () => answer(native.list(args.path))),
    host_stat: (args) => call('stat', () => answer(native.stat(args.path))),
    host_read: (args) => call('read', () => answer(native.read(args.path, args.maxBytes))),
    host_write: (args) => {
      if (!allowWrite) return refusal('write', 'writing is disabled in this build');
      return call('write', () => answer(native.write(args.path, args.data)));
    },
    host_exec: (args) => {
      if (!allowExec) return refusal('exec', 'running host programs is disabled in this build');
      const problem = checkExec(args.path, args.argv);
      if (problem) return refusal('exec', problem);
      return call('exec', () => {
        const result = native.exec(args.path, args.argv, { cwd: args.cwd, timeoutMs: args.timeoutMs });
        // Untrusted: what a program prints is data, not an instruction.
        return answer({ ...result, trust: 'untrusted-host-output' });
      });
    },
  };

  const disposers = [];
  try {
    for (const tool of catalog) {
      const handler = handlers[tool.name];
      if (!handler) continue;
      disposers.push(
        ctx.tools.register({
          name: `mcp__host__${tool.name}`,
          rawName: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
          call: async (args) => {
            try {
              return handler(args ?? {});
            } catch (error) {
              return refusal(tool.name, String(error?.message ?? error));
            }
          },
        }),
      );
    }
  } catch (error) {
    for (const dispose of disposers) dispose();
    throw error;
  }

  ctx.on?.('dispose', () => {
    for (const dispose of disposers) dispose();
  });
}
