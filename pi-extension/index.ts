import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { chmod, mkdir, rm, writeFile } from "node:fs/promises";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import { join, resolve } from "node:path";

const MAX_REQUEST_BYTES = 256 * 1024;

function runtimeDir(): string {
	const xdg = process.env.XDG_RUNTIME_DIR;
	return xdg && xdg.length > 0
		? join(xdg, "pi-nvim")
		: `/tmp/pi-nvim-${process.getuid?.() ?? "unknown"}`;
}

function send(socket: Socket, response: Record<string, unknown>): void {
	socket.end(`${JSON.stringify(response)}\n`);
}

export default function piNvimExtension(pi: ExtensionAPI) {
	let server: Server | undefined;
	let socketPath: string | undefined;
	let metadataPath: string | undefined;
	const clients = new Set<Socket>();
	const notificationSockets = new Set<string>();

	function notifyFileChanged(path: string): void {
		const message = `${JSON.stringify({ version: 1, type: "file_changed", path })}\n`;
		for (const notificationSocket of notificationSockets) {
			const client = createConnection(notificationSocket);
			client.on("connect", () => client.end(message));
			client.on("error", () => {
				client.destroy();
				notificationSockets.delete(notificationSocket);
			});
		}
	}

	async function stopServer(): Promise<void> {
		for (const client of clients) client.destroy();
		clients.clear();

		const activeServer = server;
		server = undefined;
		if (activeServer) {
			await new Promise<void>((resolve) => activeServer.close(() => resolve()));
		}

		await Promise.all([
			socketPath ? rm(socketPath, { force: true }) : Promise.resolve(),
			metadataPath ? rm(metadataPath, { force: true }) : Promise.resolve(),
		]);
		socketPath = undefined;
		metadataPath = undefined;
	}

	pi.on("session_start", async (_event, ctx) => {
		await stopServer();
		if (process.env.PI_NVIM_SOCKET) notificationSockets.add(process.env.PI_NVIM_SOCKET);

		const dir = runtimeDir();
		await mkdir(dir, { recursive: true, mode: 0o700 });
		await chmod(dir, 0o700);

		socketPath = join(dir, `${process.pid}.sock`);
		metadataPath = join(dir, `${process.pid}.json`);
		await rm(socketPath, { force: true });

		server = createServer((client) => {
			clients.add(client);
			let input = "";
			let handled = false;

			client.setEncoding("utf8");
			client.on("close", () => clients.delete(client));
			client.on("error", () => clients.delete(client));
			client.on("data", (chunk: string) => {
				if (handled) return;
				input += chunk;
				if (Buffer.byteLength(input) > MAX_REQUEST_BYTES) {
					handled = true;
					send(client, { ok: false, error: "request too large" });
					return;
				}

				const newline = input.indexOf("\n");
				if (newline === -1) return;
				handled = true;

				try {
					const request = JSON.parse(input.slice(0, newline)) as {
						version?: unknown;
						message?: unknown;
						notificationSocket?: unknown;
					};
					if (request.version !== 1 || typeof request.message !== "string" || request.message.trim() === "") {
						send(client, { ok: false, error: "invalid request" });
						return;
					}

					if (typeof request.notificationSocket === "string" && request.notificationSocket.length > 0) {
						notificationSockets.add(request.notificationSocket);
					}

					const queued = !ctx.isIdle();
					if (queued) {
						pi.sendUserMessage(request.message, { deliverAs: "followUp" });
					} else {
						pi.sendUserMessage(request.message);
					}
					send(client, { ok: true, queued });
				} catch (error) {
					send(client, {
						ok: false,
						error: error instanceof Error ? error.message : String(error),
					});
				}
			});
		});

		server.on("error", (error) => {
			if (ctx.hasUI) ctx.ui.notify(`pi-nvim socket error: ${error.message}`, "error");
		});

		await new Promise<void>((resolve, reject) => {
			server!.once("error", reject);
			server!.listen(socketPath!, () => {
				server!.off("error", reject);
				resolve();
			});
		});
		await chmod(socketPath, 0o600);

		const metadata = {
			version: 1,
			pid: process.pid,
			socket: socketPath,
			cwd: ctx.cwd,
			updatedAt: Date.now(),
		};
		await writeFile(metadataPath, JSON.stringify(metadata), { mode: 0o600 });
		await chmod(metadataPath, 0o600);
	});

	pi.on("tool_result", (event, ctx) => {
		if (!event.isError && (event.toolName === "edit" || event.toolName === "write")) {
			const input = event.input as { path?: unknown };
			if (typeof input.path === "string") notifyFileChanged(resolve(ctx.cwd, input.path.replace(/^@/, "")));
		}
	});

	pi.on("session_shutdown", async () => {
		await stopServer();
	});
}
