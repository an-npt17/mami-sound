const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");
const production_config = @import("production_config.zig");

pub const Engine = struct {
    selection: core.plant.Selection,
    probe: ports.ProbeSource,
    sink: ports.AudioSink,
    status: ports.StatusSink,
    machine: core.touch.Machine,
    drone: core.noise.Noise,
    plant_b: core.plant_b.ClipPlayer,
    block: [core.block_frames]f32,
    pcm: [core.block_frames]i16,
    rendered: usize,

    pub fn init(
        selection: core.plant.Selection,
        probe: ports.ProbeSource,
        sink: ports.AudioSink,
        status: ports.StatusSink,
        clip_pool: []const []const f32,
        random: std.Random,
    ) Engine {
        return .{
            .selection = selection,
            .probe = probe,
            .sink = sink,
            .status = status,
            .machine = core.touch.Machine.init(production_config.touch),
            .drone = core.noise.Noise.init(
                core.sample_rate,
                production_config.seed,
                production_config.drone,
            ),
            .plant_b = core.plant_b.ClipPlayer.init(clip_pool, random),
            .block = undefined,
            .pcm = undefined,
            .rendered = 0,
        };
    }

    pub fn step(self: *Engine) !void {
        @memset(&self.block, 0);
        var raw_a: i16 = 0;
        var raw_bc: i16 = 0;
        var state: core.touch.State = .none;
        var touched: core.plant.Selection = undefined;

        var offset: usize = 0;
        while (offset < self.block.len) : (offset += core.sensor_frames) {
            const piece = self.block[offset..][0..core.sensor_frames];
            const reading = self.probe.read(core.sensor_frames);
            raw_a = reading.raw_a;
            raw_bc = reading.raw_bc;
            const detected = self.machine.update(raw_a, raw_bc);
            touched = core.select.apply(self.selection, .{
                detected == .plant_a or detected == .both,
                detected == .plant_bc or detected == .both,
            });
            state = detected;
            if (self.selection[0]) {
                self.drone.render(piece, self.machine.a.deviation(), touched[0]);
            }
            self.plant_b.render(piece, self.selection[1] and touched[1]);
        }

        core.pcm.toPcm(&self.block, &self.pcm);
        try self.sink.write(&self.pcm);
        self.rendered += core.block_frames;
        self.status.observe(.{
            .raw_a = raw_a,
            .raw_bc = raw_bc,
            .z_a = self.machine.a.z,
            .z_bc = self.machine.bc.z,
            .state = state,
            .touched = touched,
            .block = &self.block,
            .rendered = self.rendered,
        });
    }

    pub fn run(self: *Engine) !void {
        while (true) try self.step();
    }
};
