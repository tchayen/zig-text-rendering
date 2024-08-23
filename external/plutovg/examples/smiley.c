#include "plutovg.h"

int main(void)
{
    const int width = 150;
    const int height = 150;

    plutovg_surface_t* surface = plutovg_surface_create(width, height);
    plutovg_canvas_t* canvas = plutovg_canvas_create(surface);

    float center_x = width / 2.f;
    float center_y = height / 2.f;
    float face_radius = 70;
    float eye_radius = 10;
    float mouth_radius = 50;
    float eye_offset_x = 25;
    float eye_offset_y = 20;
    float eye_x = center_x - eye_offset_x;
    float eye_y = center_y - eye_offset_y;

    plutovg_canvas_save(canvas);
    plutovg_canvas_arc(canvas, center_x, center_y, face_radius, 0, 2 * PLUTOVG_PI, 0);
    plutovg_canvas_set_rgb(canvas, 1, 1, 0);
    plutovg_canvas_fill_preserve(canvas);
    plutovg_canvas_set_rgb(canvas, 0, 0, 0);
    plutovg_canvas_set_line_width(canvas, 5);
    plutovg_canvas_stroke(canvas);
    plutovg_canvas_restore(canvas);

    plutovg_canvas_save(canvas);
    plutovg_canvas_arc(canvas, eye_x, eye_y, eye_radius, 0, 2 * PLUTOVG_PI, 0);
    plutovg_canvas_arc(canvas, center_x + eye_offset_x, eye_y, eye_radius, 0, 2 * PLUTOVG_PI, 0);
    plutovg_canvas_set_rgb(canvas, 0, 0, 0);
    plutovg_canvas_fill(canvas);
    plutovg_canvas_restore(canvas);

    plutovg_canvas_save(canvas);
    plutovg_canvas_arc(canvas, center_x, center_y, mouth_radius, 0, PLUTOVG_PI, 0);
    plutovg_canvas_set_rgb(canvas, 0, 0, 0);
    plutovg_canvas_set_line_width(canvas, 5);
    plutovg_canvas_stroke(canvas);
    plutovg_canvas_restore(canvas);

    plutovg_surface_write_to_png(surface, "smiley.png");
    plutovg_canvas_destroy(canvas);
    plutovg_surface_destroy(surface);
    return 0;
}
