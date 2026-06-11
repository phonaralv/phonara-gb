import { spawn } from 'node:child_process';

const app = process.argv[2];
const port = process.argv[3];

if ((app !== 'web' && app !== 'admin') || !port) {
  process.stderr.write('Usage: tsx scripts/e2e-dev-server.ts <web|admin> <port>\n');
  process.exit(1);
}

function runBun(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(toCommand(['bun', ...args]), {
      stdio: 'inherit',
      shell: true,
    });

    child.once('exit', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`bun ${args.join(' ')} exited with ${code ?? 'unknown'}`));
    });
    child.once('error', reject);
  });
}

function toCommand(parts: string[]): string {
  return parts
    .map((part) => (part.includes(' ') || part.includes('*') ? `"${part.replaceAll('"', '\\"')}"` : part))
    .join(' ');
}

await runBun(['run', 'build:packages']);

const server = spawn(
  toCommand([
    'bun',
    'run',
    `dev:${app}`,
    '--',
    '--host',
    '127.0.0.1',
    '--port',
    port,
    '--strictPort',
  ]),
  {
    stdio: 'inherit',
    shell: true,
  },
);

const stop = (): void => {
  if (!server.killed) server.kill('SIGTERM');
};

process.once('SIGINT', stop);
process.once('SIGTERM', stop);

server.once('exit', (code) => {
  process.exit(code ?? 0);
});
server.once('error', (error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});
