# zig-rendering

Basic setup of libraries for:

- WebGPU graphics
- FreeType font rendering with HarfBuzz shaping

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
