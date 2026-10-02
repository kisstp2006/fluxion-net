// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Net: web requests for games and the tools around them. HTTPS
//! over the standard library's client and TLS, with the system's trusted
//! certificates; each request on a thread of its own, a few at a time, its
//! answer collected once a frame; a body into memory or into a file.

pub const Client = @import("Client.zig");
pub const Request = Client.Request;
pub const Response = Client.Response;
pub const Header = Client.Header;
pub const Error = Client.Error;
pub const Done = Client.Done;
pub const Id = Client.Id;
pub const Progress = Client.Progress;

test {
    _ = @import("client_test.zig");
}
