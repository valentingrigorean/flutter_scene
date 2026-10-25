# flutter_scene_wgpu example

A rotating lit cube drawn by the Rust presenter into a Flutter texture, one
synchronous render call per Flutter frame. Dart computes the camera; a pan
orbits it, and an amber dot sits on the projected position of one cube
corner. The top-left strips carry the frame index: the magenta-anchored
strip is drawn by Rust into the texture, the cyan-anchored strip by Flutter,
so one capture shows how many frames the texture trails the overlay.

```sh
flutter build macos --debug
flutter build ios --simulator --debug
flutter build apk --debug                            # Vulkan
flutter build apk --debug --dart-define=FSW_PRESENT_GL=true   # GLES
```

`--dart-define=FSW_PRESENT_SCENE=true` runs flutter_scene on its wgpu
backend instead: the scene renders into a `RenderTexture`, and the presenter
draws that texture with `presentTexture` (flutter_scene's GPU shim). The
status line names the backend and the texture's format.

`flutter test` runs `test/present_texture_test.dart`, which presents shim
textures of known patterns through an offscreen presenter and checks the
pixels read back from its IOSurface.
