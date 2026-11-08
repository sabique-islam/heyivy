#!/usr/bin/env node
// A stand-in for the Worker that misbehaves on purpose, for hardening tests (drawing plan, D7).
// It answers /chat with a short fixed script and /voice with a WebSocket, and each can be told
// to stall or drop. It calls nothing, costs nothing, and ignores the device token.
//
//   node scripts/fake-worker.mjs --port 8799 --chat normal|stall|drop --voice normal|silent|stall-midway|spend-limit
//
//   --chat normal         Streams the whole script, then ends.
//   --chat stall          Sends the first words, then goes quiet with the connection open.
//   --chat drop           Sends the first words, then cuts the connection.
//   --voice normal        Speaks the whole script as silent audio with timings, then finishes,
//                         so long runs like LessonLab's --soak cost nothing.
//   --voice silent        Accepts the WebSocket, then never sends anything.
//   --voice stall-midway  Sends half a second of silent audio with timings, then goes quiet.
//   --voice spend-limit   Closes with 4429, as the Worker does when a device is over its cap.
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
  // What the client sends is thrown away, except a close, which is answered as the real
  // Worker does. Pass --close ignore to leave it unanswered, as a lost network would.
  let unreadBytes = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    unreadBytes = Buffer.concat([unreadBytes, chunk]);
    while (unreadBytes.length >= 2) {
      const opcode = unreadBytes[0] & 0x0f;
      let payloadLength = unreadBytes[1] & 0x7f;
      let headerLength = 2;
      if (payloadLength === 126) {
        if (unreadBytes.length < 4) return;
        payloadLength = unreadBytes.readUInt16BE(2);
        headerLength = 4;
      } else if (payloadLength === 127) {
        if (unreadBytes.length < 10) return;
        payloadLength = Number(unreadBytes.readBigUInt64BE(2));
        headerLength = 10;
      }
      const maskLength = unreadBytes[1] & 0x80 ? 4 : 0;
      const frameLength = headerLength + maskLength + payloadLength;
      if (unreadBytes.length < frameLength) return;
      unreadBytes = unreadBytes.subarray(frameLength);
      if (opcode === 0x8 && options.close !== "ignore") {
        socket.end(Buffer.from([0x88, 0x02, 0x03, 0xe8]));
        return;
      }
    }
  });
  socket.on("error", () => {});
  if (options.voice === "normal") {
    // Each character takes 60 ms, about the pace of real speech.
    setTimeout(() => {
      const characters = [...scriptWords.join("")];
      const audio = Buffer.alloc(Math.round(characters.length * 0.06 * 24000) * 2);
      socket.write(
        textFrame(
          JSON.stringify({
            audio: audio.toString("base64"),
            alignment: {
              chars: characters,
              charStartTimesMs: characters.map((_, index) => index * 60),
              charDurationsMs: characters.map(() => 60),
            },
          }),
        ),
      );
      socket.write(textFrame(JSON.stringify({ isFinal: true })));
    }, 600);
  }
  if (options.voice === "spend-limit") {
    setTimeout(() => socket.end(Buffer.from([0x88, 0x02, 0x11, 0x4d])), 300);
  }
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
