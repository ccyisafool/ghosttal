const std = @import("std");
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const objc = @import("objc");
const math = @import("../../math.zig");
const global = @import("../../global.zig");

const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.metal);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "bg_color_fragment",
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "cell_bg_fragment",
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = "cell_text_vertex",
            .fragment_fn = "cell_text_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "cursor", .{
            .vertex_attributes = CursorQuad,
            .vertex_fn = "cursor_vertex",
            .fragment_fn = "cursor_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "input_glyph", .{
            .vertex_attributes = InputGlyphQuad,
            .vertex_fn = "input_glyph_vertex",
            .fragment_fn = "input_glyph_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = "image_vertex",
            .fragment_fn = "image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = "bg_image_vertex",
            .fragment_fn = "bg_image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: []const u8,
    fragment_fn: []const u8,
    step_fn: mtl.MTLVertexStepFunction = .per_vertex,
    blending_enabled: bool,

    fn initPipeline(
        self: PipelineDescription,
        device: objc.Object,
        library: objc.Object,
        pixel_format: mtl.MTLPixelFormat,
    ) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .device = device,
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .vertex_library = library,
            .fragment_library = library,
            .step_fn = self.step_fn,
            .attachments = &.{.{
                .pixel_format = pixel_format,
                .blending_enabled = self.blending_enabled,
            }},
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    const StructField = std.builtin.Type.StructField;

    var names: [pipeline_descs.len][]const u8 = undefined;
    var types = [_]type{Pipeline} ** pipeline_descs.len;
    var attrs = [_]StructField.Attributes{.{ .@"align" = @alignOf(Pipeline) }} ** pipeline_descs.len;

    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};

/// This contains the state for the shaders used by the Metal renderer.
pub const Shaders = struct {
    library: objc.Object,

    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        device: objc.Object,
        post_shaders: []const [:0]const u8,
        pixel_format: mtl.MTLPixelFormat,
    ) !Shaders {
        const library = try initLibrary(device);
        errdefer library.msgSend(void, objc.sel("release"), .{});

        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(
                device,
                library,
                pixel_format,
            );
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            device,
            library,
            post_shaders,
            pixel_format,
        ) catch |err| err: {
            // If an error happens while building postprocess shaders we
            // want to just not use any postprocess shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .library = library,
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }
        self.library.msgSend(void, objc.sel("release"), .{});

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    // Note: all of the explicit alignments are copied from the
    // MSL developer reference just so that we can be sure that we got
    // it all exactly right.

    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(1),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans.
    ///
    /// TODO: Maybe put these in a packed struct, like for OpenGL.
    bools: extern struct {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool align(1),

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool align(1),

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Metal itself will re-encode the colors for storage.
        use_linear_blending: bool align(1),

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool align(1) = false,
    },

    const PaddingExtend = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u4 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    test {
        // Minimizing the size of this struct is important,
        // so we test it in order to be aware of any changes.
        try std.testing.expectEqual(32, @sizeOf(CellText));
    }
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the animated cursor shader ("cursor motion").
///
/// Unlike `CellText`, this quad is positioned in free-floating pixels
/// instead of being snapped to a grid cell, which is what lets the cursor
/// be drawn part way between two cells. The glyph is stretched to fill the
/// quad, so a block cursor scales cleanly and a bar or underline stretches
/// along the direction of travel.
///
/// Cursor sprites always live in the grayscale atlas, so unlike `CellText`
/// there's no atlas selector and no color atlas to sample.
pub const CursorQuad = extern struct {
    /// Top-left corner of the quad in pixels, in the same space as
    /// `cell_size * grid_pos` in the other shaders: relative to the
    /// top-left of the grid, with the window padding applied afterwards
    /// by the projection matrix.
    pos: [2]f32 align(8),

    /// Size of the quad in pixels.
    size: [2]f32 align(8),

    /// Orthonormal-ish pixel-space basis for the quad. Normal cursor heads
    /// use (1, 0), (0, 1); motion trails use a basis aligned to travel.
    basis_x: [2]f32 align(8),
    basis_y: [2]f32 align(8),

    /// The position of the glyph in the grayscale atlas (x, y).
    glyph_pos: [2]u32 align(8),

    /// The size of the glyph in the grayscale atlas (w, h).
    glyph_size: [2]u32 align(8),

    /// The cursor color. The alpha channel carries the configured cursor
    /// opacity and, for the trail quad, its fade.
    color: [4]u8 align(4),
};

