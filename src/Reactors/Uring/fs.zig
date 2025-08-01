const std = @import("std");
const root = @import("zig_async");

const Runtime = root.Runtime;
const Reactor = root.Reactor;

const Uring = @import("./Uring.zig");
const ThreadContext = Uring.ThreadContext;
const Operation = Uring.Operation;
const errno = Uring.errno;

// Open file asynchronously
pub fn openFile(ctx: ?*anyopaque, exec: Reactor.Executer, path: []const u8, flags: Runtime.File.OpenFlags) Runtime.File.OpenError!Runtime.File {
    _ = ctx;
    _ = exec;
    var os_flags: std.posix.O = .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
    };

    if (@hasField(std.posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) os_flags.NOCTTY = !flags.allow_ctty;

    const fd = try std.posix.open(path, os_flags, 0);

    return .{
        .handle = fd,
    };
}

pub fn getStdIn(ctx: ?*anyopaque, exec: Reactor.Executer) Runtime.File {
    _ = ctx;
    _ = exec;
    return .{ .handle = std.os.linux.STDIN_FILENO };
}

// Async file read
pub fn pread(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []u8, offset: std.posix.off_t) Runtime.File.PReadError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    // Get SQE and operation from ring buffer
    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    var op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_read(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }
        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return @as(usize, @intCast(result)),
                .INTR => unreachable,
                .CANCELED => return error.Canceled,
                .INVAL => unreachable,
                .FAULT => unreachable,
                .NOENT => return error.ProcessNotFound,
                .AGAIN => return error.WouldBlock,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
}

// Async file write
pub fn pwrite(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []const u8, offset: std.posix.off_t) Runtime.File.PWriteError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    // Get SQE and operation from ring buffer
    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    var op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_write(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }
        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return @as(usize, @intCast(result)),
                .INTR => unreachable,
                .INVAL => unreachable,
                .FAULT => unreachable,
                .AGAIN => unreachable,
                .BADF => return error.NotOpenForWriting, // can be a race condition.
                .DESTADDRREQ => unreachable, // `connect` was never called.
                .DQUOT => return error.DiskQuota,
                .FBIG => return error.FileTooBig,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .PERM => return error.AccessDenied,
                .PIPE => return error.BrokenPipe,
                .NXIO => return error.Unseekable,
                .SPIPE => return error.Unseekable,
                .OVERFLOW => return error.Unseekable,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
}

// Close file
pub fn closeFile(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File) void {
    _ = ctx;
    _ = exec;
    std.posix.close(file.handle);
}
