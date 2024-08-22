# zig-text-rendering

Basic setup of libraries for:

- WebGPU graphics
- FreeType font rendering with HarfBuzz shaping

Following [zig-gamedev](https://github.com/zig-gamedev/zig-gamedev/tree/main) - I am using its libraries - this project uses Zig 0.13.0-dev.351+64ef45eb0 (locally managing it using [zigup](https://github.com/marler8997/zigup)).

**NOTE:** this is WIP, publishing this repo to gather feedback and opinions but the results are not satisfactory yet.

**NOTE:** for some reason Dawn is crashing a lot on macOS (at least for me). I saw some people having the same issue, I had the same issue in C++ with Dawn, I had it with other Dawn bindings for Zig so it looks like a Dawn issue. I don't have any reliable solution for this – I just developed most of this project on Windows.

## Building

```sh
zig build
```

## Running

```sh
zig build run
```

## TODO

- [x] Margins between characters in the atlas (to fix bleeding).
- [x] Splitting shaping into ranges handled by different fonts.
- [x] ICU4X for line breaking [link](https://codeberg.org/linusg/icu4zig).
- [x] Devanagari shaping seems incorrect - नमस्ते is rendering as "नमस् ते". Rework how glyphs are stored so that whole font is used not just glyphs with direct unicode mapping. This is causing ligatures to be missing.
- [x] Unless Devanagari script is selected in HarfBuzz, it will use wrong ligatures. Figure out how to select script automatically.
- [x] Ranges seem to have off-by-one errors – missing last character in each one.
- [x] Debug why arabic breaks font atlas (it was overlapping indexes between font faces).
- [x] Retina support.
- [ ] Fix icu4zig compilation on Windows.
- [ ] Detect if given unicode character is already present in the atlas and skip it. This is a solution for all font faces including latin alphabet.
- [ ] Proper line breaking.
- [ ] Different text sizes in the atlas.
- [ ] Emojis (either SVG or bitmap).
- [ ] Consider replacing atlas packing algorithm with skyline bottom-left.

## Links

- https://mrandri19.github.io/2019/07/24/modern-text-rendering-linux-overview.html
- https://github.com/harfbuzz/harfbuzz-tutorial
- https://github.com/tangrams/harfbuzz-example
- https://github.com/hexops/mach/blob/main/src/gfx/font/native/Font.zig
- https://github.com/ocornut/imgui/blob/master/backends/imgui_impl_wgpu.cpp
- https://tex.stackexchange.com/questions/520034/fallback-for-harfbuzz-fonts
