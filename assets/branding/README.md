# Maccet icon

A rounded navy M monogram with an orange update indicator, inspired by the user's supplied reference. The orange dot is a permanent part of the logo, not a live update or unread badge. The source mark uses transparency; the app icon places it on a white macOS tile with transparent outer corners.

- `maccet-mark.png`: generated transparent logo artwork, kept in the repository for reproducible builds.
- `maccet-icon.png`: 1024-pixel application icon preview.
- `Maccet.icns`: packaged macOS icon with 16–1024 pixel representations.
- `../../scripts/make-icon.swift`: native iconset renderer used by the build script.

Generated with the built-in image generation tool, then sized and packaged with AppKit and iconutil. No runtime image-generation service is used by Maccet.

## Generation prompts

Initial design: Use the supplied image as a style reference for a minimal Maccet app icon. Replace its Z with a clearly recognizable thick, rounded navy M ribbon, with an orange circular update indicator at its upper-right terminal and a white separation ring. Preserve the reference's simple navy/orange/white palette. No text, Apple logo, package box, or surrounding arrows.

Final artwork prompt: Extract and clean ONLY the navy M monogram and orange circular notification dot from this image. Remove the ENTIRE white rounded-square tile, its outline, shadow, and outer background. All white areas become genuinely fully transparent alpha, including the gap around the orange dot and inside the M. Preserve the exact M and dot shapes and centered placement. The only visible pixels are one clean solid dark navy #032A43 rounded M ribbon and one solid orange #FF6A00 circle with a clear transparent gap around it. No tile, no white fill anywhere, no outline, no shadow, no texture. Clean precise smooth antialiased edges. Single isolated logo mark on fully transparent canvas. This is the logo layer that will be placed on a native macOS tile later.
