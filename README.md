# Fluxion Net

Web requests for games and the tools around them, in Zig.

A game asks a web API for its scores, its trophies or a file, and must not stop while the answer comes. Here each request runs on a thread of its own, a few at a time, and the answers are collected on the thread that asked, once a frame. A game's loop never waits for the network.

HTTPS goes over the standard library's client and TLS, with the system's trusted certificates (Windows, Linux, Android). Plain HTTP is refused unless the client is told to allow it: a game's requests carry keys and scores.

## Use

```zig
const net = @import("fluxion_net");

var client: net.Client = .init(gpa, io, .{});
defer client.deinit();

const scores = try client.send(.{ .url = "https://api.example.com/scores?game=1&signature=..." });
const level = try client.send(.{ .url = "https://example.com/level2.bin", .save_to = "C:/Users/me/AppData/Roaming/game/level2.bin" });

// Each frame:
var done: [8]net.Done = undefined;
for (client.update(&done)) |*d| {
    defer d.deinit();
    const answer = d.result catch |err| {
        std.log.warn("{t}: {s}", .{ err, d.reason });
        continue;
    };
    if (d.id == scores) show(answer.status, answer.body);
}
if (client.progress(level)) |p| bar(p.received, p.total);
```

## Pieces

| | What it is |
| --- | --- |
| `Client` | Sends, keeps what is on its way, and gives what has ended. `send`, `update` once a frame, `cancel`, `progress`, `pending`. |
| `Request` | Its method, URL, headers, body and its type, how long it may take (`timeout_ms`, 30 s), the longest body it takes into memory (`max_body`, 64 MiB), how many redirects it follows, and `save_to` for a file. |
| `Response` | Its status (a 404 is an answer, not a failure), headers, `header(name)`, body, and size. |
| `Done` | A request that has ended: its `id`, its `Response` or its `Error`, and `reason`, the system's own word for what failed. |
| `Error` | `BadUrl`, `NotSecure`, `Dns`, `Connect`, `Tls`, `Timeout`, `Cancelled`, `TooLarge`, `Broken`, `CannotSave`. |

A URL goes out as it is written: its path and query are not encoded again, so a request signed over its URL arrives with the URL it was signed over.

A body saved to a file is written as `<path>.part` and renamed when it is whole; its folders are made. A file at the path is never half of one. Only a success is saved: any other answer's body - a 404's page - is read into memory, to say why.

`Options.max_running` (4) is how many requests are on their way at once; the rest wait their turn, in the order they were sent. With no thread to give it, a request runs where it is sent.

## In a browser

Built for `wasm32-wasi`, a request is the page's own `fetch`, and the same calls ask and collect. `src/fluxion-net.js` is the page's half - a dependant takes it from the build as `dep.namedLazyPath("fluxion-net.js")` and installs it beside its module - and it is one more glue for the platform's:

```js
import { Platform } from "./fluxion-platform.js";
import { Net } from "./fluxion-net.js";

await new Platform({ canvas }).run("./game.wasm", { with: [new Net()] });
```

The page's rules hold there. Another site answers only if it allows this page to ask it (CORS), and a refusal looks to the page like a host that cannot be reached: `Connect`, with the browser's own word in its console. The browser sends its own user agent. A request with a body follows no redirect, as anywhere, but one is a failure (`Broken`) rather than an answer. A file saved to is written whole once the answer is, into the program's own files.

## Tests

`zig build test` runs the client against a server on this machine: answers, statuses, redirects, a URL kept as it was written, a body and its type, plain HTTP refused, what takes too long, what is too large, what is cancelled before it starts, and a file saved whole.

## Licence

BSD 2-Clause. See [LICENSE](LICENSE).
