# Fusion Runtime
A game engine written in Zig for learning, currently uses glfw for window management and OpenGL 4.6 as it's renderer.

## Native game SDK

Game libraries use the sibling `fusion-sdk` package. Shared component/math/key
sources live there; the runtime owns ECS storage and translates generated wire
values at `src/core/game_host.zig`. The editor binds libraries through
`GameLibrary.bind` and keeps the library alive until runtime teardown.

Build modes are independent. After building sandbox-game in Debug, run:

```sh
zig build test-game -Doptimize=ReleaseFast -Dgame-library=../sandbox-game/zig-out/lib/libsandbox-game.so
```

The SDK README describes the interface and MVP scope. Engine-only builds/tests
continue to work without building a game library.
