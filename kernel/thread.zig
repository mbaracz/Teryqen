// Kernel threads with round robin over a simple queue. A thread runs until it
// calls yield() or exit(), or until the timer decides its time slice is over.
//
// Switching: push the callee-saved registers (rbx, rbp, r12-r15) on the old
// thread's stack, save its rsp, load the new thread's rsp, pop its registers,
// ret. A new thread gets a fake stack that "returns" into threadStart.

const std = @import("std");
const heap = @import("heap.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.thread);

const stack_size = 16 * 1024;
const slice_ticks = 2; // 20 ms at 100 Hz

pub const Thread = struct {
    id: u64,
    rsp: u64 = 0, // saved while not running
    stack: ?[]u8, // null for the boot thread, it runs on Limine's stack
    dead: bool = false,
    ticks_left: u32 = slice_ticks,
    node: std.DoublyLinkedList.Node = .{},
};

var boot_thread: Thread = .{ .id = 0, .stack = null };
var current: *Thread = &boot_thread;
var ready: std.DoublyLinkedList = .{};
var dead: std.DoublyLinkedList = .{}; // freed later, a thread can't free its own stack
var next_id: u64 = 1;

fn fromNode(node: *std.DoublyLinkedList.Node) *Thread {
    return @fieldParentPtr("node", node);
}

/// Starts a new thread running entry(arg). entry has to end with exit().
pub fn spawn(entry: *const fn (usize) callconv(.c) noreturn, arg: usize) !*Thread {
    const t = try heap.allocator.create(Thread);
    errdefer heap.allocator.destroy(t);
    const stack = try heap.allocator.alignedAlloc(u8, .@"16", stack_size);

    // Fake what switchStacks would have pushed, so the first switch to this
    // thread pops zeros and "returns" into threadStart (entry in r12, arg in r13).
    const top = @intFromPtr(stack.ptr) + stack_size;
    const frame: [*]u64 = @ptrFromInt(top - 7 * 8);
    frame[0] = 0; // r15
    frame[1] = 0; // r14
    frame[2] = arg; // r13
    frame[3] = @intFromPtr(entry); // r12
    frame[4] = 0; // rbp
    frame[5] = 0; // rbx
    frame[6] = @intFromPtr(&threadStart); // return address

    t.* = .{ .id = next_id, .rsp = top - 7 * 8, .stack = stack };
    next_id += 1;
    const irq = cpu.disableInterrupts();
    ready.append(&t.node);
    cpu.restoreInterrupts(irq);
    return t;
}

/// Let the next thread run. Comes back when it's our turn again.
pub fn yield() void {
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    const next = ready.popFirst() orelse return;
    ready.append(&current.node);
    switchTo(fromNode(next));
    freeDead();
}

pub fn exit() noreturn {
    _ = cpu.disableInterrupts();
    if (current == &boot_thread) @panic("the boot thread can't exit");
    current.dead = true;
    dead.append(&current.node);
    const next = ready.popFirst() orelse @panic("no thread left to run");
    switchTo(fromNode(next));
    unreachable;
}

/// Called from the timer interrupt (interrupts are off there). When the
/// current thread used up its slice and someone else is waiting, switch.
/// The interrupted thread continues later where it was, through iretq.
pub fn onTick() void {
    if (current.ticks_left > 0) current.ticks_left -= 1;
    if (current.ticks_left > 0) return;
    const next = ready.popFirst() orelse return;
    ready.append(&current.node);
    switchTo(fromNode(next));
    freeDead();
}

pub fn currentId() u64 {
    return current.id;
}

fn switchTo(next: *Thread) void {
    const prev = current;
    next.ticks_left = slice_ticks;
    current = next;
    asm volatile ("callq switchStacks"
        :
        : [from] "{rdi}" (&prev.rsp),
          [to] "{rsi}" (next.rsp),
        : .{ .rax = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .cc = true, .memory = true });
}

fn freeDead() void {
    while (dead.popFirst()) |node| {
        const t = fromNode(node);
        log.debug("thread {d} finished", .{t.id});
        heap.allocator.free(t.stack.?);
        heap.allocator.destroy(t);
    }
}

export fn switchStacks() callconv(.naked) void {
    asm volatile (
        \\pushq %%rbx
        \\pushq %%rbp
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\movq %%rsp, (%%rdi)
        \\movq %%rsi, %%rsp
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbp
        \\popq %%rbx
        \\retq
    );
}

// New threads start here. rbp = 0 so the backtrace stops here.
export fn threadStart() callconv(.naked) noreturn {
    asm volatile (
        \\sti
        \\xorl %%ebp, %%ebp
        \\movq %%r13, %%rdi
        \\callq *%%r12
        \\ud2
    );
}