/// A free-floating text glyph used only while a confirmed local echo rises
/// into its final cell. Kept separate from CellText so steady-state terminal
/// data stays compact and its ABI remains stable.
pub const InputGlyphQuad = extern struct {
    pos: [2]f32 align(8),
    glyph_pos: [2]u32 align(8),
    glyph_size: [2]u32 align(8),
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: CellText.Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        _padding: u7 = 0,
    } align(1) = .{},
    opacity: u8 align(1) = 255,
    /// Pixel extent of the free-floating quad. This is independent from the
    /// atlas rectangle so decay can shrink a complete glyph without cropping
    /// its texture coordinates.
    draw_size: [2]f32 align(8),

    test {
        try std.testing.expectEqual(48, @sizeOf(InputGlyphQuad));
        try std.testing.expectEqual(0, @offsetOf(InputGlyphQuad, "pos"));
        try std.testing.expectEqual(8, @offsetOf(InputGlyphQuad, "glyph_pos"));
        try std.testing.expectEqual(16, @offsetOf(InputGlyphQuad, "glyph_size"));
        try std.testing.expectEqual(24, @offsetOf(InputGlyphQuad, "grid_pos"));
        try std.testing.expectEqual(28, @offsetOf(InputGlyphQuad, "color"));
        try std.testing.expectEqual(32, @offsetOf(InputGlyphQuad, "atlas"));
        try std.testing.expectEqual(33, @offsetOf(InputGlyphQuad, "bools"));
        try std.testing.expectEqual(34, @offsetOf(InputGlyphQuad, "opacity"));
        try std.testing.expectEqual(40, @offsetOf(InputGlyphQuad, "draw_size"));
    }
};

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

/// Initialize the MTLLibrary. A MTLLibrary is a collection of shaders.
fn initLibrary(device: objc.Object) !objc.Object {
    const start: std.Io.Timestamp = .now(global.io(), .awake);

    const data = try macos.dispatch.Data.create(
        @embedFile("ghostty_metallib"),
        macos.dispatch.queue.getMain(),
        macos.dispatch.Data.DESTRUCTOR_DEFAULT,
    );
    defer data.release();

    var err: ?*anyopaque = null;
    const library = device.msgSend(
        objc.Object,
        objc.sel("newLibraryWithData:error:"),
        .{
            data,
            &err,
        },
    );
    try checkError(err);

    log.debug("shader library loaded time={}us", .{start.untilNow(global.io(), .awake).toMicroseconds()});

    return library;
}

/// Initialize our custom shader pipelines.
///
/// The shaders argument is a set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    device: objc.Object,
    library: objc.Object,
    shaders: []const [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(
            device,
            library,
            source,
            pixel_format,
        );
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(
    device: objc.Object,
    library: objc.Object,
    data: [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) !Pipeline {
    // Create our library which has the shader source
    const post_library = library: {
        const source = try macos.foundation.String.createWithBytes(
            data,
            .utf8,
            false,
        );
        defer source.release();

        var err: ?*anyopaque = null;
        const post_library = device.msgSend(
            objc.Object,
            objc.sel("newLibraryWithSource:options:error:"),
            .{ source, @as(?*anyopaque, null), &err },
        );
        try checkError(err);
        errdefer post_library.msgSend(void, objc.sel("release"), .{});

        break :library post_library;
    };
    defer post_library.msgSend(void, objc.sel("release"), .{});

    return try Pipeline.init(null, .{
        .device = device,
        .vertex_fn = "full_screen_vertex",
        .fragment_fn = "main0",
        .vertex_library = library,
        .fragment_library = post_library,
        .attachments = &.{
            .{
                .pixel_format = pixel_format,
                .blending_enabled = false,
            },
        },
    });
}

fn checkError(err_: ?*anyopaque) !void {
    const nserr = objc.Object.fromId(err_ orelse return);
    const str = @as(
        *macos.foundation.String,
        @ptrCast(nserr.getProperty(?*anyopaque, "localizedDescription").?),
    );

    log.err("metal error={s}", .{str.cstringPtr(.ascii).?});
    return error.MetalFailed;
}
