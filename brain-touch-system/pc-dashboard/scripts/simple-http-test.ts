import http from "node:http";
import os from "node:os";

const PORT = Number(process.env.HTTP_TEST_PORT ?? 8000);

function getLocalIPv4Addresses() {
  return Object.values(os.networkInterfaces())
    .flatMap((networkInterface) => networkInterface ?? [])
    .filter((address) => address.family === "IPv4" && !address.internal)
    .map((address) => address.address);
}

const server = http.createServer((request, response) => {
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  console.log(`[http-test] ${remote} ${request.method ?? "UNKNOWN"} ${request.url ?? "/"}`);

  response.writeHead(200, {
    "Cache-Control": "no-store",
    "Content-Type": "text/plain; charset=utf-8"
  });
  response.end(`ok from mac\nremote=${remote}\ntime=${new Date().toISOString()}\n`);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Simple HTTP test server listening on 0.0.0.0:${PORT}`);
  for (const address of getLocalIPv4Addresses()) {
    console.log(`Try on iPhone Safari: http://${address}:${PORT}/`);
  }
});

server.on("error", (error) => {
  console.error("[http-test] server error", error);
  process.exitCode = 1;
});
