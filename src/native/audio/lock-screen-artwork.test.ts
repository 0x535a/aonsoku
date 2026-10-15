import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  isLockScreenArtworkAvailable,
  lockScreenArtwork,
} from "./lock-screen-artwork";

const mocks = vi.hoisted(() => ({
  runtime: "capacitor-ios",
  installed: true,
  plugin: {
    getLockScreenArtworkState: vi.fn(),
    configureLockScreenArtwork: vi.fn(),
    downloadLockScreenArtworkModel: vi.fn(),
    cancelLockScreenArtworkDownload: vi.fn(),
    deleteLockScreenArtworkModel: vi.fn(),
  },
}));

vi.mock("@/utils/capabilities", () => ({ getRuntime: () => mocks.runtime }));
vi.mock("@/native/artwork/tauri", () => ({
  isMacArtworkAvailable: () => false,
}));
vi.mock("@capacitor/core", () => ({
  Capacitor: { isPluginAvailable: () => mocks.installed },
}));
vi.mock("@aonsoku/capacitor-native/preferences", () => ({
  AonsokuNativePreferences: mocks.plugin,
}));

describe("iOS artwork preferences extension", () => {
  beforeEach(() => {
    mocks.runtime = "capacitor-ios";
    mocks.installed = true;
    vi.clearAllMocks();
  });

  it.each(["web", "electron", "tauri", "capacitor-android"])(
    "does not call unsupported native methods on %s",
    (runtime) => {
      mocks.runtime = runtime;
      expect(isLockScreenArtworkAvailable()).toBe(false);
      expect(() => lockScreenArtwork.getState()).toThrow("native iOS");
      expect(mocks.plugin.getLockScreenArtworkState).not.toHaveBeenCalled();
    },
  );

  it("handles a missing preferences plugin without invoking a proxy", () => {
    mocks.installed = false;
    expect(isLockScreenArtworkAvailable()).toBe(false);
    expect(() =>
      lockScreenArtwork.configure({ dynamicEnabled: true }),
    ).toThrow();
  });

  it("keeps options and model commands in the iOS native layer", async () => {
    const options = { immersiveEnabled: false, quality: "p6" as const };
    await lockScreenArtwork.configure(options);
    await lockScreenArtwork.download("p8");
    await lockScreenArtwork.cancel("p8");
    await lockScreenArtwork.remove("fp16");
    expect(mocks.plugin.configureLockScreenArtwork).toHaveBeenCalledWith(
      options,
    );
    expect(mocks.plugin.downloadLockScreenArtworkModel).toHaveBeenCalledWith({
      tier: "p8",
    });
    expect(mocks.plugin.cancelLockScreenArtworkDownload).toHaveBeenCalledWith({
      tier: "p8",
    });
    expect(mocks.plugin.deleteLockScreenArtworkModel).toHaveBeenCalledWith({
      tier: "fp16",
    });
  });
});
