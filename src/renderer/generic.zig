const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const wuffs = @import("wuffs");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const inputpkg = @import("../input.zig");
const os = @import("../os/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const cellpkg = @import("cell.zig");
const motionpkg = @import("cursor_motion.zig");
const inputmotion = @import("input_motion.zig");
const noMinContrast = cellpkg.noMinContrast;
const constraintWidth = cellpkg.constraintWidth;
const isCovering = cellpkg.isCovering;
const rowNeverExtendBg = @import("row.zig").neverExtendBg;
const Overlay = @import("Overlay.zig");
const imagepkg = @import("image.zig");
const ImageState = imagepkg.State;
const shadertoy = @import("shadertoy.zig");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;
const Health = renderer.Health;
const compat_file = @import("../lib/compat/file.zig");

const getConstraint = @import("../font/nerd_font_attributes.zig").getConstraint;

const FileType = @import("../file_type.zig").FileType;

const macos = switch (builtin.os.tag) {
    .macos => @import("macos"),
    else => void,
};

const DisplayLink = switch (builtin.os.tag) {
    .macos => *macos.video.DisplayLink,
    else => void,
};

const log = std.log.scoped(.generic_renderer);

/// Map the `cursor-motion` config value on to an animation style. Returns
/// null for `none`, which means cursor motion is disabled entirely and the
/// cursor stays in the shared cell_text pipeline.
fn cursorMotionStyle(v: configpkg.CursorMotion) ?motionpkg.Style {
    return switch (v) {
        .none => null,
        .ease => .ease,
        .spring => .spring,
        .smear => .smear,
        .squash => .squash,
    };
}

/// The pixel rect that a cursor `CellText` instance occupies, in the same
/// top-left space that the vertex shaders compute from `cell_size *
/// grid_pos`: relative to the top-left of the grid, with the window padding
/// applied afterwards by the projection matrix.
///
/// This mirrors the bearing math in `cell_text_vertex`. The X bearing is
/// the offset from the left of the cell, and the Y bearing is measured from
/// the *bottom* of the cell up to the top of the glyph, so the top edge of
/// the glyph is `cell_height - bearing_y` below the top of the cell.
///
/// A wide cursor needs no special handling here: `addCursor` rasterizes the
/// sprite at two cells wide, so the width is already in `glyph_size`.
///
/// `cell` is duck-typed because each graphics API has its own `CellText`.
fn cursorCellRect(cell: anytype, metrics: font.Metrics) motionpkg.Rect {
    const cell_width: f32 = @floatFromInt(metrics.cell_width);
    const cell_height: f32 = @floatFromInt(metrics.cell_height);
    const bearing_x: f32 = @floatFromInt(cell.bearings[0]);
    const bearing_y: f32 = @floatFromInt(cell.bearings[1]);
    return .{
        .pos = .{
            (@as(f32, @floatFromInt(cell.grid_pos[0])) * cell_width) +
                bearing_x,
            (@as(f32, @floatFromInt(cell.grid_pos[1])) * cell_height) +
                (cell_height - bearing_y),
        },
        .size = .{
            @floatFromInt(cell.glyph_size[0]),
            @floatFromInt(cell.glyph_size[1]),
        },
    };
}

/// The cell whose text should use the block-cursor foreground color once an
/// animated block cursor has arrived. While the cursor is between cells we
/// deliberately leave this unset in the shader: there is no single cell that
/// is visually under the free-floating cursor quad.
const CursorTextTarget = struct {
    pos: [2]u16,
    wide: bool,
};

/// A moving block cursor must not recolor its destination text early. Once
/// the cursor is resting (including an explicit snap), restore the legacy
/// block-cursor text behavior at its target cell.
fn cursorTextInversionTarget(
    target: ?CursorTextTarget,
    animating: bool,
) ?CursorTextTarget {
    return if (animating) null else target;
}

/// Create a renderer type with the provided graphics API wrapper.
///
/// The graphics API wrapper must provide the interface outlined below.
/// Specific details for the interfaces are documented on the existing
/// implementations (`Metal` and `OpenGL`).
///
/// Hierarchy of graphics abstractions:
///
/// [ GraphicsAPI ] - Responsible for configuring the runtime surface
///    |     |        and providing render `Target`s that draw to it,
///    |     |        as well as `Frame`s and `Pipeline`s.
///    |     V
///    | [ Target ] - Represents an abstract target for rendering, which
///    |              could be a surface directly but is also used as an
///    |              abstraction for off-screen frame buffers.
///    V
/// [ Frame ] - Represents the context for drawing a given frame,
///    |        provides `RenderPass`es for issuing draw commands
///    |        to, and reports the frame health when complete.
///    V
/// [ RenderPass ] - Represents a render pass in a frame, consisting of
///   :              one or more `Step`s applied to the same target(s),
/// [ Step ] - - - - each describing the input buffers and textures and
///   :              the vertex/fragment functions and geometry to use.
///   :_ _ _ _ _ _ _ _ _ _/
///   v
/// [ Pipeline ] - Describes a vertex and fragment function to be used
///                for a `Step`; the `GraphicsAPI` is responsible for
///                these and they should be constructed and cached
///                ahead of time.
///
/// [ Buffer ] - An abstraction over a GPU buffer.
///
/// [ Texture ] - An abstraction over a GPU texture.
///
pub fn Renderer(comptime GraphicsAPI: type) type {
    return struct {
        const Self = @This();

        pub const API = GraphicsAPI;

        const Target = GraphicsAPI.Target;
        const Buffer = GraphicsAPI.Buffer;
        const Sampler = GraphicsAPI.Sampler;
        const Texture = GraphicsAPI.Texture;
        const RenderPass = GraphicsAPI.RenderPass;

        const shaderpkg = GraphicsAPI.shaders;
        const Shaders = shaderpkg.Shaders;

        /// Allocator that can be used
        alloc: std.mem.Allocator,

        /// This mutex must be held whenever any state used in `drawFrame` is
        /// being modified, and also when it's being accessed in `drawFrame`.
        draw_mutex: std.Io.Mutex = .init,

        /// The configuration we need derived from the main config.
        config: DerivedConfig,

        /// The mailbox for communicating with the window.
        surface_mailbox: apprt.surface.Mailbox,

        /// Current font metrics defining our grid.
        grid_metrics: font.Metrics,

        /// The size of everything.
        size: renderer.Size,

        /// True if the window is focused
        focused: bool,

        /// True if the window is visible.
        visible: bool,

        /// Flag to indicate that our focus state changed for custom
        /// shaders to update their state.
        custom_shader_focused_changed: bool = false,

        /// The most recent scrollbar state. We use this as a cache to
        /// determine if we need to notify the apprt that there was a
        /// scrollbar change.
        scrollbar: terminal.Scrollbar,
        scrollbar_dirty: bool,

        /// Tracks the last bottom-right pin of the screen to detect new output.
        /// When the final line changes (node or y differs), new content was added.
        /// Used for scroll-to-bottom on output feature.
        last_bottom_node: ?usize,
        last_bottom_y: terminal.size.CellCountInt,

        /// The most recent viewport matches so that we can render search
        /// matches in the visible frame. This is provided asynchronously
        /// from the search thread so we have the dirty flag to also note
        /// if we need to rebuild our cells to include search highlights.
        ///
        /// Note that the selections MAY BE INVALID (point to PageList nodes
        /// that do not exist anymore). These must be validated prior to use.
        search_matches: ?renderer.Message.SearchMatches,
        search_selected_match: ?renderer.Message.SearchMatch,
        search_matches_dirty: bool,

        /// The current set of cells to render. This is rebuilt on every frame
        /// but we keep this around so that we don't reallocate. Each set of
        /// cells goes into a separate shader.
        cells: cellpkg.Contents,

        /// Set to true after rebuildCells is called. This can be used
        /// to determine if any possible changes have been made to the
        /// cells for the draw call.
        cells_rebuilt: bool = false,

        /// The current GPU uniform values.
        uniforms: shaderpkg.Uniforms,

        /// Animated cursor state. Inert unless `cursor-motion` is set to
        /// something other than `none`. See `CursorMotionState`.
        cursor_motion: CursorMotionState,

        /// The only cursor-motion state read by the render-thread scheduler
        /// without `draw_mutex`. All detailed animation state stays behind
        /// that mutex; this atomic is published after each retarget/sample.
        cursor_motion_active: std.atomic.Value(bool) = .init(false),

        /// Set while the one-shot local-echo glyph needs draw-only pump
        /// frames. Like cursor_motion_active this is deliberately atomic:
        /// the render thread reads it without draw_mutex.
        input_motion_active: std.atomic.Value(bool) = .init(false),

        /// Kept as an overlay until its row next rebuilds, so the final
        /// steady glyph is never drawn twice.
        input_glyph_motion: ?struct {
            quad: ?shaderpkg.InputGlyphQuad = null,
            /// Accessibility/config cancellation retains the withheld glyph
            /// as a static overlay until its normal row rebuild restores
            /// CellText. It must never simply disappear.
            force_static: bool = false,
            start: std.Io.Timestamp,
            generation: u64,
            row: u16,
            col: u16,
        } = null,

        /// Retained pre-delete glyph plus a tiny, bounded afterimage fan.
        /// This is deliberately separate from CellText: the terminal row is
        /// rebuilt normally underneath it as soon as local echo arrives.
        input_decay_motion: ?struct {
            quad: shaderpkg.InputGlyphQuad,
            start: std.Io.Timestamp,
        } = null,

        /// A short, OSC-133-confirmed afterimage of a submitted input row.
        /// The fixed storage keeps command commits bounded even for long lines.
        input_commit_motion: ?struct {
            quads: [inputmotion.commit_quad_count]shaderpkg.InputGlyphQuad,
            len: usize,
            start: std.Io.Timestamp,
        } = null,

        /// Custom shader uniform values.
        custom_shader_uniforms: shadertoy.Uniforms,

        /// Timestamp we rendered out first frame.
        ///
        /// This is used when updating custom shader uniforms.
        first_frame_time: ?std.Io.Timestamp = null,

        /// Timestamp when we rendered out more recent frame.
        ///
        /// This is used when updating custom shader uniforms.
        last_frame_time: ?std.Io.Timestamp = null,

        /// The font structures.
        font_grid: *font.SharedGrid,
        font_shaper: font.Shaper,
        font_shaper_cache: font.ShaperCache,

        /// The images that we may render.
        images: ImageState = .empty,

        /// Background image, if we have one.
        bg_image: ?imagepkg.Image = null,
        /// Set whenever the background image changes, signalling
        /// that the new background image needs to be uploaded to
        /// the GPU.
        ///
        /// This is initialized as true so that we load the image
        /// on renderer initialization, not just on config change.
        bg_image_changed: bool = true,
        /// Background image vertex buffer.
        bg_image_buffer: shaderpkg.BgImage,
        /// This value is used to force-update the swap chain copy
        /// of the background image buffer whenever we change it.
        bg_image_buffer_modified: usize = 0,

        /// Graphics API state.
        api: GraphicsAPI,

        /// The CVDisplayLink used to drive the rendering loop in
        /// sync with the display. This is void on platforms that
        /// don't support a display link.
        display_link: ?DisplayLink = null,

        /// Health of the most recently completed frame.
        health: std.atomic.Value(Health) = .{ .raw = .healthy },

        /// True when we have a graphics context that can create GPU
        /// resources. Creating any GPU resource while this is false is invalid.
        display_realized: bool = true,

        /// Our swap chain (multiple buffering). Null when it has
        /// been released, either because the surface is hidden
        /// (`releaseGpuResources`) or because the display is
        /// unrealized. Rebuilt on the next `drawFrame`.
        swap_chain: ?SwapChain,

        /// This value is used to force-update swap chain targets in the
        /// event of a config change that requires it (such as blending mode).
        target_config_modified: usize = 0,

        /// If something happened that requires us to reinitialize our shaders,
        /// this is set to true so that we can do that whenever possible.
        reinitialize_shaders: bool = false,

        /// Whether or not we have custom shaders.
        has_custom_shaders: bool = false,

        /// Our shader pipelines.
        shaders: Shaders,

        /// The render state we update per loop.
        terminal_state: terminal.RenderState = .empty,

        /// The number of frames since the last terminal state reset.
        /// We reset the terminal state after ~100,000 frames (about 10 to
        /// 15 minutes at 120Hz) to prevent wasted memory buildup from
        /// a large screen.
        terminal_state_frame_count: usize = 0,

        /// Our overlay state, if any.
        overlay: ?Overlay = null,

        /// The base timestamp for the Kitty graphics animation clock.
        /// Animation frame timing is expressed as milliseconds since
        /// this instant. Set on the first frame update that observes
        /// Kitty images.
        kitty_animation_clock: ?std.Io.Timestamp = null,

        /// When the next Kitty animation frame is due, in
        /// milliseconds on the animation clock, from the most recent
        /// frame update. Null when no running animation needs a
        /// wakeup.
        kitty_animation_next_ms: ?u64 = null,

        const HighlightTag = enum(u8) {
            search_match,
            search_match_selected,
        };
        /// Swap chain which maintains multiple copies of the state needed to
        /// render a frame, so that we can start building the next frame while
        /// the previous frame is still being processed on the GPU.
        const SwapChain = struct {
            // The count of buffers we use for double/triple buffering.
            // If this is one then we don't do any double+ buffering at all.
            // This is comptime because there isn't a good reason to change
            // this at runtime and there is a lot of complexity to support it.
            const buf_count = GraphicsAPI.swap_chain_count;

            /// `buf_count` structs that can hold the
            /// data needed by the GPU to draw a frame.
            frames: [buf_count]FrameState,
            /// Index of the most recently used frame state struct.
            frame_index: std.math.IntFittingRange(0, buf_count) = 0,
            /// Semaphore that we wait on to make sure we have an available
            /// frame state struct so we can start working on a new frame.
            frame_sema: std.Io.Semaphore = .{ .permits = buf_count },

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !SwapChain {
                var result: SwapChain = .{ .frames = undefined };

                // Initialize all of our frame state.
                for (&result.frames) |*frame| {
                    frame.* = try FrameState.init(api, custom_shaders);
                }

                return result;
            }

            pub fn deinit(self: *SwapChain) void {
                // Wait for all of our inflight draws to complete
                // so that we can cleanly deinit our GPU state.
                for (0..buf_count) |_| self.frame_sema.waitUncancelable(
                    global.io(),
                );
                for (&self.frames) |*frame| frame.deinit();
            }

            /// Get the next frame state to draw to. This will wait on the
            /// semaphore to ensure that the frame is available. This must
            /// always be paired with a call to releaseFrame.
            pub fn nextFrame(self: *SwapChain) *FrameState {
                self.frame_sema.waitUncancelable(global.io());
                self.frame_index = (self.frame_index + 1) % buf_count;
                return &self.frames[self.frame_index];
            }

            /// This should be called when the frame has completed drawing.
            pub fn releaseFrame(self: *SwapChain) void {
                self.frame_sema.post(global.io());
            }
        };

        /// State we need duplicated for every frame. Any state that could be
        /// in a data race between the GPU and CPU while a frame is being drawn
        /// should be in this struct.
        ///
        /// While a draw is in-process, we "lock" the state (via a semaphore)
        /// and prevent the CPU from updating the state until our graphics API
        /// reports that the frame is complete.
        ///
        /// This is used to implement double/triple buffering.
        const FrameState = struct {
            uniforms: UniformBuffer,
            cells: CellTextBuffer,
            cells_bg: CellBgBuffer,

            /// Vertex data for the animated cursor quads. At most two
            /// instances are ever drawn, so this is tiny enough that we
            /// don't bother making it conditional on `cursor-motion`.
            cursor: CursorBuffer,

            input_glyph: InputGlyphBuffer,

            grayscale: Texture,
            grayscale_modified: usize = 0,
            color: Texture,
            color_modified: usize = 0,

            target: Target,
            /// See property of same name on Renderer for explanation.
            target_config_modified: usize = 0,

            /// Buffer with the vertex data for our background image.
            ///
            /// TODO: Make this an optional and only create it
            ///       if we actually have a background image.
            bg_image_buffer: BgImageBuffer,
            /// See property of same name on Renderer for explanation.
            bg_image_buffer_modified: usize = 0,

            /// Custom shader state, this is null if we have no custom shaders.
            custom_shader_state: ?CustomShaderState = null,

            const UniformBuffer = Buffer(shaderpkg.Uniforms);
            const CellBgBuffer = Buffer(shaderpkg.CellBg);
            const CellTextBuffer = Buffer(shaderpkg.CellText);
            const CursorBuffer = Buffer(shaderpkg.CursorQuad);
            const InputGlyphBuffer = Buffer(shaderpkg.InputGlyphQuad);
            const BgImageBuffer = Buffer(shaderpkg.BgImage);

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !FrameState {
                // Uniform buffer contains exactly 1 uniform struct. The
                // uniform data will be undefined so this must be set before
                // a frame is drawn.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Create GPU buffers for our cells.
                //
                // We start them off with a size of 1, which will of course be
                // too small, but they will be resized as needed. This is a bit
                // wasteful but since it's a one-time thing it's not really a
                // huge concern.
                var cells = try CellTextBuffer.init(api.fgBufferOptions(), 1);
                errdefer cells.deinit();
                var cells_bg = try CellBgBuffer.init(api.bgBufferOptions(), 1);
                errdefer cells_bg.deinit();

                // The animated cursor never needs more than two instances
                // (a trail and the cursor itself) so we size it exactly.
                var cursor = try CursorBuffer.init(api.instanceBufferOptions(), 2);
                errdefer cursor.deinit();
                var input_glyph = try InputGlyphBuffer.init(
                    api.instanceBufferOptions(),
                    inputmotion.max_overlay_quads,
                );
                errdefer input_glyph.deinit();

                // Create a GPU buffer for our background image info.
                var bg_image_buffer = try BgImageBuffer.init(
                    api.bgImageBufferOptions(),
                    1,
                );
                errdefer bg_image_buffer.deinit();

                // Initialize our textures for our font atlas.
                //
                // As with the buffers above, we start these off as small
                // as possible since they'll inevitably be resized anyway.
                const grayscale = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .grayscale,
                });
                errdefer grayscale.deinit();
                const color = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .bgra,
                });
                errdefer color.deinit();

                var custom_shader_state =
                    if (custom_shaders)
                        try CustomShaderState.init(api)
                    else
                        null;
                errdefer if (custom_shader_state) |*state| state.deinit();

                // Initialize the target. Just as with the other resources,
                // start it off as small as we can since it'll be resized.
                const target = try api.initTarget(1, 1);

                return .{
                    .uniforms = uniforms,
                    .cells = cells,
                    .cells_bg = cells_bg,
                    .cursor = cursor,
                    .input_glyph = input_glyph,
                    .bg_image_buffer = bg_image_buffer,
                    .grayscale = grayscale,
                    .color = color,
                    .target = target,
                    .custom_shader_state = custom_shader_state,
                };
            }

            pub fn deinit(self: *FrameState) void {
                self.target.deinit();
                self.uniforms.deinit();
                self.cells.deinit();
                self.cells_bg.deinit();
                self.cursor.deinit();
                self.input_glyph.deinit();
                self.grayscale.deinit();
                self.color.deinit();
                self.bg_image_buffer.deinit();
                if (self.custom_shader_state) |*state| state.deinit();
            }

            pub fn resize(
                self: *FrameState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                if (self.custom_shader_state) |*state| {
                    try state.resize(api, width, height);
                }
                const target = try api.initTarget(width, height);
                self.target.deinit();
                self.target = target;
            }
        };

        /// State relevant to our custom shaders if we have any.
        const CustomShaderState = struct {
            /// When we have a custom shader state, we maintain a front
            /// and back texture which we use as a swap chain to render
            /// between when multiple custom shaders are defined.
            front_texture: Texture,
            back_texture: Texture,

            /// Shadertoy uses a sampler for accessing the various channel
            /// textures. In Metal, we need to explicitly create these since
            /// the glslang-to-msl compiler doesn't do it for us (as we
            /// normally would in hand-written MSL). To keep it clean and
            /// consistent, we just force all rendering APIs to provide an
            /// explicit sampler.
            ///
            /// Samplers are immutable and describe sampling properties so
            /// we can share the sampler across front/back textures (although
            /// we only need it for the source texture at a time, we don't
            /// need to "swap" it).
            sampler: Sampler,

            uniforms: UniformBuffer,

            const UniformBuffer = Buffer(shadertoy.Uniforms);

            /// Swap the front and back textures.
            pub fn swap(self: *CustomShaderState) void {
                std.mem.swap(Texture, &self.front_texture, &self.back_texture);
            }

            pub fn init(api: GraphicsAPI) !CustomShaderState {
                // Create a GPU buffer to hold our uniforms.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Initialize the front and back textures at 1x1 px, this
                // is slightly wasteful but it's only done once so whatever.
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer back_texture.deinit();

                const sampler = try Sampler.init(api.samplerOptions());
                errdefer sampler.deinit();

                return .{
                    .front_texture = front_texture,
                    .back_texture = back_texture,
                    .sampler = sampler,
                    .uniforms = uniforms,
                };
            }

            pub fn deinit(self: *CustomShaderState) void {
                self.front_texture.deinit();
                self.back_texture.deinit();
                self.sampler.deinit();
                self.uniforms.deinit();
            }

            pub fn resize(
                self: *CustomShaderState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer back_texture.deinit();

                self.front_texture.deinit();
                self.back_texture.deinit();

                self.front_texture = front_texture;
                self.back_texture = back_texture;
            }
        };

        /// State for the animated cursor, a.k.a. "caret motion".
        ///
        /// This is only used when `cursor-motion` is not `none`. When it is
        /// `none` the whole thing is inert: the cursor stays in the shared
        /// cell_text pipeline exactly as it always has, and the only cost is
        /// a single enum comparison on the paths that would otherwise touch
        /// this state.
        ///
        /// The animation itself lives in `cursor_motion.zig` and knows
        /// nothing about the renderer. All this struct does is decide when
        /// to retarget it, when to snap it, and what to draw.
        const CursorMotionState = struct {
            /// The pure animation state machine.
            anim: motionpkg.CursorMotion,

            /// The epoch for `anim`'s millisecond clock. Null until the
            /// first time we need a timestamp.
            ///
            /// This is deliberately its own clock rather than the custom
            /// shader `time` uniform: `f32` milliseconds start losing
            /// sub-frame precision after a few hours of uptime, which would
            /// show up as stutter, so we rebase the epoch whenever the
            /// animation is idle. See `cursorMotionTimeStart`.
            epoch: ?std.Io.Timestamp = null,

            /// The cursor sprite and color captured by the most recent
            /// `rebuildCells`. Null means the cursor isn't currently drawn
            /// (blink off phase, scrolled out of the viewport, preedit
            /// active), in which case we draw nothing but keep the
            /// animation state.
            head: ?Head = null,

            /// Legacy cell representation retained solely so an OS Reduce
            /// Motion toggle can restore the non-animated cursor immediately
            /// without waiting for another terminal snapshot.
            legacy_cell: ?shaderpkg.CellText = null,
            legacy_style: ?renderer.CursorStyle = null,

            /// The solid block sprite used to draw the trail quad, so that
            /// the trail reads as a streak regardless of the cursor's own
            /// shape. Only populated for styles that produce trails.
            trail: ?Glyph = null,

            /// True if the cursor should be drawn on top of the text rather
            /// than underneath it. This mirrors the ordering that
            /// `cell.Contents.setCursor` gives the cursor in the cell_text
            /// pipeline, so that both paths look the same.
            over_text: bool = false,

            /// The destination cell for block-cursor text inversion. This
            /// is separate from the pixel animation rect: text is only
            /// recolored after the free-floating cursor has arrived.
            block_text_target: ?CursorTextTarget = null,

            /// Set when the next target must be applied instantly rather
            /// than animated: the cursor was hidden, the grid was resized,
            /// the font changed, focus changed, or the config changed.
            ///
            /// Starts true so that the very first cursor placement doesn't
            /// fly in from the origin.
            snap: bool = true,

            /// True if the frame we most recently drew was mid-animation.
            /// This makes us draw exactly one more frame after `isActive`
            /// goes false, so that we always present the resting position
            /// rather than stopping a fraction of a pixel short.
            pending: bool = false,

            /// The rect we sampled for the frame we most recently drew.
            /// Custom shaders read the cursor position from here so that
            /// they follow the animation rather than the grid cell.
            last_rect: motionpkg.Rect = .zero,

            /// A glyph in the grayscale atlas.
            const Glyph = struct {
                pos: [2]u32,
                size: [2]u32,
            };

            /// The cursor quad itself.
            const Head = struct {
                glyph: Glyph,
                color: [4]u8,
            };
        };

        /// The GPU quads to draw for the animated cursor this frame. At most
        /// two: an optional trail quad, which is drawn first so that the
        /// cursor draws over it, and the cursor itself.
        const CursorQuads = struct {
            quads: [2]shaderpkg.CursorQuad = undefined,
            len: usize = 0,

            /// See `CursorMotionState.over_text`.
            over_text: bool = false,
        };

        /// The configuration for this renderer that is derived from the main
        /// configuration. This must be exported so that we don't need to
        /// pass around Config pointers which makes memory management a pain.
        pub const DerivedConfig = struct {
            arena: ArenaAllocator,

            font_thicken: bool,
            font_thicken_strength: u8,
            font_features: std.ArrayListUnmanaged([:0]const u8),
            font_styles: font.CodepointResolver.StyleStatus,
            font_shaping_break: configpkg.FontShapingBreak,
            cursor_color: ?configpkg.Config.TerminalColor,
            cursor_opacity: f64,
            cursor_motion: configpkg.CursorMotion,
            cursor_motion_duration: u32,
            cursor_motion_respect_reduce_motion: bool,
            input_motion: bool,
            input_motion_duration: u32,
            input_motion_intensity: f32,
            input_motion_respect_reduce_motion: bool,
            cursor_text: ?configpkg.Config.TerminalColor,
            background: terminal.color.RGB,
            background_opacity: f64,
            background_opacity_cells: bool,
            foreground: terminal.color.RGB,
            selection_background: ?configpkg.Config.TerminalColor,
            selection_foreground: ?configpkg.Config.TerminalColor,
            search_background: configpkg.Config.TerminalColor,
            search_foreground: configpkg.Config.TerminalColor,
            search_selected_background: configpkg.Config.TerminalColor,
            search_selected_foreground: configpkg.Config.TerminalColor,
            bold_color: ?terminal.Style.BoldColor,
            faint_opacity: u8,
            min_contrast: f32,
            padding_color: configpkg.WindowPaddingColor,
            custom_shaders: configpkg.RepeatablePath,
            bg_image: ?configpkg.Path,
            bg_image_opacity: f32,
            bg_image_position: configpkg.BackgroundImagePosition,
            bg_image_fit: configpkg.BackgroundImageFit,
            bg_image_repeat: bool,
            links: link.Set,
            vsync: bool,
            colorspace: configpkg.Config.WindowColorspace,
            blending: configpkg.Config.AlphaBlending,
            background_blur: configpkg.Config.BackgroundBlur,
            scroll_to_bottom_on_output: bool,
            custom_shader_animation: configpkg.CustomShaderAnimation,

            pub fn init(
                alloc_gpa: Allocator,
                config: *const configpkg.Config,
            ) !DerivedConfig {
                var arena = ArenaAllocator.init(alloc_gpa);
                errdefer arena.deinit();
                const alloc = arena.allocator();

                // Copy our shaders
                const custom_shaders = try config.@"custom-shader".clone(alloc);

                // Copy our background image
                const bg_image =
                    if (config.@"background-image") |bg|
                        try bg.clone(alloc)
                    else
                        null;

                // Copy our font features
                const font_features = try config.@"font-feature".clone(alloc);

                // Get our font styles
                var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
                font_styles.set(.bold, config.@"font-style-bold" != .false);
                font_styles.set(.italic, config.@"font-style-italic" != .false);
                font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

                // Our link configs
                const links = try link.Set.fromConfig(
                    alloc,
                    config.link.links.items,
                );

                return .{
                    .background_opacity = @max(0, @min(1, config.@"background-opacity")),
                    .background_opacity_cells = config.@"background-opacity-cells",
                    .font_thicken = config.@"font-thicken",
                    .font_thicken_strength = config.@"font-thicken-strength",
                    .font_features = font_features.list,
                    .font_styles = font_styles,
                    .font_shaping_break = config.@"font-shaping-break",

                    .cursor_color = config.@"cursor-color",
                    .cursor_text = config.@"cursor-text",
                    .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),
                    .cursor_motion = config.@"cursor-motion",
                    .cursor_motion_duration = @min(1000, config.@"cursor-motion-duration"),
                    .cursor_motion_respect_reduce_motion = config.@"cursor-motion-respect-reduce-motion",
                    .input_motion = config.@"input-motion",
                    .input_motion_duration = @min(1000, config.@"input-motion-duration"),
                    .input_motion_intensity = @floatCast(@max(0, @min(1, config.@"input-motion-intensity"))),
                    .input_motion_respect_reduce_motion = config.@"input-motion-respect-reduce-motion",

                    .background = config.background.toTerminalRGB(),
                    .foreground = config.foreground.toTerminalRGB(),
                    .bold_color = if (config.@"bold-color") |b| b.toTerminal() else null,
                    .faint_opacity = @intFromFloat(@ceil(config.@"faint-opacity" * 255)),

                    .min_contrast = @floatCast(config.@"minimum-contrast"),
                    .padding_color = config.@"window-padding-color",

                    .selection_background = config.@"selection-background",
                    .selection_foreground = config.@"selection-foreground",
                    .search_background = config.@"search-background",
                    .search_foreground = config.@"search-foreground",
                    .search_selected_background = config.@"search-selected-background",
                    .search_selected_foreground = config.@"search-selected-foreground",

                    .custom_shaders = custom_shaders,
                    .bg_image = bg_image,
                    .bg_image_opacity = config.@"background-image-opacity",
                    .bg_image_position = config.@"background-image-position",
                    .bg_image_fit = config.@"background-image-fit",
                    .bg_image_repeat = config.@"background-image-repeat",
                    .links = links,
                    .vsync = config.@"window-vsync",
                    .colorspace = config.@"window-colorspace",
                    .blending = config.@"alpha-blending",
                    .background_blur = config.@"background-blur",
                    .scroll_to_bottom_on_output = config.@"scroll-to-bottom".output,
                    .custom_shader_animation = config.@"custom-shader-animation",
                    .arena = arena,
                };
            }

            pub fn deinit(self: *DerivedConfig) void {
                const alloc = self.arena.allocator();
                self.links.deinit(alloc);
                self.arena.deinit();
            }
        };

        pub fn init(alloc: Allocator, options: renderer.Options) !Self {
            // Initialize our graphics API wrapper, this will prepare the
            // surface provided by the apprt and set up any API-specific
            // GPU resources.
            var api = try GraphicsAPI.init(alloc, options);
            errdefer api.deinit();

            const has_custom_shaders = options.config.custom_shaders.value.items.len > 0;

            // Prepare our swap chain
            var swap_chain = try SwapChain.init(
                api,
                has_custom_shaders,
            );
            errdefer swap_chain.deinit();

            // Create the font shaper.
            var font_shaper = try font.Shaper.init(alloc, .{
                .features = options.config.font_features.items,
            });
            errdefer font_shaper.deinit();

            // Initialize all the data that requires a critical font section.
            const font_critical: struct {
                metrics: font.Metrics,
            } = font_critical: {
                const grid: *font.SharedGrid = options.font_grid;
                grid.lock.lockSharedUncancelable(global.io());
                defer grid.lock.unlockShared(global.io());
                break :font_critical .{
                    .metrics = grid.metrics,
                };
            };

            var result: Self = .{
                .alloc = alloc,
                .config = options.config,
                .surface_mailbox = options.surface_mailbox,
                .grid_metrics = font_critical.metrics,
                .size = options.size,
                .focused = true,
                .visible = true,
                .scrollbar = .zero,
                .scrollbar_dirty = false,
                .last_bottom_node = null,
                .last_bottom_y = 0,
                .search_matches = null,
                .search_selected_match = null,
                .search_matches_dirty = false,

                // Render state
                .cells = .{},
                .uniforms = .{
                    .projection_matrix = undefined,
                    .cell_size = undefined,
                    .grid_size = undefined,
                    .grid_padding = undefined,
                    .screen_size = undefined,
                    .padding_extend = .{},
                    .min_contrast = options.config.min_contrast,
                    .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
                    .cursor_color = undefined,
                    .bg_color = .{
                        options.config.background.r,
                        options.config.background.g,
                        options.config.background.b,
                        // Note that if we're on macOS with glass effects
                        // we'll disable background opacity but we handle
                        // that in updateFrame.
                        @intFromFloat(@round(options.config.background_opacity * 255.0)),
                    },
                    .bools = .{
                        .cursor_wide = false,
                        .use_display_p3 = options.config.colorspace == .@"display-p3",
                        .use_linear_blending = options.config.blending.isLinear(),
                        .use_linear_correction = options.config.blending == .@"linear-corrected",
                    },
                },
                // The style here is only consulted while motion is enabled,
                // so `none` can map to anything; `changeConfig` keeps it up
                // to date from then on.
                .cursor_motion = .{ .anim = .init(
                    cursorMotionStyle(options.config.cursor_motion) orelse .ease,
                    @floatFromInt(options.config.cursor_motion_duration),
                ) },
                .custom_shader_uniforms = .{
                    .resolution = .{ 0, 0, 1 },
                    .time = 0,
                    .time_delta = 0,
                    .frame_rate = 60, // not currently updated
                    .frame = 0,
                    .channel_time = @splat(@splat(0)), // not currently updated
                    .channel_resolution = @splat(@splat(0)),
                    .mouse = @splat(0), // not currently updated
                    .date = @splat(0), // not currently updated
                    .sample_rate = 0, // N/A, we don't have any audio
                    .current_cursor = @splat(0),
                    .previous_cursor = @splat(0),
                    .current_cursor_color = @splat(0),
                    .previous_cursor_color = @splat(0),
                    .current_cursor_style = 0,
                    .previous_cursor_style = 0,
                    .cursor_visible = 0,
                    .cursor_change_time = 0,
                    .time_focus = 0,
                    .focus = 1, // assume focused initially
                    .palette = @splat(@splat(0)),
                    .background_color = @splat(0),
                    .foreground_color = @splat(0),
                    .cursor_color = @splat(0),
                    .cursor_text = @splat(0),
                    .selection_background_color = @splat(0),
                    .selection_foreground_color = @splat(0),
                },
                .bg_image_buffer = undefined,

                // Fonts
                .font_grid = options.font_grid,
                .font_shaper = font_shaper,
                .font_shaper_cache = font.ShaperCache.init(),

                // Shaders (initialized below)
                .shaders = undefined,

                // Graphics API stuff
                .api = api,
                .swap_chain = swap_chain,
            };

            try result.initShaders();

            // Ensure our undefined values above are correctly initialized.
            result.updateFontGridUniforms();
            result.updateScreenSizeUniforms();
            result.updateBgImageBuffer();
            try result.prepBackgroundImage();

            return result;
        }

        pub fn deinit(self: *Self) void {
            if (self.overlay) |*overlay| overlay.deinit(self.alloc);
            self.terminal_state.deinit(self.alloc);
            if (self.search_selected_match) |*m| m.arena.deinit();
            if (self.search_matches) |*m| m.arena.deinit();
            if (self.swap_chain) |*sc| sc.deinit();

            if (DisplayLink != void) {
                if (self.display_link) |display_link| {
                    display_link.stop() catch {};
                    display_link.release();
                }
            }

            self.cells.deinit(self.alloc);

            self.font_shaper.deinit();
            self.font_shaper_cache.deinit(self.alloc);

            self.config.deinit();

            self.images.deinit(self.alloc);

            if (self.bg_image) |img| img.deinit(self.alloc);

            self.deinitShaders();

            self.api.deinit();

            self.* = undefined;
        }

        fn deinitShaders(self: *Self) void {
            self.shaders.deinit(self.alloc);
        }

        fn initShaders(self: *Self) !void {
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Load our custom shaders
            const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
                arena_alloc,
                self.config.custom_shaders,
                GraphicsAPI.custom_shader_target,
            ) catch |err| err: {
                log.warn("error loading custom shaders err={}", .{err});
                break :err &.{};
            };

            const has_custom_shaders = custom_shaders.len > 0;

            var shaders = try self.api.initShaders(
                self.alloc,
                custom_shaders,
            );
            errdefer shaders.deinit(self.alloc);

            self.shaders = shaders;
            self.has_custom_shaders = has_custom_shaders;
        }

        /// This is called early right after surface creation.
        pub fn surfaceInit(surface: *apprt.Surface) !void {
            // If our API has to do things here, let it.
            if (@hasDecl(GraphicsAPI, "surfaceInit")) {
                try GraphicsAPI.surfaceInit(surface);
            }
        }

        /// This is called just prior to spinning up the renderer thread for
        /// final main thread setup requirements.
        pub fn finalizeSurfaceInit(self: *Self, surface: *apprt.Surface) !void {
            // If our API has to do things to finalize surface init, let it.
            if (@hasDecl(GraphicsAPI, "finalizeSurfaceInit")) {
                try self.api.finalizeSurfaceInit(surface);
            }
        }

        /// Callback called by renderer.Thread when it begins.
        pub fn threadEnter(self: *const Self, surface: *apprt.Surface) !void {
            // If our API has to do things on thread enter, let it.
            if (@hasDecl(GraphicsAPI, "threadEnter")) {
                try self.api.threadEnter(surface);
            }
        }

        /// Callback called by renderer.Thread when it exits.
        pub fn threadExit(self: *const Self) void {
            // If our API has to do things on thread exit, let it.
            if (@hasDecl(GraphicsAPI, "threadExit")) {
                self.api.threadExit();
            }
        }

        /// Called by renderer.Thread when it starts the main loop.
        pub fn loopEnter(self: *Self, thr: *renderer.Thread) !void {
            // If our API has to do things on loop enter, let it.
            if (@hasDecl(GraphicsAPI, "loopEnter")) {
                self.api.loopEnter();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            self.syncDisplayLink(null, &thr.draw_now);
        }

        /// Called by renderer.Thread when it exits the main loop.
        pub fn loopExit(self: *Self) void {
            // If our API has to do things on loop exit, let it.
            if (@hasDecl(GraphicsAPI, "loopExit")) {
                self.api.loopExit();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            // Stop our display link. If this fails its okay it just means
            // that we either never started it or the view its attached to
            // is gone which is fine.
            const display_link = self.display_link orelse return;
            display_link.stop() catch {};
        }

        /// This is called by the GTK apprt after the surface is
        /// reinitialized due to any of the events mentioned in
        /// the doc comment for `displayUnrealized`.
        pub fn displayRealized(self: *Self) !void {
            // If our API has to do things on realize, let it.
            if (@hasDecl(GraphicsAPI, "displayRealized")) {
                self.api.displayRealized();
            }

            // Lock the draw mutex so that we can
            // safely reinitialize our GPU resources.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We assume that the swap chain was deinited in
            // `displayUnrealized`. If not, we have a problem.
            assert(self.swap_chain == null);
            assert(!self.display_realized);

            // We reinitialize our shaders and our swap chain.
            try self.initShaders();
            self.swap_chain = try SwapChain.init(
                self.api,
                self.has_custom_shaders,
            );
            self.display_realized = true;
            self.reinitialize_shaders = false;
            self.target_config_modified = 1;
        }

        /// This is called by the GTK apprt when the surface is being destroyed.
        /// This can happen because the surface is being closed but also when
        /// moving the window between displays or splitting.
        pub fn displayUnrealized(self: *Self) void {
            // If our API has to do things on unrealize, let it.
            if (@hasDecl(GraphicsAPI, "displayUnrealized")) {
                self.api.displayUnrealized();
            }

            // Lock the draw mutex so that we can
            // safely deinitialize our GPU resources.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We deinit our swap chain and shaders. Clearing
            // `display_realized` ensures drawFrame doesn't attempt
            // to rebuild the swap chain (we have no GPU context);
            // displayRealized will.
            if (self.swap_chain) |*sc| sc.deinit();
            self.swap_chain = null;
            self.display_realized = false;
            self.shaders.deinit(self.alloc);
        }

        fn displayLinkCallback(
            _: *macos.video.DisplayLink,
            ud: ?*xev.Async,
        ) void {
            const draw_now = ud orelse return;
            draw_now.notify() catch |err| {
                log.err("error notifying draw_now err={}", .{err});
            };
        }

        /// Mark the full screen as dirty so that we redraw everything.
        pub inline fn markDirty(self: *Self) void {
            self.terminal_state.dirty = .full;
        }

        /// Called when we get an updated display ID for our display link.
        pub fn setMacOSDisplayID(
            self: *Self,
            id: u32,
            draw_now: *xev.Async,
        ) !void {
            if (comptime DisplayLink == void) return;
            self.syncDisplayLink(id, draw_now);
        }

        /// True if the cursor motion animation needs more frames.
        ///
        /// This is separate from `hasAnimations` because the render thread
        /// has to be able to tell the two apart: `custom-shader-animation`
        /// governs custom shaders only and must not gate cursor motion.
        ///
        /// This is called on the render thread outside the draw mutex (and
        /// `drawFrame` may be on the app thread). It reads only the atomic
        /// pending flag, which draw-owned animation state publishes after
        /// every target update and sample.
        pub fn cursorMotionActive(self: *const Self) bool {
            return self.cursor_motion_active.load(.acquire);
        }

        pub fn inputMotionActive(self: *const Self) bool {
            return self.input_motion_active.load(.acquire);
        }

        fn reduceMotion(self: *const Self, input: bool) bool {
            const respect = if (input)
                self.config.input_motion_respect_reduce_motion
            else
                self.config.cursor_motion_respect_reduce_motion;
            if (!respect) return false;
            if (comptime builtin.os.tag == .macos) {
                return os.macos.accessibilityDisplayShouldReduceMotion();
            }
            return false;
        }

        /// The cursor animation clock, in milliseconds since
        /// `cursor_motion.epoch`. Returns 0 before the clock has started,
        /// at which point nothing can be animating anyway.
        fn cursorMotionTime(self: *const Self) f32 {
            const epoch = self.cursor_motion.epoch orelse return 0;
            const now: std.Io.Timestamp = .now(global.io(), .awake);

            // We go through f64 because the nanosecond count is well past
            // what f32 can hold exactly.
            const ns: f64 = @floatFromInt(epoch.durationTo(now).nanoseconds);
            return @floatCast(ns / std.time.ns_per_ms);
        }

        /// Like `cursorMotionTime`, but restarts the clock first if the
        /// animation is idle.
        ///
        /// Rebasing while idle is always safe (nothing holds a timestamp
        /// across it) and it's what keeps the `f32` values we hand the
        /// animation small enough to stay exact, no matter how long the
        /// process has been running.
        ///
        /// Caller must hold the draw mutex.
        fn cursorMotionTimeStart(self: *Self) f32 {
            const state: *CursorMotionState = &self.cursor_motion;

            if (state.epoch != null) {
                const ms = self.cursorMotionTime();
                if (state.anim.isActive(ms)) return ms;
            }

            state.epoch = .now(global.io(), .awake);

            // Park the animation on its target so that its stored
            // timestamps agree with the clock we just restarted.
            state.anim.snap(state.anim.target);
            return 0;
        }

        /// The cadence of continuous (draw-only) animation wakes,
        /// i.e. 120fps, and the floor for any animation wake delay.
        pub const draw_interval_ms: u64 = 8;

        /// A point in the future when the renderer needs to be driven
        /// again to keep animating, and what kind of drive it needs.
        pub const AnimationWake = struct {
            /// Delay in milliseconds until the wake is due.
            delay_ms: u64,
            kind: Kind,

            pub const Kind = enum {
                /// A redraw alone suffices, no updateFrame. Much cheaper
                /// than `update`.
                draw,

                /// Frame data must be updated first: updateFrame, then draw.
                update,
            };
        };

        /// The soonest animation wake this renderer needs, if any:
        /// custom shader animation wants continuous draw-only wakes
        /// at draw_interval_ms while active, and a running Kitty
        /// graphics animation wants an update wake when its next
        /// frame is due. The renderer thread drives its animation
        /// timer off this, re-querying after every wake.
        ///
        /// Must be called on the render thread.
        pub fn animationWake(self: *const Self) ?AnimationWake {
            // Ghosttal cursor and local-input motion are draw-only and are
            // deliberately independent of custom-shader-animation.
            const motion_delay: ?u64 = if (self.focused and
                (self.cursorMotionActive() or self.inputMotionActive()))
                draw_interval_ms
            else
                null;

            // Custom shaders animate by redrawing on a fixed cadence,
            // gated by configuration and focus.
            const shader_delay: ?u64 = shader: {
                if (!self.has_custom_shaders) break :shader null;
                break :shader switch (self.config.custom_shader_animation) {
                    .false => null,
                    .always => draw_interval_ms,
                    .true => if (self.focused) draw_interval_ms else null,
                };
            };

            // Kitty animations tick during updateFrame; between
            // updates the deadline is absolute on the animation
            // clock, so a stream of draw wakes recomputing this
            // cannot starve it into the future.
            const kitty_delay: ?u64 = kitty: {
                const next = self.kitty_animation_next_ms orelse break :kitty null;
                const base = self.kitty_animation_clock orelse break :kitty null;
                const now: std.Io.Timestamp = .now(global.io(), .awake);
                const now_ms: u64 = @intCast(@divTrunc(
                    base.durationTo(now).nanoseconds,
                    std.time.ns_per_ms,
                ));
                // Never wake faster than the draw interval; an
                // overdue frame is picked up on the next wake.
                break :kitty @max(next -| now_ms, draw_interval_ms);
            };

            // An update wake includes a draw, so it wins ties.
            const draw_delay: ?u64 = if (motion_delay) |m|
                if (shader_delay) |s| @min(m, s) else m
            else
                shader_delay;

            if (kitty_delay) |k| {
                if (draw_delay == null or k <= draw_delay.?) {
                    return .{ .delay_ms = k, .kind = .update };
                }
            }

            if (draw_delay) |d| return .{ .delay_ms = d, .kind = .draw };

            return null;
        }

        /// True if our renderer is using vsync. If true, the renderer or apprt
        /// is responsible for triggering draw_now calls to the render thread.
        /// That is the only way to trigger a drawFrame.
        pub fn hasVsync(self: *const Self) bool {
            if (comptime DisplayLink == void) return false;
            const display_link = self.display_link orelse return false;
            return display_link.isRunning();
        }

        /// Callback when the focus changes for the terminal this is rendering.
        ///
        /// Must be called on the render thread.
        pub fn setFocus(self: *Self, focus: bool) !void {
            assert(self.focused != focus);

            self.focused = focus;

            // Flag that we need to update our custom shaders
            self.custom_shader_focused_changed = true;

            // Focus changes swap the cursor between solid and hollow and
            // stop the blink, so an animation across the change would be
            // nonsense. Snap instead.
            self.draw_mutex.lockUncancelable(global.io());
            self.cursor_motion.snap = true;
            self.clearInputMotion();
            self.draw_mutex.unlock(global.io());
            self.cursor_motion_active.store(false, .release);

            self.syncDisplayLink(null, null);
        }

        /// Callback when the window is visible or occluded.
        ///
        /// Must be called on the render thread.
        pub fn setVisible(self: *Self, visible: bool) void {
            self.visible = visible;
            self.syncDisplayLink(null, null);

            // When we're hidden, release our GPU resources if GPU
            // operations are allowed from this thread. Apprts where
            // they aren't (GTK owns the OpenGL context on the app
            // thread) call `releaseGpuResources` at the appropriate
            // time instead.
            if (comptime !apprt.must_draw_from_app_thread) {
                if (!visible) self.releaseGpuResources();
            }
        }

        /// Release the GPU resources we hold while the surface is not
        /// visible. Today this is the swap chain (render targets, font
        /// atlas texture copies, cell buffers, custom shader textures),
        /// which makes up nearly all of a surface's GPU memory usage;
        /// a hidden surface doesn't draw, so it doesn't need it. The
        /// swap chain is rebuilt on the next `drawFrame`.
        ///
        /// This is safe to call in any state; resources that are
        /// already released are skipped.
        ///
        /// For OpenGL this must be called on the app thread with the
        /// GL context current (the same requirement as
        /// `displayUnrealized`). Other APIs may call this from the
        /// render thread; see `apprt.must_draw_from_app_thread`.
        pub fn releaseGpuResources(self: *Self) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            if (self.swap_chain) |*sc| {
                // Waits for any in-flight frames to complete, then
                // frees all GPU resources.
                sc.deinit();
                self.swap_chain = null;

                // Let the API drop any references it holds to swap
                // chain resources (e.g. OpenGL's last presented
                // target).
                if (comptime @hasDecl(GraphicsAPI, "gpuResourcesReleased")) {
                    self.api.gpuResourcesReleased();
                }
            }
        }

        /// Create or update the display link and match it to the current
        /// surface state.
        fn syncDisplayLink(
            self: *Self,
            display_id: ?u32,
            draw_now: ?*xev.Async,
        ) void {
            if (comptime DisplayLink == void) return;

            const display_link = self.display_link orelse display_link: {
                if (!self.config.vsync) return;
                const callback = draw_now orelse return;
                const result = macos.video.DisplayLink.createWithActiveCGDisplays() catch |err| {
                    // A locked macOS session can temporarily have no active
                    // displays. Rendering can continue without vsync and a
                    // later display update will retry this method.
                    log.warn("error creating display link; using fallback rendering err={}", .{err});
                    return;
                };
                result.setOutputCallback(
                    xev.Async,
                    &displayLinkCallback,
                    callback,
                ) catch |err| {
                    log.warn("error configuring display link err={}", .{err});
                    result.release();
                    return;
                };

                self.display_link = result;
                log.info("created display link", .{});
                break :display_link result;
            };

            if (display_id) |id| {
                log.info("updating display link display id={}", .{id});
                display_link.setCurrentCGDisplay(id) catch |err| {
                    log.warn("error setting display link display id err={}", .{err});
                };
            }

            const should_run =
                // Non-visible windows never vsync
                self.visible and
                // Non-focused windows only render on-demand
                self.focused and
                // Only vsync if we have cell changes or animation
                (self.cells_rebuilt or self.animationWake() != null);

            if (should_run) {
                if (!display_link.isRunning()) {
                    display_link.start() catch {};
                }
            } else {
                display_link.stop() catch {};
            }
        }

        /// Set the new font grid.
        ///
        /// Must be called on the render thread.
        pub fn setFontGrid(self: *Self, grid: *font.SharedGrid) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // Update our grid
            self.font_grid = grid;

            // Update all our textures so that they sync on the next frame.
            // We can modify this without a lock because the GPU does not
            // touch this data. A released swap chain is rebuilt with
            // fresh frames that sync all textures on first use.
            if (self.swap_chain) |*sc| for (&sc.frames) |*frame| {
                frame.grayscale_modified = 0;
                frame.color_modified = 0;
            };

            // Get our metrics from the grid. This doesn't require a lock because
            // the metrics are never recalculated.
            const metrics = grid.metrics;
            self.grid_metrics = metrics;

            // Reset our shaper cache. If our font changed (not just the size) then
            // the data in the shaper cache may be invalid and cannot be used, so we
            // always clear the cache just in case.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Update cell size.
            self.size.cell = .{
                .width = metrics.cell_width,
                .height = metrics.cell_height,
            };

            // Update relevant uniforms
            self.updateFontGridUniforms();

            // The cursor rect is derived from the cell size, so a font
            // change moves and resizes it for reasons that have nothing to
            // do with the cursor. Snap rather than animate that.
            self.cursor_motion.snap = true;

            // Force a full rebuild, because cached rows may still reference
            // an outdated atlas from the old grid and this can cause garbage
            // to be rendered.
            self.markDirty();
        }

        /// Update uniforms that are based on the font grid.
        ///
        /// Caller must hold the draw mutex.
        fn updateFontGridUniforms(self: *Self) void {
            self.uniforms.cell_size = .{
                @floatFromInt(self.grid_metrics.cell_width),
                @floatFromInt(self.grid_metrics.cell_height),
            };
        }

        /// Update the frame data.
        pub fn updateFrame(
            self: *Self,
            state: *renderer.State,
            cursor_blink_visible: bool,
        ) Allocator.Error!void {
            // CoreText shaping accumulates objects for deferred release over
            // the course of a frame. Always flush those objects, including
            // when rebuilding the frame fails due to memory pressure.
            defer self.font_shaper.endFrame();

            // We fully deinit and reset the terminal state every so often
            // so that a particularly large terminal state doesn't cause
            // the renderer to hold on to retained memory.
            //
            // Frame count is ~12 minutes at 120Hz.
            const max_terminal_state_frame_count = 100_000;
            if (self.terminal_state_frame_count >= max_terminal_state_frame_count) {
                self.terminal_state.deinit(self.alloc);
                self.terminal_state = .empty;
                self.terminal_state_frame_count = 0;
            }
            self.terminal_state_frame_count += 1;

            // Create an arena for all our temporary allocations while rebuilding
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Data we extract out of the critical area.
            const Critical = struct {
                links: terminal.RenderState.CellSet,
                mouse: renderer.State.Mouse,
                preedit: ?renderer.State.Preedit,
                /// A locally encoded intent is only consumed alongside a
                /// dirty terminal snapshot. The later cell-diff matcher may
                /// reject it; in that case no output animation is emitted.
                input_intent: ?inputmotion.Event,
                screen_generation: usize,
                semantic_output: bool,
                scrollbar: terminal.Scrollbar,
                overlay_features: []const Overlay.Feature,
            };

            // Update all our data as tightly as possible within the mutex.
            var critical: Critical = critical: {
                // NOTE: This code needs be updated to 0.16.0 before you
                // un-comment it ;)
                //
                // const start = try std.time.Instant.now();
                // const start_micro = std.time.microTimestamp();
                // defer {
                //     const end = std.time.Instant.now() catch unreachable;
                //     std.log.err("[updateFrame critical time] start={}\tduration={} us", .{ start_micro, end.since(start) / std.time.ns_per_us });
                // }

                state.lockDemand(global.io());
                defer state.unlockDemand(global.io());

                // If we're in a synchronized output state, we pause all rendering.
                if (state.terminal.modes.get(.synchronized_output)) {
                    log.debug("synchronized output started, skipping render", .{});
                    return;
                }

                // If scroll-to-bottom on output is enabled, check if the final line
                // changed by comparing the bottom-right pin. If the node pointer or
                // y offset changed, new content was added to the screen.
                // Update this BEFORE we update our render state so we can
                // draw the new scrolled data immediately.
                if (self.config.scroll_to_bottom_on_output) scroll: {
                    const br = state.terminal.screens.active.pages.getBottomRight(.screen) orelse break :scroll;

                    // If the pin hasn't changed, then don't scroll.
                    if (self.last_bottom_node == @intFromPtr(br.node) and
                        self.last_bottom_y == br.y) break :scroll;

                    // Update tracked pin state for next frame
                    self.last_bottom_node = @intFromPtr(br.node);
                    self.last_bottom_y = br.y;

                    // Scroll
                    state.terminal.scrollViewport(.bottom);
                }

                // Begin the update of our terminal state. Work that
                // doesn't require terminal access (e.g. style
                // denormalization) is deferred to the endUpdate call
                // outside of this critical section, keeping our lock
                // hold time as short as possible.
                try self.terminal_state.beginUpdate(
                    self.alloc,
                    state.terminal,
                );

                // If our terminal state is dirty at all we need to redo
                // the viewport search.
                if (self.terminal_state.dirty != .false) {
                    state.terminal.flags.search_viewport_dirty = true;
                }

                // Get our scrollbar out of the terminal. We synchronize
                // the scrollbar read with frame data updates because this
                // naturally limits the number of calls to this method (it
                // can be expensive) and also makes it so we don't need another
                // cross-thread mailbox message within the IO path.
                const scrollbar = state.terminal.screens.active.pages.scrollbar();

                // Get our preedit state
                const preedit: ?renderer.State.Preedit = preedit: {
                    const p = state.preedit orelse break :preedit null;
                    break :preedit try p.clone(arena_alloc);
                };

                // Do not drain intent merely because a frame happened. The
                // cell-diff matcher consumes it only after confirming a
                // local-echo-shaped change; until then it remains queued.
                state.input_motion.dropExpired(.now(global.io(), .awake));
                const input_intent = if (self.terminal_state.dirty == .false)
                    null
                else
                    state.input_motion.peek();
                // Advance any running Kitty graphics animations to the
                // frame due now, and remember when the next frame is
                // due (as an absolute deadline, see animationWake) so
                // the renderer thread can schedule a wakeup for it.
                // This must happen before the dirty check below:
                // advancing a frame marks the image state dirty.
                self.kitty_animation_next_ms = next: {
                    // Likely case: we have no kitty images, so do nothing.
                    const storage = &state.terminal.screens.active.kitty_images;
                    if (storage.images.count() == 0) break :next null;

                    const now: std.Io.Timestamp = .now(global.io(), .awake);
                    const base = self.kitty_animation_clock orelse base: {
                        self.kitty_animation_clock = now;
                        break :base now;
                    };
                    const now_ms: u64 = @intCast(@divTrunc(
                        base.durationTo(now).nanoseconds,
                        std.time.ns_per_ms,
                    ));
                    const delay = storage.animationTick(
                        global.io(),
                        now_ms,
                    ) orelse break :next null;
                    break :next now_ms + delay;
                };

                // If we have Kitty graphics data, we enter a SLOW SLOW SLOW path.
                // We only do this if the Kitty image state is dirty meaning only if
                // it changes.
                //
                // If we have any virtual references, we must also rebuild our
                // kitty state on every frame because any cell change can move
                // an image.
                if (self.images.kittyRequiresUpdate(state.terminal)) {
                    // We need to grab the draw mutex since this updates
                    // our image state that drawFrame uses.
                    self.draw_mutex.lockUncancelable(global.io());
                    defer self.draw_mutex.unlock(global.io());
                    self.images.kittyUpdate(
                        self.alloc,
                        state.terminal,
                        .{
                            .width = self.grid_metrics.cell_width,
                            .height = self.grid_metrics.cell_height,
                        },
                    );
                }

                // Get our OSC8 links we're hovering if we have a mouse.
                // This requires terminal state because of URLs.
                const links: terminal.RenderState.CellSet = osc8: {
                    // If our mouse isn't hovering, we have no links.
                    const vp = state.mouse.point orelse break :osc8 .empty;

                    // If the right mods aren't pressed, then we can't match.
                    if (!state.mouse.mods.equal(inputpkg.ctrlOrSuper(.{})))
                        break :osc8 .empty;

                    break :osc8 self.terminal_state.linkCells(
                        arena_alloc,
                        vp,
                    ) catch |err| {
                        log.warn("error searching for OSC8 links err={}", .{err});
                        break :osc8 .empty;
                    };
                };

                const overlay_features: []const Overlay.Feature = overlay: {
                    const insp = state.inspector orelse break :overlay &.{};
                    const renderer_info = insp.rendererInfo();
                    break :overlay renderer_info.overlayFeatures(
                        arena_alloc,
                    ) catch &.{};
                };

                break :critical .{
                    .links = links,
                    .mouse = state.mouse,
                    .preedit = preedit,
                    .input_intent = input_intent,
                    .screen_generation = state.terminal.screens.generation(state.terminal.screens.active_key),
                    .semantic_output = state.terminal.screens.active.cursor.semantic_content == .output,
                    .scrollbar = scrollbar,
                    .overlay_features = overlay_features,
                };
            };

            // Outside the critical area, complete the update we began
            // within it. This must be done before anything reads the
            // render state (e.g. rebuildCells).
            self.terminal_state.endUpdate();

            // Outside the critical area we can update our links to contain
            // our regex results.
            self.config.links.renderCellMap(
                arena_alloc,
                &critical.links,
                &self.terminal_state,
                state.mouse.point,
                state.mouse.mods,
            ) catch |err| {
                log.warn("error searching for regex links err={}", .{err});
            };

            // Clear our highlight state and update.
            if (self.search_matches_dirty or self.terminal_state.dirty != .false) {
                self.search_matches_dirty = false;

                // Clear the prior highlights
                const row_data = self.terminal_state.row_data.slice();
                var any_dirty: bool = false;
                for (
                    row_data.items(.highlights),
                    row_data.items(.dirty),
                ) |*highlights, *dirty| {
                    if (highlights.items.len > 0) {
                        highlights.clearRetainingCapacity();
                        dirty.* = true;
                        any_dirty = true;
                    }
                }
                if (any_dirty and self.terminal_state.dirty == .false) {
                    self.terminal_state.dirty = .partial;
                }

                // NOTE: The order below matters. Highlights added earlier
                // will take priority.

                if (self.search_selected_match) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match_selected),
                        &.{m.match},
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search selected highlight err={}", .{err});
                    };
                }

                if (self.search_matches) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match),
                        m.matches,
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search highlights err={}", .{err});
                    };
                }
            }

            // From this point forward no more errors.
            errdefer comptime unreachable;

            // Resolve the intent while no draw lock is held. updateFrame's
            // normal ordering is State -> draw; preserving it here avoids a
            // lock inversion with Surface's input path.
            const clear_input_motion = critical.preedit != null or self.terminal_state.dirty == .full;
            const input_glyph_start: ?inputmotion.Event = if (clear_input_motion or
                !self.config.input_motion or self.config.input_motion_intensity == 0 or self.reduceMotion(true))
            barrier: {
                // A preedit/full redraw changes the input contract rather
                // than merely delaying echo. Discard every pending intent.
                state.mutex.lockUncancelable(global.io());
                defer state.mutex.unlock(global.io());
                state.input_motion.reset();
                break :barrier null;
            } else if (critical.input_intent) |event| switch (event.kind) {
                .text => self.resolveInputGlyphIntent(state, event, false, false, critical.screen_generation),
                .delete => self.resolveInputDecayIntent(state, event, critical.screen_generation),
                .commit => self.resolveInputCommitIntent(
                    state,
                    event,
                    critical.screen_generation,
                    critical.semantic_output,
                ),
            } else null;

            // Reset our dirty state after updating.
            defer self.terminal_state.dirty = .false;

            // Rebuild the overlay image if we have one. We can do this
            // outside of any critical areas.
            self.rebuildOverlay(
                critical.overlay_features,
            ) catch |err| {
                log.warn(
                    "error rebuilding overlay surface err={}",
                    .{err},
                );
            };

            // Acquire the draw mutex for all remaining state updates.
            {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());

                // Build our GPU cells
                if (clear_input_motion) self.clearInputMotion();
                if (input_glyph_start) |event| switch (event.kind) {
                    .text => self.startInputGlyphMotion(event),
                    .delete => self.startInputDecayMotion(event),
                    .commit => self.startInputCommitMotion(event),
                };
                self.rebuildCells(
                    critical.preedit,
                    renderer.cursorStyle(&self.terminal_state, .{
                        .preedit = critical.preedit != null,
                        .focused = self.focused,
                        .blink_visible = cursor_blink_visible,
                    }),
                    &critical.links,
                ) catch |err| {
                    // This means we weren't able to allocate our buffer
                    // to update the cells. In this case, we continue with
                    // our old buffer (frozen contents) and log it.
                    comptime assert(@TypeOf(err) == error{OutOfMemory});
                    log.warn("error rebuilding GPU cells err={}", .{err});
                };

                // The scrollbar is only emitted during draws so we also
                // check the scrollbar cache here and update if needed.
                // This is pretty fast.
                if (!self.scrollbar.eql(critical.scrollbar)) {
                    self.scrollbar = critical.scrollbar;
                    self.scrollbar_dirty = true;
                }

                // Update our background color
                self.uniforms.bg_color = .{
                    self.terminal_state.colors.background.r,
                    self.terminal_state.colors.background.g,
                    self.terminal_state.colors.background.b,
                    @intFromFloat(@round(self.config.background_opacity * 255.0)),
                };

                // If we're on macOS and have glass styles, we remove
                // the background opacity because the glass effect handles
                // it.
                if (comptime builtin.os.tag == .macos) switch (self.config.background_blur) {
                    .@"macos-glass-regular",
                    .@"macos-glass-clear",
                    => self.uniforms.bg_color[3] = 0,

                    else => {},
                };

                // Prepare our overlay image for upload (or unload). This
                // has to use our general allocator since it modifies
                // state that survives frames.
                self.images.overlayUpdate(
                    self.alloc,
                    self.overlay,
                ) catch |err| {
                    log.warn("error updating overlay images err={}", .{err});
                };

                // Update custom shader uniforms that depend on terminal state.
                self.updateCustomShaderUniformsFromState();
            }

            // Start the display link now that the rebuilt frame is ready.
            self.syncDisplayLink(null, null);
        }

        /// Draw the frame to the screen.
        ///
        /// If `sync` is true, this will synchronously block until
        /// the frame is finished drawing and has been presented.
        pub fn drawFrame(
            self: *Self,
            sync: bool,
        ) !void {
            // We hold a the draw mutex to prevent changes to any
            // data we access while we're in the middle of drawing.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            self.cancelMotionForReduceMotion();

            // After the graphics API is complete (so we defer) we want to
            // update our scrollbar state.
            defer if (self.scrollbar_dirty) {
                // Fail instantly if the surface mailbox if full, we'll just
                // get it on the next frame.
                if (self.surface_mailbox.push(.{
                    .scrollbar = self.scrollbar,
                }, .instant) > 0) self.scrollbar_dirty = false;
            };

            // Let our graphics API do any bookkeeping, etc.
            // that it needs to do before / after `drawFrame`.
            self.api.drawFrameStart();
            defer self.api.drawFrameEnd();

            // Retrieve the most up-to-date surface size from the Graphics API
            const surface_size = try self.api.surfaceSize();

            // If either of our surface dimensions is zero
            // then drawing is absurd, so we just return.
            if (surface_size.width == 0 or surface_size.height == 0) return;

            // If we have no graphics context we can't draw. This is
            // only the case while unrealized (GTK); displayRealized
            // rebuilds the swap chain.
            if (!self.display_realized) return;

            // Get our swap chain, rebuilding it if it was released
            // while we were hidden. Rebuilding is deferred to draw
            // time because resource creation must happen somewhere
            // our graphics API allows it (OpenGL requires a current
            // context, which drawFrame guarantees).
            const swap_chain: *SwapChain, const swap_chain_rebuilt: bool =
                if (self.swap_chain) |*sc| .{ sc, false } else rebuild: {
                    self.swap_chain = try SwapChain.init(
                        self.api,
                        self.has_custom_shaders,
                    );
                    break :rebuild .{ &self.swap_chain.?, true };
                };

            const size_changed =
                self.size.screen.width != surface_size.width or
                self.size.screen.height != surface_size.height;

            // Conditions under which we need to draw the frame, otherwise we
            // don't need to since the previous frame should be identical.
            //
            // While any animation is in progress (a pending animation wake)
            // every draw must actually render.
            const needs_redraw =
                size_changed or
                swap_chain_rebuilt or
                self.cells_rebuilt or
                self.animationWake() != null or
                sync;

            if (!needs_redraw) {
                // We still need to present the last target again, because the
                // apprt may be swapping buffers and display an outdated frame
                // if we don't draw something new.
                try self.api.presentLastTarget();

                // Resync the display link because we can probably pause
                // the display link at this point.
                self.syncDisplayLink(null, null);
                return;
            }
            self.cells_rebuilt = false;

            // Wait for a frame to be available.
            const frame = swap_chain.nextFrame();
            errdefer swap_chain.releaseFrame();
            // log.debug("drawing frame index={}", .{swap_chain.frame_index});

            // If we need to reinitialize our shaders, do so.
            if (self.reinitialize_shaders) {
                self.reinitialize_shaders = false;
                self.shaders.deinit(self.alloc);
                try self.initShaders();
            }

            // Our shaders should not be defunct at this point.
            assert(!self.shaders.defunct);

            // If we have custom shaders, make sure we have the
            // custom shader state in our frame state, otherwise
            // if we have a state but don't need it we remove it.
            if (self.has_custom_shaders) {
                if (frame.custom_shader_state == null) {
                    frame.custom_shader_state = try .init(self.api);
                    try frame.custom_shader_state.?.resize(
                        self.api,
                        surface_size.width,
                        surface_size.height,
                    );
                }
            } else if (frame.custom_shader_state) |*state| {
                state.deinit();
                frame.custom_shader_state = null;
            }

            // If our stored size doesn't match the
            // surface size we need to update it.
            if (size_changed) {
                self.clearInputMotion();
                self.size.screen = .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
                self.updateScreenSizeUniforms();
            }

            // If this frame's target isn't the correct size, or the target
            // config has changed (such as when the blending mode changes),
            // remove it and replace it with a new one with the right values.
            if (frame.target.width != self.size.screen.width or
                frame.target.height != self.size.screen.height or
                frame.target_config_modified != self.target_config_modified)
            {
                try frame.resize(
                    self.api,
                    self.size.screen.width,
                    self.size.screen.height,
                );
                frame.target_config_modified = self.target_config_modified;
            }

            // Upload images to the GPU as necessary.
            _ = self.images.upload(self.alloc, &self.api);

            // Upload the background image to the GPU as necessary.
            try self.uploadBackgroundImage();

            // Sample the animated cursor before the custom shader uniforms.
            // The latter intentionally sees the semantic target instead of
            // every intermediate rect (see cursorPixelRect), but sampling
            // here publishes whether another animation frame is needed.
            const cursor_quads = self.sampleCursorMotion();
            const input_glyph = self.sampleInputGlyphMotion();
            const input_decay = self.sampleInputDecayMotion();
            const input_commit = self.sampleInputCommitMotion();
            var input_quads: InputGlyphQuads = .{};
            var input_animating = false;
            if (input_glyph) |glyph| {
                input_quads.append(glyph.quad);
                input_animating = glyph.active;
            }
            if (input_decay) |decay| {
                input_quads.appendSlice(decay.quads[0..decay.len]);
                input_animating = true;
            }
            if (input_commit) |commit| {
                input_quads.appendSlice(commit.quads[0..commit.len]);
                input_animating = true;
            }
            self.input_motion_active.store(input_animating, .release);

            // Update per-frame custom shader uniforms.
            try self.updateCustomShaderUniformsForFrame();

            // Setup our frame data
            try frame.uniforms.sync(&.{self.uniforms});
            try frame.cells_bg.sync(self.cells.bg_cells);
            const fg_count = try frame.cells.syncFromArrayLists(self.cells.fg_rows);
            if (cursor_quads.len > 0) {
                try frame.cursor.sync(cursor_quads.quads[0..cursor_quads.len]);
            }
            if (input_quads.len > 0) try frame.input_glyph.sync(input_quads.quads[0..input_quads.len]);

            // If our background image buffer has changed, sync it.
            if (frame.bg_image_buffer_modified != self.bg_image_buffer_modified) {
                try frame.bg_image_buffer.sync(&.{self.bg_image_buffer});

                frame.bg_image_buffer_modified = self.bg_image_buffer_modified;
            }

            // If our font atlas changed, sync the texture data
            texture: {
                const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                if (modified <= frame.grayscale_modified) break :texture;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.grayscale_modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_grayscale, &frame.grayscale);
            }
            texture: {
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);
                if (modified <= frame.color_modified) break :texture;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_color, &frame.color);
            }

            // Get a frame context from the graphics API.
            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            defer frame_ctx.complete(sync);

            {
                var pass = frame_ctx.renderPass(&.{.{
                    .target = if (frame.custom_shader_state) |state|
                        .{ .texture = state.back_texture }
                    else
                        .{ .target = frame.target },
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                }});
                defer pass.complete();

                // First we draw our background image, if we have one.
                // The bg image shader also draws the main bg color.
                //
                // Otherwise, if we don't have a background image, we
                // draw the background color by itself in its own step.
                //
                // NOTE: We don't use the clear_color for this because that
                //       would require us to do color space conversion on the
                //       CPU-side. In the future when we have utilities for
                //       that we should remove this step and use clear_color.
                if (self.bg_image) |img| switch (img) {
                    .ready => |texture| pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_image,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{frame.bg_image_buffer.buffer},
                        .textures = &.{texture},
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    }),
                    else => {},
                } else {
                    pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_color,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{ null, frame.cells_bg.buffer },
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    });
                }

                // Then we draw any kitty images that need
                // to be behind text AND cell backgrounds.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_bg,
                );

                // Then we draw any opaque cell backgrounds.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_bg,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{ null, frame.cells_bg.buffer },
                    .draw = .{ .type = .triangle, .vertex_count = 3 },
                });

                // Kitty images between cell backgrounds and text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_text,
                );

                // The animated cursor, when it belongs beneath the text.
                // This mirrors `Contents.setCursor` putting the block
                // cursor in the fg row that draws before the text.
                if (cursor_quads.len > 0 and !cursor_quads.over_text) {
                    self.drawCursorQuads(&pass, frame, cursor_quads);
                }

                // Text.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_text,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{
                        frame.cells.buffer,
                        frame.cells_bg.buffer,
                    },
                    .textures = &.{
                        frame.grayscale,
                        frame.color,
                    },
                    .draw = .{
                        .type = .triangle_strip,
                        .vertex_count = 4,
                        .instance_count = fg_count,
                    },
                });

                // The one confirmed local echo rises above normal text. Its
                // corresponding CellText instance was withheld in addGlyph.
                if (input_quads.len > 0) pass.step(.{
                    .pipeline = self.shaders.pipelines.input_glyph,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{ frame.input_glyph.buffer, frame.cells_bg.buffer },
                    .textures = &.{ frame.grayscale, frame.color },
                    .draw = .{ .type = .triangle_strip, .vertex_count = 4, .instance_count = input_quads.len },
                });

                // The animated cursor, when it belongs on top of the text:
                // hollow, bar, underline, and lock. This mirrors
                // `Contents.setCursor` putting those in the fg row that
                // draws after the text.
                if (cursor_quads.len > 0 and cursor_quads.over_text) {
                    self.drawCursorQuads(&pass, frame, cursor_quads);
                }

                // Kitty images in front of text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_above_text,
                );

                // Debug overlay. We do this before any custom shader state
                // because our debug overlay is aligned with the grid.
                if (self.overlay != null) self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .overlay,
                );
            }

            // If we have custom shaders, then we render them.
            if (frame.custom_shader_state) |*state| {
                // Sync our uniforms.
                try state.uniforms.sync(&.{self.custom_shader_uniforms});

                for (self.shaders.post_pipelines, 0..) |pipeline, i| {
                    defer state.swap();

                    var pass = frame_ctx.renderPass(&.{.{
                        .target = if (i < self.shaders.post_pipelines.len - 1)
                            .{ .texture = state.front_texture }
                        else
                            .{ .target = frame.target },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    }});
                    defer pass.complete();

                    pass.step(.{
                        .pipeline = pipeline,
                        .uniforms = state.uniforms.buffer,
                        .textures = &.{state.back_texture},
                        .samplers = &.{state.sampler},
                        .draw = .{
                            .type = .triangle,
                            .vertex_count = 3,
                        },
                    });
                }
            }
        }

        /// Sample the cursor motion animation for this frame and build the
        /// quads to draw for it. Returns an empty result when cursor motion
        /// is disabled or the cursor isn't currently visible.
        ///
        /// Caller must hold the draw mutex.
        fn sampleCursorMotion(self: *Self) CursorQuads {
            if (self.config.cursor_motion == .none) return .{};

            const state: *CursorMotionState = &self.cursor_motion;
            const head = state.head orelse {
                // Nothing to draw, and nothing to schedule frames for.
                state.pending = false;
                self.cursor_motion_active.store(false, .release);
                return .{};
            };

            // Note this also restarts the clock and parks the animation if
            // we've settled, so the sample below lands exactly on target.
            const now = self.cursorMotionTimeStart();
            const sample = state.anim.sample(now);

            // Remember whether we're still in flight. This is what keeps
            // the draw pump running, and it stays true through the frame on
            // which the animation ends so that we always present the
            // resting position rather than stopping a fraction short.
            state.pending = state.anim.isActive(now);
            self.cursor_motion_active.store(state.pending, .release);
            state.last_rect = sample.rect;

            // A free-floating block cursor is not over any one grid cell,
            // so keep cell-text inversion disabled while it is moving. The
            // final resting/snap frame restores the legacy cursor-text color
            // at the destination without requiring another terminal rebuild.
            if (cursorTextInversionTarget(
                state.block_text_target,
                state.pending,
            )) |target| {
                self.uniforms.cursor_pos = target.pos;
                self.uniforms.bools.cursor_wide = target.wide;
            }

            var result: CursorQuads = .{ .over_text = state.over_text };

            // The trail goes first so that the cursor draws over it.
            if (sample.trail != null) trail: {
                const glyph = state.trail orelse break :trail;
                // `trail` is the conservative axis-aligned bounds; the
                // actual drawing uses this directional line. A sample from
                // an older/restored state without one simply has no trail.
                const line = sample.trail_line orelse break :trail;
                const dx = line.to[0] - line.from[0];
                const dy = line.to[1] - line.from[1];
                const length = std.math.hypot(dx, dy);
                if (length < 1.0) break :trail;
                const basis_x: [2]f32 = .{ dx / length, dy / length };
                const basis_y: [2]f32 = .{ -basis_x[1], basis_x[0] };

                // Fold the trail's fade into the cursor alpha. The shader
                // premultiplies from this byte, so scaling it here is the
                // correct way to fade a premultiplied color.
                const alpha: u8 = @intFromFloat(@round(
                    @as(f32, @floatFromInt(head.color[3])) *
                        std.math.clamp(sample.trail_alpha, 0.0, 1.0),
                ));
                if (alpha == 0) break :trail;

                result.quads[result.len] = .{
                    .pos = .{
                        line.from[0] - (basis_y[0] * line.thickness / 2),
                        line.from[1] - (basis_y[1] * line.thickness / 2),
                    },
                    .size = .{ length, line.thickness },
                    .basis_x = basis_x,
                    .basis_y = basis_y,
                    .glyph_pos = glyph.pos,
                    .glyph_size = glyph.size,
                    .color = .{
                        head.color[0],
                        head.color[1],
                        head.color[2],
                        alpha,
                    },
                };
                result.len += 1;
            }

            result.quads[result.len] = .{
                .pos = sample.rect.pos,
                .size = sample.rect.size,
                .basis_x = .{ 1, 0 },
                .basis_y = .{ 0, 1 },
                .glyph_pos = head.glyph.pos,
                .glyph_size = head.glyph.size,
                .color = head.color,
            };
            result.len += 1;

            return result;
        }

        /// Issue the draw step for the animated cursor quads. The caller is
        /// responsible for checking `quads.len` and for calling this at the
        /// right point relative to the text, per `quads.over_text`.
        fn drawCursorQuads(
            self: *const Self,
            pass: *RenderPass,
            frame: *const FrameState,
            quads: CursorQuads,
        ) void {
            pass.step(.{
                .pipeline = self.shaders.pipelines.cursor,
                .uniforms = frame.uniforms.buffer,
                .buffers = &.{frame.cursor.buffer},
                .textures = &.{frame.grayscale},
                .draw = .{
                    .type = .triangle_strip,
                    .vertex_count = 4,
                    .instance_count = quads.len,
                },
            });
        }

        /// Start only the narrowest possible local-echo shape: one scalar at
        /// the recorded cursor, echoed in that exact cell, with the terminal
        /// cursor advanced by its grid width. Anything else is output (or a
        /// terminal rewrite) and is intentionally never animated.
        fn resolveInputGlyphIntent(
            self: *Self,
            shared: *renderer.State,
            event: inputmotion.Event,
            preedit: bool,
            rebuild: bool,
            screen_generation: usize,
        ) ?inputmotion.Event {
            const reject = struct {
                fn run(shared_: *renderer.State, generation: u64) void {
                    shared_.mutex.lockUncancelable(global.io());
                    defer shared_.mutex.unlock(global.io());
                    _ = shared_.input_motion.takeIfGeneration(generation);
                }
            }.run;
            if (preedit or rebuild or event.kind != .text or event.scalar_len != 1) {
                shared.mutex.lockUncancelable(global.io());
                defer shared.mutex.unlock(global.io());
                shared.input_motion.reset();
                return null;
            }
            const state = &self.terminal_state;
            if (event.source_row >= state.rows or event.source_col >= state.cols or
                @intFromEnum(state.screen) != event.screen or
                event.screen_generation != screen_generation)
            {
                reject(shared, event.generation);
                return null;
            }
            const row = state.row_data.items(.cells)[event.source_row];
            const cell = row.get(event.source_col).raw;
            const cursor = state.cursor.viewport orelse {
                reject(shared, event.generation);
                return null;
            };
            const width = cell.gridWidth();
            if (!inputmotion.matchesSingleScalar(
                event,
                cell.codepoint(),
                cursor.x,
                cursor.y,
                width,
            )) {
                // This dirty snapshot is not the echo we were waiting for;
                // drop it rather than allowing a stale key to block later
                // local input indefinitely.
                reject(shared, event.generation);
                return null;
            }

            // Only one changed row, and it must be the source row, can
            // plausibly be this local echo. Multiple dirty rows means scroll,
            // redraw, or concurrent output: conservatively reject it.
            const dirty_rows = blk: {
                var count: usize = 0;
                for (state.row_data.items(.dirty)) |dirty| {
                    if (dirty) count += 1;
                }
                break :blk count;
            };
            if (dirty_rows != 1 or !state.row_data.items(.dirty)[event.source_row]) {
                reject(shared, event.generation);
                return null;
            }
            shared.mutex.lockUncancelable(global.io());
            defer shared.mutex.unlock(global.io());
            if (shared.input_motion.takeIfGeneration(event.generation) == null) return null;
            return event;
        }

        /// Confirm a backward delete only after the terminal snapshot has
        /// completed. This rejects all output-like rewrites and retains the
        /// old text sprite from the parallel text-only cache before the row
        /// clear in rebuildCells can destroy it.
        fn resolveInputDecayIntent(
            self: *Self,
            shared: *renderer.State,
            event: inputmotion.Event,
            screen_generation: usize,
        ) ?inputmotion.Event {
            const reject = struct {
                fn run(shared_: *renderer.State, generation: u64) void {
                    shared_.mutex.lockUncancelable(global.io());
                    defer shared_.mutex.unlock(global.io());
                    _ = shared_.input_motion.takeIfGeneration(generation);
                }
            }.run;
            const state = &self.terminal_state;
            if (event.source_row >= state.rows or event.target_col >= state.cols or
                @intFromEnum(state.screen) != event.screen or
                event.screen_generation != screen_generation or
                event.source_col == 0)
            {
                reject(shared, event.generation);
                return null;
            }
            const cursor = state.cursor.viewport orelse {
                reject(shared, event.generation);
                return null;
            };
            const cell = state.row_data.items(.cells)[event.source_row].get(event.target_col).raw;
            if (!inputmotion.matchesBackwardDelete(
                event,
                @intCast(@intFromEnum(state.screen)),
                cell.codepoint(),
                cursor.x,
                cursor.y,
            )) {
                reject(shared, event.generation);
                return null;
            }
            var dirty_rows: usize = 0;
            for (state.row_data.items(.dirty)) |dirty| {
                if (dirty) dirty_rows += 1;
            }
            if (dirty_rows != 1 or !state.row_data.items(.dirty)[event.source_row]) {
                reject(shared, event.generation);
                return null;
            }
            shared.mutex.lockUncancelable(global.io());
            defer shared.mutex.unlock(global.io());
            if (shared.input_motion.takeIfGeneration(event.generation) == null) return null;
            return event;
        }

        /// A commit is not a cursor/newline heuristic. It is emitted only
        /// when an Enter accepted in OSC 133 B later observes OSC 133 C on
        /// the same screen generation. Shells can put the linefeed in the
        /// terminal before C, hence the deliberately tiny retry window.
        fn resolveInputCommitIntent(
            self: *Self,
            shared: *renderer.State,
            event: inputmotion.Event,
            screen_generation: usize,
            semantic_output: bool,
        ) ?inputmotion.Event {
            const state = &self.terminal_state;
            const same_screen = @intFromEnum(state.screen) == event.screen;
            if (inputmotion.matchesSemanticCommit(
                event,
                @intCast(@intFromEnum(state.screen)),
                screen_generation,
                semantic_output,
            )) {
                // The input row must still be visible and must not be a
                // broad redraw. This makes the cached text-row snapshot a
                // safe source for a transient overlay.
                if (event.source_row >= state.rows or
                    state.dirty == .full or
                    self.cells.text_rows.len <= event.source_row)
                {
                    shared.mutex.lockUncancelable(global.io());
                    defer shared.mutex.unlock(global.io());
                    _ = shared.input_motion.takeIfGeneration(event.generation);
                    return null;
                }
                shared.mutex.lockUncancelable(global.io());
                defer shared.mutex.unlock(global.io());
                if (shared.input_motion.takeIfGeneration(event.generation) == null) return null;
                return event;
            }

            shared.mutex.lockUncancelable(global.io());
            defer shared.mutex.unlock(global.io());
            // A screen/generation barrier is terminal output, never a delayed
            // semantic command transition. Drop it immediately. Otherwise
            // retain just three dirty snapshots for the common LF -> OSC C
            // ordering, then expire and unblock newer input.
            if (!same_screen or event.screen_generation != screen_generation) {
                _ = shared.input_motion.takeIfGeneration(event.generation);
                return null;
            }
            _ = shared.input_motion.retryCommitIfGeneration(event.generation);
            return null;
        }

        /// Caller holds draw_mutex. This is deliberately separate from
        /// resolveInputGlyphIntent so it never reaches for State.mutex.
        fn startInputGlyphMotion(self: *Self, event: inputmotion.Event) void {
            self.input_glyph_motion = .{
                .start = .now(global.io(), .awake),
                .generation = event.generation,
                .row = event.source_row,
                .col = event.source_col,
            };
            self.input_motion_active.store(true, .release);
        }

        const InputGlyphQuads = struct {
            quads: [inputmotion.max_overlay_quads]shaderpkg.InputGlyphQuad = undefined,
            len: usize = 0,

            fn append(self: *InputGlyphQuads, quad: shaderpkg.InputGlyphQuad) void {
                assert(self.len < self.quads.len);
                self.quads[self.len] = quad;
                self.len += 1;
            }

            fn appendSlice(self: *InputGlyphQuads, quads: []const shaderpkg.InputGlyphQuad) void {
                assert(self.len + quads.len <= self.quads.len);
                @memcpy(self.quads[self.len .. self.len + quads.len], quads);
                self.len += quads.len;
            }
        };

        const SampledInputGlyph = struct {
            quad: shaderpkg.InputGlyphQuad,
            active: bool,
        };

        /// Returns the frame-local animated quad. Rise is 5px -> 0px over
        /// the configured duration using cubic ease-out.
        fn sampleInputGlyphMotion(self: *Self) ?SampledInputGlyph {
            const motion = &(self.input_glyph_motion orelse return null);
            var quad = motion.quad orelse return null;
            if (motion.force_static) {
                quad.opacity = 255;
                return .{ .quad = quad, .active = false };
            }
            const now = std.Io.Timestamp.now(global.io(), .awake);
            const elapsed: f64 = @floatFromInt(motion.start.durationTo(now).nanoseconds);
            const elapsed_ms: f32 = @floatCast(elapsed / std.time.ns_per_ms);
            const duration: f32 = @floatFromInt(self.config.input_motion_duration);
            const t: f32 = if (duration == 0) 1 else std.math.clamp(elapsed_ms / duration, 0.0, 1.0);
            const p = inputmotion.riseProgressScaled(elapsed_ms, duration);
            quad.pos[1] += 5.0 * self.config.input_motion_intensity * (1.0 - p);
            // Intensity controls how visible the arrival is, not the final
            // glyph. At rest the held overlay is fully opaque so it remains
            // visually identical until ordinary CellText replaces it.
            quad.opacity = @intFromFloat(255.0 * (1.0 - self.config.input_motion_intensity * (1.0 - p)));
            return .{ .quad = quad, .active = t < 1.0 };
        }

        /// Retain one old glyph and render a small deterministic fan of
        /// shrinking/rising afterimages. The fixed five-instance budget is
        /// enough to read as a restrained shatter without per-key allocation.
        fn startInputDecayMotion(self: *Self, event: inputmotion.Event) void {
            const glyph = self.cells.textGlyph(event.source_row, event.target_col) orelse return;
            const cell_width: f32 = @floatFromInt(self.grid_metrics.cell_width);
            const cell_height: f32 = @floatFromInt(self.grid_metrics.cell_height);
            self.input_decay_motion = .{
                .quad = .{
                    .pos = .{
                        @as(f32, @floatFromInt(event.target_col)) * cell_width + @as(f32, @floatFromInt(glyph.bearings[0])),
                        @as(f32, @floatFromInt(event.source_row)) * cell_height + cell_height - @as(f32, @floatFromInt(glyph.bearings[1])),
                    },
                    .glyph_pos = glyph.glyph_pos,
                    .glyph_size = glyph.glyph_size,
                    .grid_pos = glyph.grid_pos,
                    .color = glyph.color,
                    .atlas = glyph.atlas,
                    .bools = .{ .no_min_contrast = glyph.bools.no_min_contrast },
                    .draw_size = .{
                        @floatFromInt(glyph.glyph_size[0]),
                        @floatFromInt(glyph.glyph_size[1]),
                    },
                },
                .start = .now(global.io(), .awake),
            };
            self.input_motion_active.store(true, .release);
        }

        /// Snapshot text-only sprites before rebuildCells clears the prior
        /// input row. Normal committed text is rebuilt underneath; these
        /// copies drift upward by a few pixels and fade as a restrained carry.
        fn startInputCommitMotion(self: *Self, event: inputmotion.Event) void {
            if (event.source_row >= self.cells.text_rows.len) return;
            const cell_width: f32 = @floatFromInt(self.grid_metrics.cell_width);
            const cell_height: f32 = @floatFromInt(self.grid_metrics.cell_height);
            var motion: @TypeOf(self.input_commit_motion.?) = undefined;
            motion.len = 0;
            for (self.cells.text_rows[event.source_row].items) |glyph| {
                const x = glyph.grid_pos[0];
                if (x < event.input_col_start or x >= event.input_col_end) continue;
                if (motion.len == motion.quads.len) break;
                motion.quads[motion.len] = .{
                    .pos = .{
                        @as(f32, @floatFromInt(x)) * cell_width + @as(f32, @floatFromInt(glyph.bearings[0])),
                        @as(f32, @floatFromInt(event.source_row)) * cell_height + cell_height - @as(f32, @floatFromInt(glyph.bearings[1])),
                    },
                    .glyph_pos = glyph.glyph_pos,
                    .glyph_size = glyph.glyph_size,
                    .grid_pos = glyph.grid_pos,
                    .color = glyph.color,
                    .atlas = glyph.atlas,
                    .bools = .{ .no_min_contrast = glyph.bools.no_min_contrast },
                    .opacity = 255,
                    .draw_size = .{
                        @floatFromInt(glyph.glyph_size[0]),
                        @floatFromInt(glyph.glyph_size[1]),
                    },
                };
                motion.len += 1;
            }
            if (motion.len == 0) return;
            motion.start = .now(global.io(), .awake);
            self.input_commit_motion = motion;
            self.input_motion_active.store(true, .release);
        }

        const DecayGlyphQuads = struct {
            quads: [inputmotion.decay_quad_count]shaderpkg.InputGlyphQuad,
            len: usize,
        };

        fn sampleInputDecayMotion(self: *Self) ?DecayGlyphQuads {
            const motion = &(self.input_decay_motion orelse return null);
            const now = std.Io.Timestamp.now(global.io(), .awake);
            const elapsed: f64 = @floatFromInt(motion.start.durationTo(now).nanoseconds);
            const duration: f32 = @floatFromInt(self.config.input_motion_duration);
            const p = inputmotion.decayProgressScaled(@floatCast(elapsed / std.time.ns_per_ms), duration * 1.2);
            if (p >= 1.0) {
                self.input_decay_motion = null;
                return null;
            }
            var result: DecayGlyphQuads = undefined;
            // Head plus four fixed afterimages. Their offsets are intentionally
            // deterministic so deletion is stable and free of RNG state.
            const offsets: [inputmotion.decay_quad_count][2]f32 = .{ .{ 0, 0 }, .{ -1.6, -2.2 }, .{ 1.3, -3.6 }, .{ -2.7, -5.2 }, .{ 2.5, -6.8 } };
            for (offsets, 0..) |offset, i| {
                var quad = motion.quad;
                const age = std.math.clamp(p + @as(f32, @floatFromInt(i)) * 0.10, 0.0, 1.0);
                const scale = 1.0 - 0.42 * age * self.config.input_motion_intensity;
                quad.pos[0] += offset[0] * p * self.config.input_motion_intensity;
                quad.pos[1] -= (7.0 + offset[1]) * p * self.config.input_motion_intensity;
                quad.draw_size = .{
                    @max(1.0, quad.draw_size[0] * scale),
                    @max(1.0, quad.draw_size[1] * scale),
                };
                const afterimage_alpha: f32 = if (i == 0) 1.0 else 0.38;
                quad.opacity = @intFromFloat(255.0 * (1.0 - age) * afterimage_alpha * self.config.input_motion_intensity);
                result.quads[i] = quad;
            }
            result.len = offsets.len;
            return result;
        }

        const CommitGlyphQuads = struct {
            quads: [inputmotion.commit_quad_count]shaderpkg.InputGlyphQuad,
            len: usize,
        };

        fn sampleInputCommitMotion(self: *Self) ?CommitGlyphQuads {
            const motion = &(self.input_commit_motion orelse return null);
            const now = std.Io.Timestamp.now(global.io(), .awake);
            const elapsed: f64 = @floatFromInt(motion.start.durationTo(now).nanoseconds);
            const elapsed_ms: f32 = @floatCast(elapsed / std.time.ns_per_ms);
            const duration: f32 = @floatFromInt(self.config.input_motion_duration);
            const p = inputmotion.commitProgressScaled(elapsed_ms, duration * 1.4);
            if (p >= 1.0) {
                self.input_commit_motion = null;
                return null;
            }
            var result: CommitGlyphQuads = .{ .quads = undefined, .len = motion.len };
            for (motion.quads[0..motion.len], 0..) |base, i| {
                var quad = base;
                // A slight stagger makes the carry read left-to-right without
                // obscuring the stable committed row below it.
                const stagger = @as(f32, @floatFromInt(i % 6)) * 0.035;
                const age = std.math.clamp((p - stagger) / (1.0 - stagger), 0.0, 1.0);
                quad.pos[1] -= 4.0 * age * self.config.input_motion_intensity;
                quad.pos[0] += @as(f32, @floatFromInt(@as(i32, @intCast(i % 3)) - 1)) * 0.45 * age * self.config.input_motion_intensity;
                quad.opacity = @intFromFloat(96.0 * (1.0 - age) * self.config.input_motion_intensity);
                result.quads[i] = quad;
            }
            return result;
        }

        /// Caller holds draw_mutex. Full redraw, resize, focus and config
        /// changes invalidate pixel-space overlay anchors.
        fn clearInputMotion(self: *Self) void {
            self.input_glyph_motion = null;
            self.input_decay_motion = null;
            self.input_commit_motion = null;
            self.input_motion_active.store(false, .release);
        }

        /// Stop visual motion without dropping the sole rendering of a
        /// withheld typed cell. Decay/commit overlays are afterimages over
        /// normally rebuilt text and can be removed immediately.
        fn freezeTypedInputMotion(self: *Self) void {
            var visual_changed = self.input_decay_motion != null or
                self.input_commit_motion != null;
            if (self.input_glyph_motion) |*motion| {
                if (inputmotion.retainTypedOverlayAfterCancellation(motion.quad != null)) {
                    visual_changed = visual_changed or !motion.force_static;
                    motion.force_static = true;
                } else {
                    self.input_glyph_motion = null;
                }
            }
            self.input_decay_motion = null;
            self.input_commit_motion = null;
            self.input_motion_active.store(false, .release);
            // Cancellation runs before drawFrame's early-out decision. Make
            // sure the final static glyph/removal is actually presented even
            // when no terminal cells changed in this frame.
            if (visual_changed) self.cells_rebuilt = true;
        }

        /// Draw-owned, immediate accessibility cancellation. This runs before
        /// deciding whether the current frame needs redrawing, so a runtime
        /// macOS Reduce Motion toggle cannot leave a floating caret or input
        /// overlay on screen. The saved legacy cell restores block inversion
        /// and normal cursor layering in the same frame.
        fn cancelMotionForReduceMotion(self: *Self) void {
            if (self.reduceMotion(true)) self.freezeTypedInputMotion();
            if (!self.reduceMotion(false)) return;

            const state = &self.cursor_motion;
            // `legacy_cell` is a retained sprite, not proof that the cursor
            // is currently visible: blink-off, preedit, or an off-viewport
            // cursor clears `head`. Never resurrect a stale hidden cursor.
            if (state.head != null) if (state.legacy_cell) |cell| {
                self.cells.setCursor(cell, state.legacy_style);
                if (state.block_text_target) |target| {
                    self.uniforms.cursor_pos = target.pos;
                    self.uniforms.bools.cursor_wide = target.wide;
                } else {
                    self.uniforms.cursor_pos = .{
                        std.math.maxInt(u16),
                        std.math.maxInt(u16),
                    };
                    self.uniforms.bools.cursor_wide = false;
                }
                self.cells_rebuilt = true;
            };
            state.head = null;
            state.legacy_cell = null;
            state.legacy_style = null;
            state.trail = null;
            state.block_text_target = null;
            state.pending = false;
            state.snap = true;
            self.cursor_motion_active.store(false, .release);
        }

        // Callback from the graphics API when a frame is completed.
        pub fn frameCompleted(
            self: *Self,
            health: Health,
        ) void {
            // If our health value hasn't changed, then we do nothing. We don't
            // do a cmpxchg here because strict atomicity isn't important.
            if (self.health.load(.seq_cst) != health) {
                self.health.store(health, .seq_cst);

                // Our health value changed, so we notify the surface so that it
                // can do something about it.
                _ = self.surface_mailbox.push(.{
                    .renderer_health = health,
                }, .{ .forever = {} });
            }

            // Always release our semaphore. The swap chain is
            // guaranteed to exist here: it is only torn down after
            // waiting for all in-flight frames to complete, and this
            // callback is what signals that completion.
            self.swap_chain.?.releaseFrame();
        }

        /// Call this any time the background image path changes.
        ///
        /// Caller must hold the draw mutex.
        fn prepBackgroundImage(self: *Self) !void {
            // Then we try to load the background image if we have a path.
            if (self.config.bg_image) |p| load_background: {
                const path = switch (p) {
                    .required, .optional => |slice| slice,
                };

                // Open the file
                var file = std.Io.Dir.openFileAbsolute(
                    global.io(),
                    path,
                    .{},
                ) catch |err| {
                    log.warn(
                        "error opening background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer file.close(global.io());

                // Read it
                const contents = compat_file.readToEndAlloc(
                    file,
                    self.alloc,
                    std.math.maxInt(u32), // Max size of 4 GiB, for now.
                ) catch |err| {
                    log.warn(
                        "error reading background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer self.alloc.free(contents);

                // Figure out what type it probably is.
                const file_type = switch (FileType.detect(contents)) {
                    .unknown => FileType.guessFromExtension(
                        std.fs.path.extension(path),
                    ),
                    else => |t| t,
                };

                // Decode it if we know how.
                const image_data = switch (file_type) {
                    .png => try wuffs.png.decode(self.alloc, contents),
                    .jpeg => try wuffs.jpeg.decode(self.alloc, contents),
                    .unknown => {
                        log.warn(
                            "Cannot determine file type for background image file \"{s}\"!",
                            .{path},
                        );
                        break :load_background;
                    },
                    else => |f| {
                        log.warn(
                            "Unsupported file type {} for background image file \"{s}\"!",
                            .{ f, path },
                        );
                        break :load_background;
                    },
                };

                const image: imagepkg.Image = .{
                    .pending = .{
                        .width = image_data.width,
                        .height = image_data.height,
                        .pixel_format = .rgba,
                        .data = image_data.data.ptr,
                    },
                };

                // If we have an existing background image, replace it.
                // Otherwise, set this as our background image directly.
                if (self.bg_image) |*img| {
                    img.markForReplace(self.alloc, image);
                } else {
                    self.bg_image = image;
                }
            } else {
                // If we don't have a background image path, mark our
                // background image for unload if we currently have one.
                if (self.bg_image) |*img| img.markForUnload();
            }
        }

        fn uploadBackgroundImage(self: *Self) !void {
            // Make sure our bg image is uploaded if it needs to be.
            if (self.bg_image) |*bg| {
                if (bg.isUnloading()) {
                    bg.deinit(self.alloc);
                    self.bg_image = null;
                    return;
                }
                if (bg.isPending()) try bg.upload(self.alloc, &self.api);
            }
        }

        /// Update the configuration.
        pub fn changeConfig(self: *Self, config: *DerivedConfig) !void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We always redo the font shaper in case font features changed. We
            // could check to see if there was an actual config change but this is
            // easier and rare enough to not cause performance issues.
            {
                var font_shaper = try font.Shaper.init(self.alloc, .{
                    .features = config.font_features.items,
                });
                errdefer font_shaper.deinit();
                self.font_shaper.deinit();
                self.font_shaper = font_shaper;
            }

            // We also need to reset the shaper cache so shaper info
            // from the previous font isn't reused for the new font.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Set our new minimum contrast
            self.uniforms.min_contrast = config.min_contrast;

            // Set our new color space and blending
            self.uniforms.bools.use_display_p3 = config.colorspace == .@"display-p3";
            self.uniforms.bools.use_linear_blending = config.blending.isLinear();
            self.uniforms.bools.use_linear_correction = config.blending == .@"linear-corrected";

            const bg_image_config_changed =
                self.config.bg_image_fit != config.bg_image_fit or
                self.config.bg_image_position != config.bg_image_position or
                self.config.bg_image_repeat != config.bg_image_repeat or
                self.config.bg_image_opacity != config.bg_image_opacity;

            const bg_image_changed =
                if (self.config.bg_image) |old|
                    if (config.bg_image) |new|
                        !old.equal(new)
                    else
                        true
                else
                    config.bg_image != null;

            const old_blending = self.config.blending;
            const custom_shaders_changed = !self.config.custom_shaders.equal(config.custom_shaders);

            self.config.deinit();
            self.config = config.*;

            // Apply the new cursor motion settings. Note that switching to
            // `none` needs no teardown: the `markDirty` below forces a full
            // rebuild, which puts the cursor back into the cell_text
            // pipeline, so it can't vanish. Switching the other way is the
            // same in reverse.
            if (cursorMotionStyle(config.cursor_motion)) |style| {
                self.cursor_motion.anim.setStyle(style);
            }
            self.cursor_motion.anim.setDuration(
                @floatFromInt(config.cursor_motion_duration),
            );
            self.cursor_motion.head = null;
            self.cursor_motion.snap = true;
            self.cursor_motion_active.store(false, .release);
            // Config reload normally forces a rebuild immediately. Retain a
            // withheld typed glyph statically until that rebuild, even if a
            // runtime caller observes the new disabled/zero-intensity state
            // before it can run.
            if (!config.input_motion or config.input_motion_intensity == 0) {
                self.freezeTypedInputMotion();
            } else {
                self.clearInputMotion();
            }

            // If our background image path changed, prepare the new bg image.
            if (bg_image_changed) try self.prepBackgroundImage();

            // If our background image config changed, update the vertex buffer.
            if (bg_image_config_changed) self.updateBgImageBuffer();

            // Reset our viewport to force a rebuild, in case of a font change.
            self.markDirty();

            const blending_changed = old_blending != config.blending;

            if (blending_changed) {
                // We update our API's blending mode.
                self.api.blending = config.blending;
                // And indicate that we need to reinitialize our shaders.
                self.reinitialize_shaders = true;
                // And indicate that our swap chain targets need to
                // be re-created to account for the new blending mode.
                self.target_config_modified +%= 1;
            }

            if (custom_shaders_changed) {
                self.reinitialize_shaders = true;
            }
        }

        /// Resize the screen.
        pub fn setScreenSize(
            self: *Self,
            size: renderer.Size,
        ) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We only actually need the padding from this,
            // everything else is derived elsewhere.
            self.size.padding = size.padding;

            self.updateScreenSizeUniforms();

            log.debug("screen size size={}", .{size});
        }

        /// Update uniforms that are based on the screen size.
        ///
        /// Caller must hold the draw mutex.
        fn updateScreenSizeUniforms(self: *Self) void {
            const terminal_size = self.size.terminal();

            // Blank space around the grid.
            const blank: renderer.Padding = self.size.screen.blankPadding(
                self.size.padding,
                .{
                    .columns = self.cells.size.columns,
                    .rows = self.cells.size.rows,
                },
                .{
                    .width = self.grid_metrics.cell_width,
                    .height = self.grid_metrics.cell_height,
                },
            ).add(self.size.padding);

            // Setup our uniforms
            self.uniforms.projection_matrix = math.ortho2d(
                -1 * @as(f32, @floatFromInt(self.size.padding.left)),
                @floatFromInt(terminal_size.width + self.size.padding.right),
                @floatFromInt(terminal_size.height + self.size.padding.bottom),
                -1 * @as(f32, @floatFromInt(self.size.padding.top)),
            );
            self.uniforms.grid_padding = .{
                @floatFromInt(blank.top),
                @floatFromInt(blank.right),
                @floatFromInt(blank.bottom),
                @floatFromInt(blank.left),
            };
            self.uniforms.screen_size = .{
                @floatFromInt(self.size.screen.width),
                @floatFromInt(self.size.screen.height),
            };
        }

        /// Update the background image vertex buffer (CPU-side).
        ///
        /// This should be called if and when configs change that
        /// could affect the background image.
        ///
        /// Caller must hold the draw mutex.
        fn updateBgImageBuffer(self: *Self) void {
            self.bg_image_buffer = .{
                .opacity = self.config.bg_image_opacity,
                .info = .{
                    .position = switch (self.config.bg_image_position) {
                        .@"top-left" => .tl,
                        .@"top-center" => .tc,
                        .@"top-right" => .tr,
                        .@"center-left" => .ml,
                        .@"center-center", .center => .mc,
                        .@"center-right" => .mr,
                        .@"bottom-left" => .bl,
                        .@"bottom-center" => .bc,
                        .@"bottom-right" => .br,
                    },
                    .fit = switch (self.config.bg_image_fit) {
                        .contain => .contain,
                        .cover => .cover,
                        .stretch => .stretch,
                        .none => .none,
                    },
                    .repeat = self.config.bg_image_repeat,
                },
            };
            // Signal that the buffer was modified.
            self.bg_image_buffer_modified +%= 1;
        }

        /// Update custom shader uniforms that depend on terminal state.
        ///
        /// This should be called in `updateFrame` when terminal state changes.
        fn updateCustomShaderUniformsFromState(self: *Self) void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            // Only update when terminal state is dirty.
            if (self.terminal_state.dirty == .false) return;

            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;
            const colors: *const terminal.RenderState.Colors = &self.terminal_state.colors;

            // 256-color palette
            for (colors.palette, 0..) |color, i| {
                uniforms.palette[i] = .{
                    @as(f32, @floatFromInt(color.r)) / 255.0,
                    @as(f32, @floatFromInt(color.g)) / 255.0,
                    @as(f32, @floatFromInt(color.b)) / 255.0,
                    1.0,
                };
            }

            // Background color
            uniforms.background_color = .{
                @as(f32, @floatFromInt(colors.background.r)) / 255.0,
                @as(f32, @floatFromInt(colors.background.g)) / 255.0,
                @as(f32, @floatFromInt(colors.background.b)) / 255.0,
                1.0,
            };

            // Foreground color
            uniforms.foreground_color = .{
                @as(f32, @floatFromInt(colors.foreground.r)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.g)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.b)) / 255.0,
                1.0,
            };

            // Cursor color
            if (colors.cursor) |cursor_color| {
                uniforms.cursor_color = .{
                    @as(f32, @floatFromInt(cursor_color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.b)) / 255.0,
                    1.0,
                };
            }

            // NOTE: the following could be optimized to follow a change in
            // config for a slight optimization however this is only 12 bytes
            // each being updated and likely isn't a cause for concern

            // Cursor text color
            if (self.config.cursor_text) |cursor_text| {
                uniforms.cursor_text = .{
                    @as(f32, @floatFromInt(cursor_text.color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection background color
            if (self.config.selection_background) |selection_bg| {
                uniforms.selection_background_color = .{
                    @as(f32, @floatFromInt(selection_bg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection foreground color
            if (self.config.selection_foreground) |selection_fg| {
                uniforms.selection_foreground_color = .{
                    @as(f32, @floatFromInt(selection_fg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.b)) / 255.0,
                    1.0,
                };
            }

            // Cursor visibility
            uniforms.cursor_visible = @intFromBool(self.terminal_state.cursor.visible);

            // Cursor style
            const cursor_style: renderer.CursorStyle = .fromTerminal(self.terminal_state.cursor.visual_style);
            uniforms.previous_cursor_style = uniforms.current_cursor_style;
            uniforms.current_cursor_style = @as(i32, @intFromEnum(cursor_style));
        }

        /// Update per-frame custom shader uniforms.
        ///
        /// This should be called exactly once per frame, inside `drawFrame`.
        fn updateCustomShaderUniformsForFrame(self: *Self) !void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;

            const now: std.Io.Timestamp = .now(global.io(), .awake);
            defer self.last_frame_time = now;
            const first_frame_time = self.first_frame_time orelse t: {
                self.first_frame_time = now;
                break :t now;
            };
            const last_frame_time = self.last_frame_time orelse now;

            const since_ns: f32 = @floatFromInt(first_frame_time.durationTo(now).nanoseconds);
            uniforms.time = since_ns / std.time.ns_per_s;

            const delta_ns: f32 = @floatFromInt(last_frame_time.durationTo(now).nanoseconds);
            uniforms.time_delta = delta_ns / std.time.ns_per_s;

            uniforms.frame += 1;

            const screen = self.size.screen;
            const padding = self.size.padding;

            uniforms.resolution = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
            };
            uniforms.channel_resolution[0] = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
                0,
            };

            if (self.cursorPixelRect()) |cursor| {
                // `cursor.rect` is in the renderer's native top-left pixel
                // space, relative to the top-left of the grid. Custom
                // shaders want it relative to the top-left of the screen,
                // so we add the window padding back in. Note the rect
                // already has the glyph bearings folded into it.
                const pixel_x: f32 =
                    cursor.rect.pos[0] + @as(f32, @floatFromInt(padding.left));
                const top: f32 =
                    cursor.rect.pos[1] + @as(f32, @floatFromInt(padding.top));

                // Custom shaders want the +Y edge of the cursor. If +Y is
                // down that's the bottom edge measured from the top of the
                // screen; if +Y is up it's the top edge measured from the
                // *bottom* of the screen.
                const pixel_y: f32 = if (GraphicsAPI.custom_shader_y_is_down)
                    top + cursor.rect.size[1]
                else
                    @as(f32, @floatFromInt(screen.height)) - top;

                const new_cursor: [4]f32 = .{
                    pixel_x,
                    pixel_y,
                    cursor.rect.size[0],
                    cursor.rect.size[1],
                };
                const cursor_color: [4]f32 = .{
                    @as(f32, @floatFromInt(cursor.color[0])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[1])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[2])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[3])) / 255.0,
                };

                const cursor_changed: bool =
                    !std.meta.eql(new_cursor, uniforms.current_cursor) or
                    !std.meta.eql(cursor_color, uniforms.current_cursor_color);

                if (cursor_changed) {
                    uniforms.previous_cursor = uniforms.current_cursor;
                    uniforms.previous_cursor_color = uniforms.current_cursor_color;
                    uniforms.current_cursor = new_cursor;
                    uniforms.current_cursor_color = cursor_color;
                    uniforms.cursor_change_time = uniforms.time;
                }
            }

            // Update focus uniforms
            uniforms.focus = @intFromBool(self.focused);

            // If we need to update the time our focus state changed
            // then update it to our current frame time. This may not be
            // exactly correct since it is frame time, not exact focus
            // time, but focus time on its own isn't exactly correct anyways
            // since it comes async from a message.
            if (self.custom_shader_focused_changed and self.focused) {
                uniforms.time_focus = uniforms.time;
                self.custom_shader_focused_changed = false;
            }
        }

        /// The rect and color of the cursor as it will be drawn this frame,
        /// in the renderer's native top-left pixel space (relative to the
        /// top-left of the grid, before the projection matrix applies the
        /// window padding). Null if no cursor is being drawn.
        ///
        /// With cursor motion enabled the cursor is no longer in the cell
        /// buffer. Custom shaders deliberately receive the semantic target,
        /// not the in-between animated rect: otherwise every animation
        /// sample looks like a new cursor change and perpetually resets
        /// `cursor_change_time` (breaking shader ripples/aging effects).
        ///
        /// Caller must hold the draw mutex.
        fn cursorPixelRect(self: *Self) ?struct {
            rect: motionpkg.Rect,
            color: [4]u8,
        } {
            if (self.config.cursor_motion != .none and !self.reduceMotion(false)) {
                const head = self.cursor_motion.head orelse return null;
                return .{
                    .rect = self.cursor_motion.anim.target,
                    .color = head.color,
                };
            }

            const cursor = self.cells.getCursorGlyph() orelse return null;
            return .{
                .rect = cursorCellRect(cursor, self.grid_metrics),
                .color = cursor.color,
            };
        }

        /// Build the overlay as configured. Returns null if there is no
        /// overlay currently configured.
        fn rebuildOverlay(
            self: *Self,
            features: []const Overlay.Feature,
        ) Overlay.InitError!void {
            const alloc = self.alloc;

            // If we have no features enabled, don't build an overlay.
            // If we had a previous overlay, deallocate it.
            if (features.len == 0) {
                if (self.overlay) |*old| {
                    old.deinit(alloc);
                    self.overlay = null;
                }

                return;
            }

            // If we had a previous overlay, clear it. Otherwise, init.
            const overlay: *Overlay = overlay: {
                if (self.overlay) |*v| existing: {
                    // Verify that our overlay size matches our screen
                    // size as we know it now. If not, deinit and reinit.
                    // Note: these intCasts are always safe because z2d
                    // stores as i32 but we always init with a u32.
                    const width: u32 = @intCast(v.surface.getWidth());
                    const height: u32 = @intCast(v.surface.getHeight());
                    const term_size = self.size.terminal();
                    if (width != term_size.width or
                        height != term_size.height) break :existing;

                    // We also depend on cell size.
                    if (v.cell_size.width != self.size.cell.width or
                        v.cell_size.height != self.size.cell.height) break :existing;

                    // Everything matches, so we can just reset the surface
                    // and redraw.
                    v.reset();
                    break :overlay v;
                }

                // If we reached this point we want to reset our overlay.
                if (self.overlay) |*v| {
                    v.deinit(alloc);
                    self.overlay = null;
                }

                assert(self.overlay == null);
                const new: Overlay = try .init(alloc, self.size);
                self.overlay = new;
                break :overlay &self.overlay.?;
            };
            overlay.applyFeatures(
                alloc,
                &self.terminal_state,
                features,
            );
        }

        const PreeditRange = struct {
            y: terminal.size.CellCountInt,
            x: [2]terminal.size.CellCountInt,
            cp_offset: usize,
        };

        /// Convert the terminal state to GPU cells stored in CPU memory. These
        /// are then synced to the GPU in the next frame. This only updates CPU
        /// memory and doesn't touch the GPU.
        ///
        /// This requires the draw mutex.
        ///
        /// Dirty state on terminal state won't be reset by this.
        fn rebuildCells(
            self: *Self,
            preedit: ?renderer.State.Preedit,
            cursor_style_: ?renderer.CursorStyle,
            links: *const terminal.RenderState.CellSet,
        ) Allocator.Error!void {
            const state: *terminal.RenderState = &self.terminal_state;

            const grid_size_diff =
                self.cells.size.rows != state.rows or
                self.cells.size.columns != state.cols;

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = state.rows;
                new_size.columns = state.cols;
                try self.cells.resize(self.alloc, new_size);
                self.clearInputMotion();

                // Update our uniforms accordingly, otherwise
                // our background cells will be out of place.
                self.uniforms.grid_size = .{ new_size.columns, new_size.rows };

                // A reflow moves the cursor for reasons that have nothing
                // to do with the cursor, so snap rather than animate.
                self.cursor_motion.snap = true;
            }

            const rebuild = state.dirty == .full or grid_size_diff;
            if (rebuild) {
                // See Queue.reset: a full grid replacement has no safe
                // cursor anchor for a local input event.
                // If we are doing a full rebuild, then we clear the entire cell buffer.
                self.clearInputMotion();
                self.cells.reset();

                // We also reset our padding extension depending on the screen type
                switch (self.config.padding_color) {
                    .background => {},

                    // For extension, assume we are extending in all directions.
                    // For "extend" this may be disabled due to heuristics below.
                    .extend, .@"extend-always" => {
                        self.uniforms.padding_extend = .{
                            .up = true,
                            .down = true,
                            .left = true,
                            .right = true,
                        };
                    },
                }
            }

            // From this point on we never fail. We produce some kind of
            // working terminal state, even if incorrect.
            errdefer comptime unreachable;

            // Get our row data from our state
            const row_data = state.row_data.slice();
            const row_raws = row_data.items(.raw);
            const row_cells = row_data.items(.cells);
            const row_dirty = row_data.items(.dirty);
            const row_selection = row_data.items(.selection);
            const row_highlights = row_data.items(.highlights);

            // Any subsequent rebuild of the target row replaces the held
            // overlay with ordinary cell text. A full rebuild/resize is a
            // hard barrier.
            if (self.input_glyph_motion) |motion| {
                if (motion.quad != null and
                    (rebuild or (motion.row < row_dirty.len and row_dirty[motion.row])))
                {
                    self.input_glyph_motion = null;
                }
            }

            // If our cell contents buffer is shorter than the screen viewport,
            // we render the rows that fit, starting from the bottom. If instead
            // the viewport is shorter than the cell contents buffer, we align
            // the top of the viewport with the top of the contents buffer.
            const row_len: usize = @min(
                state.rows,
                self.cells.size.rows,
            );

            // Determine our x/y range for preedit. We don't want to render anything
            // here because we will render the preedit separately.
            const preedit_range: ?PreeditRange = if (preedit) |preedit_v| preedit: {
                // We base the preedit on the position of the cursor in the
                // viewport. If the cursor isn't visible in the viewport we
                // don't show it.
                const cursor_vp = state.cursor.viewport orelse
                    break :preedit null;

                // If our preedit row isn't dirty then we don't need the
                // preedit range. This also avoids an issue later where we
                // unconditionally add preedit cells when this is set.
                if (!rebuild and !row_dirty[cursor_vp.y]) break :preedit null;

                const range = preedit_v.range(
                    cursor_vp.x,
                    state.cols - 1,
                );
                break :preedit .{
                    .y = @intCast(cursor_vp.y),
                    .x = .{ range.start, range.end },
                    .cp_offset = range.cp_offset,
                };
            } else null;

            for (
                0..,
                row_raws[0..row_len],
                row_cells[0..row_len],
                row_dirty[0..row_len],
                row_selection[0..row_len],
                row_highlights[0..row_len],
            ) |y_usize, row, *cells, *dirty, selection, *highlights| {
                const y: terminal.size.CellCountInt = @intCast(y_usize);

                if (!rebuild) {
                    // Only rebuild if we are doing a full rebuild or this row is dirty.
                    if (!dirty.*) continue;

                    // Clear the cells if the row is dirty
                    self.cells.clear(y);
                }

                // Unmark the dirty state in our render state.
                dirty.* = false;

                self.rebuildRow(
                    y,
                    row,
                    cells,
                    preedit_range,
                    selection,
                    highlights,
                    links,
                ) catch |err| {
                    // This should never happen except under exceptional
                    // scenarios. In this case, we don't want to corrupt
                    // our render state so just clear this row and keep
                    // trying to finish it out.
                    log.warn("error building row y={} err={}", .{ y, err });
                    self.cells.clear(y);
                };
            }

            // If the shaped run did not yield a glyph at the anchored cell
            // (ligature/replacement/zero-width cases), nothing was withheld
            // from CellText. Cancel rather than leaving the draw timer live.
            if (self.input_glyph_motion) |motion| {
                if (inputmotion.cancelAfterRebuild(motion.quad != null)) {
                    self.input_glyph_motion = null;
                }
            }

            // Setup our cursor rendering information.
            cursor: {
                // Clear our cursor by default.
                self.cells.setCursor(null, null);
                self.uniforms.cursor_pos = .{
                    std.math.maxInt(u16),
                    std.math.maxInt(u16),
                };

                // Clear the animated cursor too. If it wasn't visible on
                // the previous pass either, then it's coming back from
                // being hidden and must snap into place rather than fly in
                // from wherever it was left.
                if (self.config.cursor_motion != .none) {
                    if (self.cursor_motion.head == null) {
                        self.cursor_motion.snap = true;
                    }
                    self.cursor_motion.head = null;
                    self.cursor_motion.legacy_cell = null;
                    self.cursor_motion.legacy_style = null;
                    self.cursor_motion.trail = null;
                    self.cursor_motion.block_text_target = null;
                    self.cursor_motion_active.store(false, .release);
                }

                // If the cursor isn't visible on the viewport, don't show
                // a cursor. Otherwise, get our cursor cell, because we may
                // need it for styling.
                const cursor_vp = state.cursor.viewport orelse break :cursor;
                const cursor_style: terminal.Style = cursor_style: {
                    const cells = state.row_data.items(.cells);
                    const cell = cells[cursor_vp.y].get(cursor_vp.x);
                    break :cursor_style if (cell.raw.hasStyling())
                        cell.style
                    else
                        .{};
                };

                // If we have preedit text, we don't setup a cursor
                if (preedit != null) break :cursor;

                // If there isn't a cursor visual style requested then
                // we don't render a cursor.
                const style = cursor_style_ orelse break :cursor;

                // Determine the cursor color.
                const cursor_color = cursor_color: {
                    // If an explicit cursor color was set by OSC 12, use that.
                    if (state.colors.cursor) |v| break :cursor_color v;

                    // Use our configured color if specified
                    if (self.config.cursor_color) |v| switch (v) {
                        .color => |color| break :cursor_color color.toTerminalRGB(),

                        inline .@"cell-foreground",
                        .@"cell-background",
                        => |_, tag| {
                            const fg_style = cursor_style.fg(.{
                                .default = state.colors.foreground,
                                .palette = &state.colors.palette,
                                .bold = self.config.bold_color,
                            });
                            const bg_style = cursor_style.bg(
                                &state.cursor.cell,
                                &state.colors.palette,
                            ) orelse state.colors.background;

                            break :cursor_color switch (tag) {
                                .color => unreachable,
                                .@"cell-foreground" => if (cursor_style.flags.inverse)
                                    bg_style
                                else
                                    fg_style,
                                .@"cell-background" => if (cursor_style.flags.inverse)
                                    fg_style
                                else
                                    bg_style,
                            };
                        },
                    };

                    break :cursor_color state.colors.foreground;
                };

                self.addCursor(
                    &state.cursor,
                    style,
                    cursor_color,
                );

                // If the cursor is visible then we set our uniforms. Animated
                // block cursors defer their text inversion to
                // `sampleCursorMotion`: while in transit there is no target
                // cell to recolor, and the sampled resting frame restores it.
                if (style == .block) {
                    const wide = state.cursor.cell.wide;

                    if (self.config.cursor_motion == .none or self.reduceMotion(false)) {
                        self.uniforms.cursor_pos = .{
                            // If we are a spacer tail of a wide cell, our cursor needs
                            // to move back one cell. The saturate is to ensure we don't
                            // overflow but this shouldn't happen with well-formed input.
                            switch (wide) {
                                .narrow, .spacer_head, .wide => cursor_vp.x,
                                .spacer_tail => cursor_vp.x -| 1,
                            },
                            @intCast(cursor_vp.y),
                        };

                        self.uniforms.bools.cursor_wide = switch (wide) {
                            .narrow, .spacer_head => false,
                            .wide, .spacer_tail => true,
                        };
                    }

                    const uniform_color = if (self.config.cursor_text) |txt| blk: {
                        // If cursor-text is set, then compute the correct color.
                        // Otherwise, use the background color.
                        if (txt == .color) {
                            // Use the color set by cursor-text, if any.
                            break :blk txt.color.toTerminalRGB();
                        }

                        const fg_style = cursor_style.fg(.{
                            .default = state.colors.foreground,
                            .palette = &state.colors.palette,
                            .bold = self.config.bold_color,
                        });
                        const bg_style = cursor_style.bg(
                            &state.cursor.cell,
                            &state.colors.palette,
                        ) orelse state.colors.background;

                        break :blk switch (txt) {
                            // If the cell is reversed, use the opposite cell color instead.
                            .@"cell-foreground" => if (cursor_style.flags.inverse)
                                bg_style
                            else
                                fg_style,
                            .@"cell-background" => if (cursor_style.flags.inverse)
                                fg_style
                            else
                                bg_style,
                            else => unreachable,
                        };
                    } else state.colors.background;

                    self.uniforms.cursor_color = .{
                        uniform_color.r,
                        uniform_color.g,
                        uniform_color.b,
                        255,
                    };
                }
            }

            // Setup our preedit text.
            if (preedit) |preedit_v| preedit: {
                const range = preedit_range orelse break :preedit;
                var x = range.x[0];
                for (preedit_v.codepoints[range.cp_offset..]) |cp| {
                    self.addPreeditCell(
                        cp,
                        .{ .x = x, .y = range.y },
                        state.colors.foreground,
                    ) catch |err| {
                        log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                            x,
                            range.y,
                            err,
                        });
                    };

                    x += if (cp.wide) 2 else 1;
                }
            }

            // Update that our cells rebuilt
            self.cells_rebuilt = true;

            // Log some things
            // log.debug("rebuildCells complete cached_runs={}", .{
            //     self.font_shaper_cache.count(),
            // });
        }

        fn rebuildRow(
            self: *Self,
            y: terminal.size.CellCountInt,
            row: terminal.page.Row,
            cells: *std.MultiArrayList(terminal.RenderState.Cell),
            preedit_range: ?PreeditRange,
            selection: ?[2]terminal.size.CellCountInt,
            highlights: *const std.ArrayList(terminal.RenderState.Highlight),
            links: *const terminal.RenderState.CellSet,
        ) !void {
            const state = &self.terminal_state;

            // If our viewport is wider than our cell contents buffer,
            // we still only process cells up to the width of the buffer.
            const cells_slice = cells.slice();
            const cells_len = @min(cells_slice.len, self.cells.size.columns);
            const cells_raw = cells_slice.items(.raw);
            const cells_style = cells_slice.items(.style);

            // On primary screen, we still apply vertical padding
            // extension under certain conditions we feel are safe.
            //
            // This helps make some scenarios look better while
            // avoiding scenarios we know do NOT look good.
            switch (self.config.padding_color) {
                // These already have the correct values set above.
                .background, .@"extend-always" => {},

                // Apply heuristics for padding extension.
                .extend => if (y == 0) {
                    self.uniforms.padding_extend.up = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                } else if (y == self.cells.size.rows - 1) {
                    self.uniforms.padding_extend.down = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                },
            }

            // Iterator of runs for shaping.
            var run_iter_opts: font.shape.RunOptions = .{
                .grid = self.font_grid,
                .cells = cells_slice,
                .selection = if (selection) |s| s else null,

                // We want to do font shaping as long as the cursor is
                // visible on this viewport.
                .cursor_x = cursor_x: {
                    const vp = state.cursor.viewport orelse break :cursor_x null;
                    if (vp.y != y) break :cursor_x null;
                    break :cursor_x vp.x;
                },
            };
            run_iter_opts.applyBreakConfig(self.config.font_shaping_break);
            var run_iter = self.font_shaper.runIterator(run_iter_opts);
            var shaper_run: ?font.shape.TextRun = try run_iter.next(self.alloc);
            var shaper_cells: ?[]const font.shape.Cell = null;
            var shaper_cells_i: usize = 0;

            for (
                0..,
                cells_raw[0..cells_len],
                cells_style[0..cells_len],
            ) |x, *cell, *managed_style| {
                // If this cell falls within our preedit range then we
                // skip this because preedits are setup separately.
                if (preedit_range) |range| preedit: {
                    // We're not on the preedit line, no actions necessary.
                    if (range.y != y) break :preedit;
                    // We're before the preedit range, no actions necessary.
                    if (x < range.x[0]) break :preedit;
                    // We're in the preedit range, skip this cell.
                    if (x <= range.x[1]) continue;
                    // After exiting the preedit range we need to catch
                    // the run position up because of the missed cells.
                    // In all other cases, no action is necessary.
                    if (x != range.x[1] + 1) break :preedit;

                    // Step the run iterator until we find a run that ends
                    // after the current cell, which will be the soonest run
                    // that might contain glyphs for our cell.
                    while (shaper_run) |run| {
                        if (run.offset + run.cells > x) break;
                        shaper_run = try run_iter.next(self.alloc);
                        shaper_cells = null;
                        shaper_cells_i = 0;
                    }

                    const run = shaper_run orelse break :preedit;

                    // If we haven't shaped this run, do so now.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    // Advance our index until we reach or pass
                    // our current x position in the shaper cells.
                    const shaper_cells_unwrapped = shaper_cells.?;
                    while (run.offset + shaper_cells_unwrapped[shaper_cells_i].x < x) {
                        shaper_cells_i += 1;
                    }
                }

                const wide = cell.wide;
                const style: terminal.Style = if (cell.hasStyling())
                    managed_style.*
                else
                    .{};

                // True if this cell is selected
                const selected: enum {
                    false,
                    selection,
                    search,
                    search_selected,
                } = selected: {
                    // Order below matters for precedence.

                    // Selection should take the highest precedence.
                    const x_compare = if (wide == .spacer_tail)
                        x -| 1
                    else
                        x;
                    if (selection) |sel| {
                        if (x_compare >= sel[0] and
                            x_compare <= sel[1]) break :selected .selection;
                    }

                    // If we're highlighted, then we're selected. In the
                    // future we want to use a different style for this
                    // but this to get started.
                    for (highlights.items) |hl| {
                        if (x_compare >= hl.range[0] and
                            x_compare <= hl.range[1])
                        {
                            const tag: HighlightTag = @enumFromInt(hl.tag);
                            break :selected switch (tag) {
                                .search_match => .search,
                                .search_match_selected => .search_selected,
                            };
                        }
                    }

                    break :selected .false;
                };

                // The `_style` suffixed values are the colors based on
                // the cell style (SGR), before applying any additional
                // configuration, inversions, selections, etc.
                const bg_style = style.bg(
                    cell,
                    &state.colors.palette,
                );
                const fg_style = style.fg(.{
                    .default = state.colors.foreground,
                    .palette = &state.colors.palette,
                    .bold = self.config.bold_color,
                });

                // The final background color for the cell.
                const bg = switch (selected) {
                    // If we have an explicit selection background color
                    // specified in the config, use that.
                    //
                    // If no configuration, then our selection background
                    // is our foreground color.
                    .selection => if (self.config.selection_background) |v| switch (v) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    } else state.colors.foreground,

                    .search => switch (self.config.search_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    .search_selected => switch (self.config.search_selected_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    // Not selected
                    .false => if (style.flags.inverse != isCovering(cell.codepoint()))
                        // Two cases cause us to invert (use the fg color as the bg)
                        // - The "inverse" style flag.
                        // - A "covering" glyph; we use fg for bg in that
                        //   case to help make sure that padding extension
                        //   works correctly.
                        //
                        // If one of these is true (but not the other)
                        // then we use the fg style color for the bg.
                        fg_style
                    else
                        // Otherwise they cancel out.
                        bg_style,
                };

                const fg = fg: {
                    // Our happy-path non-selection background color
                    // is our style or our configured defaults.
                    const final_bg = bg_style orelse state.colors.background;

                    // Whether we need to use the bg color as our fg color:
                    // - Cell is selected, inverted, and set to cell-foreground
                    // - Cell is selected, not inverted, and set to cell-background
                    // - Cell is inverted and not selected
                    break :fg switch (selected) {
                        .selection => if (self.config.selection_foreground) |v| switch (v) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        } else state.colors.background,

                        .search => switch (self.config.search_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .search_selected => switch (self.config.search_selected_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .false => if (style.flags.inverse)
                            final_bg
                        else
                            fg_style,
                    };
                };

                // Foreground alpha for this cell.
                const alpha: u8 = if (style.flags.faint) self.config.faint_opacity else 255;

                // Set the cell's background color.
                {
                    const rgb = bg orelse state.colors.background;

                    // Determine our background alpha. If we have transparency configured
                    // then this is dynamic depending on some situations. This is all
                    // in an attempt to make transparency look the best for various
                    // situations. See inline comments.
                    const bg_alpha: u8 = bg_alpha: {
                        const default: u8 = 255;

                        // Cells that are selected should be fully opaque.
                        if (selected != .false) break :bg_alpha default;

                        // Cells that are reversed should be fully opaque.
                        if (style.flags.inverse) break :bg_alpha default;

                        // If the user requested to have opacity on all cells, apply it.
                        if (self.config.background_opacity_cells and bg_style != null) {
                            var opacity: f64 = @floatFromInt(default);
                            opacity *= self.config.background_opacity;
                            break :bg_alpha @intFromFloat(opacity);
                        }

                        // Cells that have an explicit bg color should be fully opaque.
                        if (bg_style != null) break :bg_alpha default;

                        // Otherwise, we won't draw the bg for this cell,
                        // we'll let the already-drawn background color
                        // show through.
                        break :bg_alpha 0;
                    };

                    self.cells.bgCell(y, x).* = .{
                        rgb.r, rgb.g, rgb.b, bg_alpha,
                    };
                }

                // If the invisible flag is set on this cell then we
                // don't need to render any foreground elements, so
                // we just skip all glyphs with this x coordinate.
                //
                // NOTE: This behavior matches xterm. Some other terminal
                // emulators, e.g. Alacritty, still render text decorations
                // and only make the text itself invisible. The decision
                // has been made here to match xterm's behavior for this.
                if (style.flags.invisible) {
                    continue;
                }

                // Give links a single underline, unless they already have
                // an underline, in which case use a double underline to
                // distinguish them.
                const underline: terminal.Attribute.Underline = underline: {
                    if (links.contains(.{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    })) {
                        break :underline if (style.flags.underline == .single)
                            .double
                        else
                            .single;
                    }
                    break :underline style.flags.underline;
                };

                // We draw underlines first so that they layer underneath text.
                // This improves readability when a colored underline is used
                // which intersects parts of the text (descenders).
                if (underline != .none) self.addUnderline(
                    @intCast(x),
                    @intCast(y),
                    underline,
                    style.underlineColor(&state.colors.palette) orelse fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding underline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                if (style.flags.overline) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
                    log.warn(
                        "error adding overline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                // If we're at or past the end of our shaper run then
                // we need to get the next run from the run iterator.
                if (shaper_cells != null and shaper_cells_i >= shaper_cells.?.len) {
                    shaper_run = try run_iter.next(self.alloc);
                    shaper_cells = null;
                    shaper_cells_i = 0;
                }

                if (shaper_run) |run| glyphs: {
                    // If we haven't shaped this run yet, do so.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    const shaped_cells = shaper_cells orelse break :glyphs;

                    // If there are no shaper cells for this run, ignore it.
                    // This can occur for runs of empty cells, and is fine.
                    if (shaped_cells.len == 0) break :glyphs;

                    // If we encounter a shaper cell to the left of the current
                    // cell then we have some problems. This logic relies on x
                    // position monotonically increasing.
                    assert(run.offset + shaped_cells[shaper_cells_i].x >= x);

                    // NOTE: An assumption is made here that a single cell will never
                    // be present in more than one shaper run. If that assumption is
                    // violated, this logic breaks.

                    while (shaper_cells_i < shaped_cells.len and
                        run.offset + shaped_cells[shaper_cells_i].x == x) : ({
                        shaper_cells_i += 1;
                    }) {
                        self.addGlyph(
                            @intCast(x),
                            @intCast(y),
                            state.cols,
                            cells_raw,
                            shaped_cells[shaper_cells_i],
                            shaper_run.?,
                            fg,
                            alpha,
                        ) catch |err| {
                            log.warn(
                                "error adding glyph to cell, will be invalid x={} y={}, err={}",
                                .{ x, y, err },
                            );
                        };
                    }
                }

                // Finally, draw a strikethrough if necessary.
                if (style.flags.strikethrough) self.addStrikethrough(
                    @intCast(x),
                    @intCast(y),
                    fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding strikethrough to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };
            }
        }

        /// Add an underline decoration to the specified cell
        fn addUnderline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            style: terminal.Attribute.Underline,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const sprite: font.Sprite = switch (style) {
                .none => unreachable,
                .single => .underline,
                .double => .underline_double,
                .dotted => .underline_dotted,
                .dashed => .underline_dashed,
                .curly => .underline_curly,
            };

            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(sprite),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .underline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        /// Add a overline decoration to the specified cell
        fn addOverline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.overline),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .overline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        /// Add a strikethrough decoration to the specified cell
        fn addStrikethrough(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.strikethrough),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .strikethrough, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        // Add a glyph to the specified cell.
        fn addGlyph(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            cols: usize,
            cell_raws: []const terminal.page.Cell,
            shaper_cell: font.shape.Cell,
            shaper_run: font.shape.TextRun,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const cell = cell_raws[x];
            const cp = cell.codepoint();

            // Render
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                shaper_run.font_index,
                shaper_cell.glyph_index,
                .{
                    .grid_metrics = self.grid_metrics,
                    .thicken = self.config.font_thicken,
                    .thicken_strength = self.config.font_thicken_strength,
                    .cell_width = cell.gridWidth(),
                    // If there's no Nerd Font constraint for this codepoint
                    // then, if it's a symbol, we constrain it to fit inside
                    // its cell(s), we don't modify the alignment at all.
                    .constraint = getConstraint(cp) orelse
                        if (cellpkg.isSymbol(cp)) .{
                            .size = .fit,
                        } else .none,
                    .constraint_width = constraintWidth(
                        cell_raws,
                        x,
                        cols,
                    ),
                },
            );

            // If the glyph is 0 width or height, it will be invisible
            // when drawn, so don't bother adding it to the buffer.
            if (render.glyph.width == 0 or render.glyph.height == 0) {
                return;
            }

            const text_cell: shaderpkg.CellText = .{
                .atlas = switch (render.presentation) {
                    .emoji => .color,
                    .text => .grayscale,
                },
                .bools = .{ .no_min_contrast = noMinContrast(cp) },
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x + shaper_cell.x_offset),
                    @intCast(render.glyph.offset_y + shaper_cell.y_offset),
                },
            };

            // The exact confirmed local echo is drawn by the free-floating
            // input pipeline for its whole arrival. Do not also put this
            // instance in cell_text: two overlapping glyph masks would make
            // the supposed fade begin at full darkness.
            if (self.input_glyph_motion) |*motion| {
                if (motion.quad == null and motion.col == x and motion.row == y) {
                    const cell_width: f32 = @floatFromInt(self.grid_metrics.cell_width);
                    const cell_height: f32 = @floatFromInt(self.grid_metrics.cell_height);
                    motion.quad = .{
                        .pos = .{
                            @as(f32, @floatFromInt(x)) * cell_width + @as(f32, @floatFromInt(render.glyph.offset_x + shaper_cell.x_offset)),
                            @as(f32, @floatFromInt(y)) * cell_height + cell_height - @as(f32, @floatFromInt(render.glyph.offset_y + shaper_cell.y_offset)),
                        },
                        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                        .glyph_size = .{ render.glyph.width, render.glyph.height },
                        .grid_pos = .{ x, y },
                        .color = .{ color.r, color.g, color.b, alpha },
                        .atlas = switch (render.presentation) {
                            .emoji => .color,
                            .text => .grayscale,
                        },
                        .bools = .{ .no_min_contrast = noMinContrast(cp) },
                        .opacity = 255,
                        .draw_size = .{
                            @floatFromInt(render.glyph.width),
                            @floatFromInt(render.glyph.height),
                        },
                    };
                    // Keep the real text sprite independently of fg_rows:
                    // an immediate Backspace can arrive before this held
                    // arrival glyph has ever been rebuilt into normal text.
                    try self.cells.cacheText(self.alloc, text_cell);
                    return;
                }
            }

            try self.cells.add(self.alloc, .text, text_cell);
        }

        fn addCursor(
            self: *Self,
            cursor_state: *const terminal.RenderState.Cursor,
            cursor_style: renderer.CursorStyle,
            cursor_color: terminal.color.RGB,
        ) void {
            const cursor_vp = cursor_state.viewport orelse return;

            // Add the cursor. We render the cursor over the wide character if
            // we're on the wide character tail.
            const wide, const x = cell: {
                // The cursor goes over the screen cursor position.
                if (!cursor_vp.wide_tail) break :cell .{
                    cursor_state.cell.wide == .wide,
                    cursor_vp.x,
                };

                // If we're part of a wide character, we move the cursor back
                // to the actual character.
                break :cell .{ true, cursor_vp.x - 1 };
            };

            const alpha: u8 = if (!self.focused) 255 else alpha: {
                const alpha = 255 * self.config.cursor_opacity;
                break :alpha @intFromFloat(@ceil(alpha));
            };

            const render = switch (cursor_style) {
                .block,
                .block_hollow,
                .bar,
                .underline,
                => render: {
                    const sprite: font.Sprite = switch (cursor_style) {
                        .block => .cursor_rect,
                        .block_hollow => .cursor_hollow_rect,
                        .bar => .cursor_bar,
                        .underline => .cursor_underline,
                        .lock => unreachable,
                    };

                    break :render self.font_grid.renderGlyph(
                        self.alloc,
                        font.sprite_index,
                        @intFromEnum(sprite),
                        .{
                            .cell_width = if (wide) 2 else 1,
                            .grid_metrics = self.grid_metrics,
                        },
                    ) catch |err| {
                        log.warn("error rendering cursor glyph err={}", .{err});
                        return;
                    };
                },

                .lock => self.font_grid.renderCodepoint(
                    self.alloc,
                    0xF023, // lock symbol
                    .regular,
                    .text,
                    .{
                        .cell_width = if (wide) 2 else 1,
                        .grid_metrics = self.grid_metrics,
                    },
                ) catch |err| {
                    log.warn("error rendering cursor glyph err={}", .{err});
                    return;
                } orelse {
                    // This should never happen because we embed nerd
                    // fonts so we just log and return instead of fallback.
                    log.warn("failed to find lock symbol for cursor codepoint=0xF023", .{});
                    return;
                },
            };

            const cell: shaderpkg.CellText = .{
                .atlas = .grayscale,
                .bools = .{ .is_cursor_glyph = true },
                .grid_pos = .{ x, cursor_vp.y },
                .color = .{ cursor_color.r, cursor_color.g, cursor_color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            };

            // With cursor motion enabled the cursor leaves the shared
            // cell_text pipeline and becomes its own free-floating quad,
            // which is what lets it sit part way between two cells. Note
            // everything above this point is unchanged either way, so both
            // paths agree on the sprite, the color, and the alpha.
            if (self.config.cursor_motion != .none and !self.reduceMotion(false)) {
                self.setCursorMotionTarget(cell, cursor_style, wide);
                return;
            }

            self.cells.setCursor(cell, cursor_style);
        }

        /// Aim the cursor motion animation at the cell the cursor now
        /// occupies. `cell` is exactly the instance the legacy path would
        /// have handed to `cell.Contents.setCursor`.
        ///
        /// Caller must hold the draw mutex.
        fn setCursorMotionTarget(
            self: *Self,
            cell: shaderpkg.CellText,
            style: renderer.CursorStyle,
            wide: bool,
        ) void {
            const state: *CursorMotionState = &self.cursor_motion;

            state.legacy_cell = cell;
            state.legacy_style = style;

            state.head = .{
                .glyph = .{
                    .pos = cell.glyph_pos,
                    .size = cell.glyph_size,
                },
                .color = cell.color,
            };

            // Match the z-order the cell_text pipeline gives the cursor:
            // block cursors under the text, everything else over it. This
            // mirrors the switch in `cell.Contents.setCursor`.
            state.over_text = switch (style) {
                .block => false,
                .block_hollow, .bar, .underline, .lock => true,
            };
            state.block_text_target = if (style == .block) .{
                .pos = cell.grid_pos,
                .wide = wide,
            } else null;

            // The trail quad is drawn with the solid block sprite so that
            // it reads as a streak no matter what shape the cursor itself
            // is. Only the styles that can produce a trail need it.
            state.trail = switch (self.config.cursor_motion) {
                .spring, .smear => self.cursorTrailGlyph(),
                .none, .ease, .squash => null,
            };

            const rect = cursorCellRect(cell, self.grid_metrics);

            if (state.snap) {
                state.snap = false;
                state.anim.snap(rect);
                self.cursor_motion_active.store(false, .release);
                return;
            }

            // Handing the animation the same rect it already has is a
            // no-op, so this is safe to call on every rebuild.
            const now = self.cursorMotionTimeStart();
            state.anim.setTarget(rect, now);
            self.cursor_motion_active.store(state.anim.isActive(now), .release);
        }

        /// The solid block cursor sprite, used to draw the trail quad.
        ///
        /// This is a cached atlas lookup rather than a rasterization on all
        /// but the first call for a given cell size, the same as the cursor
        /// sprite that `addCursor` fetches.
        ///
        /// Caller must hold the draw mutex.
        fn cursorTrailGlyph(self: *Self) ?CursorMotionState.Glyph {
            const render = self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.cursor_rect),
                .{
                    // Always one cell wide: the sprite is a solid rect, and
                    // it gets stretched to the trail rect regardless, so a
                    // wide cursor doesn't need its own atlas entry.
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            ) catch |err| {
                log.warn("error rendering cursor trail glyph err={}", .{err});
                return null;
            };

            return .{
                .pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .size = .{ render.glyph.width, render.glyph.height },
            };
        }

        fn addPreeditCell(
            self: *Self,
            cp: renderer.State.Preedit.Codepoint,
            coord: terminal.Coordinate,
            screen_fg: terminal.color.RGB,
        ) !void {
            // Render the glyph for our preedit text
            const render_ = self.font_grid.renderCodepoint(
                self.alloc,
                @intCast(cp.codepoint),
                .regular,
                .text,
                .{ .grid_metrics = self.grid_metrics },
            ) catch |err| {
                log.warn("error rendering preedit glyph err={}", .{err});
                return;
            };
            const render = render_ orelse {
                log.warn("failed to find font for preedit codepoint={X}", .{cp.codepoint});
                return;
            };

            // Add our text
            try self.cells.add(self.alloc, .text, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
                .color = .{ screen_fg.r, screen_fg.g, screen_fg.b, 255 },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });

            // Add underline
            try self.addUnderline(@intCast(coord.x), @intCast(coord.y), .single, screen_fg, 255);
            if (cp.wide and coord.x < self.cells.size.columns - 1) {
                try self.addUnderline(@intCast(coord.x + 1), @intCast(coord.y), .single, screen_fg, 255);
            }
        }

        /// Sync the atlas data to the given texture. This copies the bytes
        /// associated with the atlas to the given texture. If the atlas no
        /// longer fits into the texture, the texture will be resized.
        fn syncAtlasTexture(
            self: *const Self,
            atlas: *const font.Atlas,
            texture: *Texture,
        ) !void {
            if (atlas.size > texture.width) {
                // Free our old texture
                texture.*.deinit();

                // Reallocate
                texture.* = try self.api.initAtlasTexture(atlas);
            }

            try texture.replaceRegion(0, 0, atlas.size, atlas.size, atlas.data);
        }
    };
}

