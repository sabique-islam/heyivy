#!/usr/bin/env node
// A stand-in for the Worker that misbehaves on purpose, for hardening tests (drawing plan, D7).
// It answers /chat with a short fixed script and /voice with a WebSocket, and each can be told
// to stall or drop. It calls nothing, costs nothing, and ignores the device token.
//
//   node scripts/fake-worker.mjs --port 8799 --chat normal|stall|drop --voice silent|stall-midway
//
//   --chat normal         Streams the whole script, then ends.
//   --chat stall          Sends the first words, then goes quiet with the connection open.
//   --chat drop           Sends the first words, then cuts the connection.
//   --voice silent        Accepts the WebSocket, then never sends anything.
//   --voice stall-midway  Sends half a second of silent audio with timings, then goes quiet.
//
// Point LessonLab at it with: scripts/lesson-lab.sh --worker http://127.0.0.1:8799
import http from "node:http";
import crypto from "node:crypto";

const options = { port: 8799, chat: "normal", voice: "silent" };
for (let index = 2; index < process.argv.length; index += 2) {
  options[process.argv[index].replace(/^--/, "")] = process.argv[index + 1];
}

const scriptWords = ["The loop ", "stops one short, ", "so the last score ", "is never added."];

function sendServerEvent(response, event) {
  response.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
}

function textDelta(text) {
  return { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } };
}

const server = http.createServer((request, response) => {
  if (request.method !== "POST" || request.url !== "/chat") {
    response.writeHead(404).end();
    return;
  }
  request.resume();
  request.on("end", () => {
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    sendServerEvent(response, { type: "message_start", message: { usage: { input_tokens: 1 } } });
    sendServerEvent(response, textDelta(scriptWords[0]));
    if (options.chat === "stall") return;
    if (options.chat === "drop") {
      setTimeout(() => request.socket.destroy(), 300);
      return;
    }
    for (const words of scriptWords.slice(1)) sendServerEvent(response, textDelta(words));
    sendServerEvent(response, { type: "message_delta", usage: { output_tokens: 20 } });
    sendServerEvent(response, { type: "message_stop" });
    response.end();
  });
});

// A server WebSocket frame: final, text, unmasked.
function textFrame(text) {
  const payload = Buffer.from(text);
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  return Buffer.concat([header, payload]);
}

server.on("upgrade", (request, socket) => {
  if (request.url !== "/voice") {
    socket.destroy();
    return;
  }
  const acceptKey = crypto
    .createHash("sha1")
    .update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${acceptKey}\r\n\r\n`,
  );
  // What the client sends is read and thrown away.
  socket.on("data", () => {});
  socket.on("error", () => {});
  if (options.voice === "stall-midway") {
    setTimeout(() => {
      const halfSecondOfSilence = Buffer.alloc(24000);
      const characters = [..."The loop "];
      socket.write(
        textFrame(
          JSON.stringify({
            audio: halfSecondOfSilence.toString("base64"),
            alignment: {
              chars: characters,
              charStartTimesMs: characters.map((_, index) => index * 50),
              charDurationsMs: characters.map(() => 50),
            },
          }),
        ),
      );
    }, 1500);
  }
});

server.listen(Number(options.port), "127.0.0.1", () => {
  console.log(`fake worker on http://127.0.0.1:${options.port}, chat ${options.chat}, voice ${options.voice}`);
});
