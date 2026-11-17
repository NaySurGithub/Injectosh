# Injectosh

A small macOS app to inject DLL in Minecraft with Wine and Blockintosh.

## Build

Open this folder in Xcode, or run:

```sh
swift build
swift run
```

## Releases

Push a version tag such as `v1.0.0` to create a GitHub release with a macOS app archive.

The app interface and discovery code are in `Sources/Injectosh`. `InjectionAction.swift` is the place to add your own action.