test "cursor motion style mapping" {
    const testing = std.testing;

    // `none` means disabled, everything else has a 1:1 animation style.
    try testing.expect(cursorMotionStyle(.none) == null);
    try testing.expectEqual(motionpkg.Style.ease, cursorMotionStyle(.ease).?);
    try testing.expectEqual(motionpkg.Style.spring, cursorMotionStyle(.spring).?);
    try testing.expectEqual(motionpkg.Style.smear, cursorMotionStyle(.smear).?);
    try testing.expectEqual(motionpkg.Style.squash, cursorMotionStyle(.squash).?);
}

test "cursor motion block text inversion waits for arrival" {
    const testing = std.testing;
    const target: CursorTextTarget = .{
        .pos = .{ 12, 4 },
        .wide = true,
    };

    // A free-floating cursor has no one cell to invert.
    try testing.expect(cursorTextInversionTarget(target, true) == null);

    // Snaps and settled animations immediately recover legacy behavior.
    try testing.expectEqual(target, cursorTextInversionTarget(target, false).?);
    try testing.expect(cursorTextInversionTarget(null, false) == null);
}

test "cursor rect matches the cell_text bearing math" {
    const testing = std.testing;

    // Only the cell dimensions are consulted.
    var metrics: font.Metrics = undefined;
    metrics.cell_width = 10;
    metrics.cell_height = 20;

    // A block cursor fills its cell: the Y bearing is the full cell
    // height, so the glyph top is flush with the cell top.
    {
        const rect = cursorCellRect(.{
            .grid_pos = [2]u16{ 3, 4 },
            .bearings = [2]i16{ 0, 20 },
            .glyph_size = [2]u32{ 10, 20 },
        }, metrics);
        try testing.expectEqual(@as(f32, 30), rect.pos[0]);
        try testing.expectEqual(@as(f32, 80), rect.pos[1]);
        try testing.expectEqual(@as(f32, 10), rect.size[0]);
        try testing.expectEqual(@as(f32, 20), rect.size[1]);
    }

    // A bar cursor is narrow and inset from the left of the cell by its
    // X bearing.
    {
        const rect = cursorCellRect(.{
            .grid_pos = [2]u16{ 1, 0 },
            .bearings = [2]i16{ 1, 20 },
            .glyph_size = [2]u32{ 2, 20 },
        }, metrics);
        try testing.expectEqual(@as(f32, 11), rect.pos[0]);
        try testing.expectEqual(@as(f32, 0), rect.pos[1]);
        try testing.expectEqual(@as(f32, 2), rect.size[0]);
        try testing.expectEqual(@as(f32, 20), rect.size[1]);
    }

    // An underline cursor sits near the bottom of the cell, which is
    // `cell_height - bearing_y` below the cell top.
    {
        const rect = cursorCellRect(.{
            .grid_pos = [2]u16{ 0, 1 },
            .bearings = [2]i16{ 0, 3 },
            .glyph_size = [2]u32{ 10, 3 },
        }, metrics);
        try testing.expectEqual(@as(f32, 0), rect.pos[0]);
        try testing.expectEqual(@as(f32, 37), rect.pos[1]);
        try testing.expectEqual(@as(f32, 3), rect.size[1]);
    }

    // A wide cursor needs no special handling: `addCursor` rasterizes the
    // sprite two cells wide, so the width is already in the glyph size.
    {
        const rect = cursorCellRect(.{
            .grid_pos = [2]u16{ 2, 0 },
            .bearings = [2]i16{ 0, 20 },
            .glyph_size = [2]u32{ 20, 20 },
        }, metrics);
        try testing.expectEqual(@as(f32, 20), rect.pos[0]);
        try testing.expectEqual(@as(f32, 20), rect.size[0]);
    }
}
