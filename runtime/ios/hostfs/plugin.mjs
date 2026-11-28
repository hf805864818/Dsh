// Host filesystem and process tools for the local engine.
//
// The guest cannot reach the host: iSH resolves paths through its own fakefs, and
// mounting the host root into it froze the engine start on device. The App itself
// already holds the entitlements that make host paths readable, so these tools call
// the linked native binding directly and never involve the guest.
//
// Two things worth knowing about how this file is loaded:
//
//   * it is registered from `ios-host.patch.json`, next to the phone plugin, so any
//     throw here means "no host tools at all" and nothing in the UI would say why.
//     Every failure therefore writes a report to `config.selftestPath`, which the
//     Diagnostics page shows;
//   * tools are defined with `createMcpToolDefinition`, the same constructor the
//     phone and browser plugins use. A plain object registered fine in tests but the
//     engine's tool registry wants the definition shape, and the mismatch showed up
//     as "this session has no host_list" rather than as an error.

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

import { createMcpToolDefinition } from '@deepseek-ai/dsh-mcp-client';

export const name = 'dsh-go-ios-hostfs';
export const inject = ['tools'];

const CATALOG = new URL('./catalog.json', import.meta.url);

// Hashed so a partially updated install fails loudly instead of offering a tool the
// runtime cannot honour.
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
 * The point is not to second-guess the user — full permission was asked for — but to
 * make an accident obvious: `host_exec` takes a path and an argument vector, so there
 * is no string to smuggle a second command into, and the binary has to live in a
 * directory that only holds programs.
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
  const report = { ok: false, stage: 'start' };
  const record = async (patch) => {
    Object.assign(report, patch);
    if (!config?.selftestPath) return;
    await writeFile(config.selftestPath, JSON.stringify(report), { mode: 0o600 }).catch(() => {});
  };

  try {
    const bytes = await readFile(CATALOG);
    const digest = createHash('sha256').update(bytes).digest('hex');
    if (digest !== catalogSha256) throw new Error(`catalog SHA256 mismatch (${digest})`);
    const catalog = JSON.parse(bytes);
    await record({ stage: 'catalog', ok: true });

    // Registered by node_runner before Node starts. When it is missing the tools are
    // still offered and answer with that reason: "no such tool" and "the tool said
    // no" are different diagnoses and must not look the same.
    let native = null;
    let nativeProblem = null;
    try {
      native = process._linkedBinding('dsh_ios_hostfs');
    } catch (error) {
      nativeProblem = String(error?.message ?? error);
    }

    const allowWrite = config?.allowWrite !== false;
    const allowExec = config?.allowExec !== false;

    /** Every host_* call goes through here, so a missing binding reads as one message. */
    const call = (label, run) => {
      if (!native) return refusal(label, `宿主原生绑定不可用（${nativeProblem ?? '未链接'}）。这个构建没有把 host_fs_binding 编进引擎。`);
      try {
        return run();
      } catch (error) {
        return refusal(label, String(error?.message ?? error));
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
    for (const tool of catalog) {
      const handler = handlers[tool.name];
      if (!handler) continue;
      disposers.push(
        ctx.tools.register(
          createMcpToolDefinition(ctx, {
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
        ),
      );
    }
    ctx.on?.('dispose', () => {
      for (const dispose of disposers) dispose();
    });

    // What the Diagnostics page reads: proof that this process can reach the host,
    // not just that a file was copied.
    let selftest = { ok: false, error: `宿主原生绑定不可用（${nativeProblem ?? '未链接'}）` };
    if (native) {
      try {
        const entries = native.list('/var/mobile/Documents');
        selftest = { ok: true, count: entries.length, sample: entries.slice(0, 5).map((entry) => entry.name) };
      } catch (error) {
        selftest = { ok: false, error: String(error?.message ?? error) };
      }
    }
    await record({ stage: 'ready', ok: true, tools: Object.keys(handlers).length, selftest });
  } catch (error) {
    await record({ stage: 'failed', ok: false, error: String(error?.message ?? error) });
    throw error;
  }
}