import { describe, expect, it } from "vitest";
import { isNativeShellLayout, nativeShellTabIndex } from "./ios-shell";

describe("native shell route and window boundaries", () => {
  it("keeps detail routes in Library and recognizes the Search root", () => {
    expect(nativeShellTabIndex("/library/albums/album-1")).toBe(1);
    expect(nativeShellTabIndex("/mobile/library")).toBe(1);
    expect(nativeShellTabIndex("/mobile/search")).toBe(2);
    expect(nativeShellTabIndex("/")).toBe(0);
  });

  it("rejects malformed native insets rather than corrupting the page layout", () => {
    expect(
      isNativeShellLayout({
        type: "layout",
        top: 88,
        bottom: 190,
        compact: false,
      }),
    ).toBe(true);
    for (const invalid of [
      null,
      {},
      { type: "layout", top: NaN, bottom: 190, compact: true },
      { type: "layout", top: 80, bottom: -1, compact: true },
      { type: "layout", top: 80, bottom: 999, compact: false },
    ]) {
      expect(isNativeShellLayout(invalid)).toBe(false);
    }
  });
});
