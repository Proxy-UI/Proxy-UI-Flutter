// The galaxy's backdrop: smoke along the disk's plane, tinted faintly with
// the theme's seed colour so the sky belongs to the same palette as the rest
// of the app. Rendered once per size and theme, then reused as an image.
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uSeed;
uniform float uDark;
uniform vec3 uTint;

out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7)) + uSeed) * 43758.5453);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
    mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

float fbm(vec2 p) {
  float value = 0.0;
  float amplitude = 0.5;
  for (int i = 0; i < 6; i++) {
    value += amplitude * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    amplitude *= 0.5;
  }
  return value;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 p = (uv - 0.5) * vec2(uSize.x / uSize.y, 1.0) * 3.2;
  // Domain warping draws the smoke into wisps.
  vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
  float n = fbm(p + 2.2 * q);
  // Thickest along a gently tilted band: the plane of the disk.
  float band = exp(-pow((uv.y - 0.56 + (uv.x - 0.5) * 0.22) * 2.4, 2.0));
  float density = smoothstep(0.42, 0.95, n) * (0.3 + 0.7 * band);
  float alpha = density * mix(0.07, 0.12, uDark);
  vec3 neutral = mix(vec3(0.17, 0.17, 0.2), vec3(1.0), uDark);
  vec3 ink = mix(neutral, uTint, 0.45);
  fragColor = vec4(ink * alpha, alpha);
}
