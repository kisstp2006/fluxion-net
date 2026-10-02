// SPDX-License-Identifier: BSD-2-Clause
//
// The other side of `Client.zig` in a browser: each request is the page's own
// `fetch`. Installed beside a program as `fluxion-net.js` - one file, no
// dependencies, no build step - and handed to the platform's glue with the
// others:
//
//   import { Platform } from "./fluxion-platform.js";
//   import { Net } from "./fluxion-net.js";
//
//   await new Platform({ canvas }).run("./game.wasm", { with: [new Net()] });
//
// A request runs as the page's, while the module goes on; the module asks how
// it is doing once a frame and copies the answer out when there is one. The
// browser's rules hold: another site answers only if it allows this page to
// ask it (CORS), and the browser sends its own user agent.

/// What `state` answers: `State` in `Client.zig`.
const STATE = { running: 0, answered: 1, badUrl: 2, connect: 3, cancelled: 4, broken: 5 };

export class Net {
  constructor() {
    // Slot 0 is no request.
    this.fetches = [null];
    this.free = [];
    this.memory = null;
    this.decoder = new TextDecoder();
    this.encoder = new TextEncoder();
  }

  /// The module's bytes from `ptr`, read at once: its memory may grow and
  /// move them by the next call.
  bytes(ptr, len) {
    return new Uint8Array(this.memory.buffer, ptr, len);
  }

  text(ptr, len) {
    return len === 0 ? "" : this.decoder.decode(this.bytes(ptr, len));
  }

  /// Every import `Client.zig` declares, under `fluxion_net`.
  imports() {
    const at = (id) => this.fetches[id];
    return {
      fluxion_net: {
        start: (method, methodLen, url, urlLen, headers, headersLen, body, bodyLen, follow) =>
          this.start(
            this.text(method, methodLen),
            this.text(url, urlLen),
            this.text(headers, headersLen),
            bodyLen === 0 ? null : this.bytes(body, bodyLen).slice(),
            follow !== 0,
          ),
        state: (id) => at(id)?.state ?? STATE.broken,
        received: (id) => at(id)?.received ?? 0,
        total: (id) => at(id)?.total ?? -1,
        status: (id) => at(id)?.status ?? 0,
        headersLength: (id) => at(id)?.head.length ?? 0,
        bodyLength: (id) => at(id)?.body?.length ?? 0,
        copy: (id, headers, body) => {
          const fetched = at(id);
          if (!fetched) return;
          if (fetched.head.length > 0) this.bytes(headers, fetched.head.length).set(fetched.head);
          if (fetched.body?.length > 0) this.bytes(body, fetched.body.length).set(fetched.body);
        },
        cancel: (id) => at(id)?.controller.abort(),
        release: (id) => {
          const fetched = at(id);
          if (!fetched) return;
          fetched.controller.abort();
          this.fetches[id] = null;
          this.free.push(id);
        },
      },
    };
  }

  start(method, url, headerLines, body, follow) {
    const fetched = {
      state: STATE.running,
      received: 0,
      total: -1,
      status: 0,
      head: new Uint8Array(0),
      body: null,
      controller: new AbortController(),
    };
    const id = this.free.length > 0 ? this.free.pop() : this.fetches.length;
    this.fetches[id] = fetched;
    this.run(fetched, method, url, headerLines, body, follow);
    return id;
  }

  async run(fetched, method, url, headerLines, body, follow) {
    let headers;
    try {
      new URL(url);
      headers = new Headers();
      for (const line of headerLines.split("\n")) {
        const colon = line.indexOf(":");
        if (colon > 0) headers.append(line.slice(0, colon), line.slice(colon + 1).trim());
      }
    } catch {
      fetched.state = STATE.badUrl;
      return;
    }
    try {
      const response = await fetch(url, {
        method,
        headers,
        body,
        redirect: follow ? "follow" : "error",
        signal: fetched.controller.signal,
      });
      fetched.status = response.status;
      const length = response.headers.get("content-length");
      if (length !== null) fetched.total = Number(length);
      let head = "";
      response.headers.forEach((value, name) => {
        head += `${name}: ${value}\n`;
      });
      fetched.head = this.encoder.encode(head);

      const chunks = [];
      if (response.body) {
        const reader = response.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(value);
          fetched.received += value.length;
        }
      }
      const whole = new Uint8Array(fetched.received);
      let at = 0;
      for (const chunk of chunks) {
        whole.set(chunk, at);
        at += chunk.length;
      }
      fetched.body = whole;
      fetched.state = STATE.answered;
    } catch (error) {
      if (error.name === "AbortError") {
        fetched.state = STATE.cancelled;
      } else if (fetched.status !== 0) {
        fetched.state = STATE.broken;
      } else {
        // The browser says no more than this to a page, on purpose: a host
        // not found, refused and not allowed all look the same from here.
        console.warn(`fluxion-net: ${method} ${url}: ${error.message}`);
        fetched.state = STATE.connect;
      }
    }
  }
}
