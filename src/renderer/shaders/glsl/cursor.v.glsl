#include "common.glsl"

// The top-left corner of the quad in pixels, relative to the top-left of
// the grid. The window padding is applied by the projection matrix, just
// like it is for cell_text and image.
layout(location = 0) in vec2 quad_pos;

// The size of the quad in pixels.
layout(location = 1) in vec2 quad_size;

// Pixel-space axes for the quad. The cursor head uses the identity basis;
// a motion trail uses a travel-aligned basis.
layout(location = 2) in vec2 basis_x;
layout(location = 3) in vec2 basis_y;

// The position of the glyph in the grayscale atlas (x, y).
layout(location = 4) in uvec2 glyph_pos;

// The size of the glyph in the grayscale atlas (w, h).
layout(location = 5) in uvec2 glyph_size;

// The color of the cursor. The alpha carries the configured cursor
// opacity and, for the trail quad, its fade.
layout(location = 6) in uvec4 color;

out CursorVertexOut {
    flat vec4 color;
    vec2 tex_coord;
} out_data;

void main() {
    int vid = gl_VertexID;

    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the quad this vertex is in
    // based on the vertex ID.
    //
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    //
    // 0 = top-left  (0, 0)
    // 1 = top-right (1, 0)
    // 2 = bot-left  (0, 1)
    // 3 = bot-right (1, 1)
    vec2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    // Unlike cell_text there is no `cell_size * grid_pos` term and no
    // bearing math here: the animation hands us the final pixel rect
    // directly, bearings already folded in, so that it can place the
    // cursor part way between two cells.
    vec2 pos = quad_pos + basis_x * (quad_size.x * corner.x) +
        basis_y * (quad_size.y * corner.y);
    gl_Position = projection_matrix * vec4(pos.x, pos.y, 0.0f, 1.0f);

    // The texture coordinate is in pixels, not normalized, since the
    // atlas is sampled as a rectangle texture. Stretching the quad
    // stretches the sprite with it.
    out_data.tex_coord = vec2(glyph_pos) + vec2(glyph_size) * corner;

    // As in cell_text, we always fetch a linearized color and let the
    // fragment shader re-encode it if we aren't blending in linear space.
    out_data.color = load_color(color, true);
}
