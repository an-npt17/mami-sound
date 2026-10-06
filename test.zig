pub fn render(self: *Noise, out: []f32, dev: i16, touched: bool) void {
    const sr = @as(f32, @floatFromInt(self.sample_rate));
    const rand = self.prng.random();


    const t = std.math.clamp(
        @as(f32, @floatFromInt(dev)) /
            @as(f32, @floatFromInt(@max(self.span, 1))),
        0.0,
        1.0,
    );

    const target_fc =
        freq_min *
        std.math.pow(
            f32,
            freq_max / freq_min,
            floor + (1.0 - floor) * t,
        );



    for (out) |*sample| {
        // Pitch: initial burst, then normal glide.
        if (touched and self.burst < 1.0) {
            self.burst = @min(
                1.0,
                self.burst + self.burst_step,
            );

            self.fc =
                freq_min *
                std.math.pow(
                    f32,
                    target_fc / freq_min,
                    self.burst,
                );
        } else {
            self.fc += (target_fc - self.fc) * alpha;
        }

        // Band-pass filtered white noise.
        const f =
            2.0 *
            @sin(std.math.pi * self.fc / sr);

        const input =
            rand.float(f32) * 2.0 - 1.0;

        self.low += f * self.band;

        const high =
            input -
            self.low -
            damping * self.band;

        self.band += f * high;

        // Volume envelope.
        if (self.env < gate_target) {
            self.env = @min(
                gate_target,
                self.env + self.gate_step,
            );
        } else if (self.env > gate_target) {
            self.env = @max(
                gate_target,
                self.env - self.gate_step,
            );
        }

        // Mix into output.
        sample.* += std.math.clamp(
            self.band *
                damping *
                makeup *
                self.env *
                voice_gain,
            -1.0,
            1.0,
        );
    }
}
