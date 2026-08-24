#include "common.glsl"

layout(location = 0) in vec2 quad_pos;
layout(location = 1) in uvec2 glyph_pos;
layout(location = 2) in uvec2 glyph_size;
layout(location = 3) in uvec2 grid_pos;
layout(location = 4) in uvec4 color;
layout(location = 5) in uint atlas;
layout(location = 6) in uint glyph_bools;
layout(location = 7) in uint opacity;
layout(location = 8) in vec2 draw_size;

const uint NO_MIN_CONTRAST = 1u;
const uint CURSOR_WIDE = 1u;

out CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
} out_data;

layout(binding = 1, std430) readonly buffer bg_cells { uint bg_colors[]; };

void main() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    uvec2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    vec2 corner = vec2(float(gl_VertexID == 1 || gl_VertexID == 3), float(gl_VertexID == 2 || gl_VertexID == 3));
    out_data.atlas = atlas;
    gl_Position = projection_matrix * vec4(quad_pos + draw_size * corner, 0.0, 1.0);
    out_data.tex_coord = vec2(glyph_pos) + vec2(glyph_size) * corner;
    out_data.color = load_color(color, true);
    out_data.bg_color = load_color(unpack4u8(bg_colors[grid_pos.y * grid_size.x + grid_pos.x]), true);
    vec4 global_bg = load_color(unpack4u8(bg_color_packed_4u8), true);
    out_data.bg_color += global_bg * vec4(1.0 - out_data.bg_color.a);
    if (min_contrast > 1.0 && (glyph_bools & NO_MIN_CONTRAST) == 0) out_data.color = contrasted_color(min_contrast, out_data.color, out_data.bg_color);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    if ((grid_pos.x == cursor_pos.x || (cursor_wide && grid_pos.x == cursor_pos.x + 1)) && grid_pos.y == cursor_pos.y)
        out_data.color = load_color(unpack4u8(cursor_color_packed_4u8), true);
    out_data.color *= float(opacity) / 255.0;
}
