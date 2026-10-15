import { beforeEach, describe, expect, it, vi } from "vitest";
import { dynamicCover } from ".";
import type { DynamicCoverVideo } from "./types";

const mocks = vi.hoisted(() => ({
  runtime: "capacitor-ios",
  mac: true,
  installed: true,
  native: {
    getDynamicCoverCapabilities: vi.fn(),
    acquireDynamicCover: vi.fn(),
    releaseDynamicCover: vi.fn(),
    registerDynamicCoverDemand: vi.fn(),
    releaseDynamicCoverDemand: vi.fn(),
  },
}));
vi.mock("@/utils/capabilities", () => ({ getRuntime: () => mocks.runtime }));
vi.mock("./tauri", () => ({ isMacArtworkAvailable: () => false }));
vi.mock("@/utils/desktop", () => ({
  get isMacOS() {
    return mocks.mac;
  },
}));
vi.mock("@aonsoku/capacitor-native/preferences", () => ({
  AonsokuNativePreferences: mocks.native,
}));
vi.mock("@capacitor/core", () => ({
  Capacitor: {
    isPluginAvailable: () => mocks.installed,
    convertFileSrc: (src: string) =>
      src.replace("file://", "capacitor://localhost/_capacitor_file_"),
  },
}));

const request = {
  coverArtId: "album-1",
  format: "square",
  mode: "dynamic",
} as const;
const capabilities = {
  version: 1,
  available: true,
  formats: ["square"],
} as const;
const video: DynamicCoverVideo = {
  status: "ready",
  leaseId: "lease-1",
  assetId: "depth-v6",
  coverArtId: "album-1",
  format: "square",
  stage: "depth",
  backend: "dav2-f16",
  width: 720,
  height: 720,
  duration: 6,
  src: "file:///private/cover.mp4",
};

describe("dynamic cover consumer interface", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mocks.runtime = "capacitor-ios";
    mocks.mac = true;
    mocks.installed = true;
    vi.stubGlobal("window", {});
    mocks.native.getDynamicCoverCapabilities.mockResolvedValue(capabilities);
    mocks.native.acquireDynamicCover.mockResolvedValue(video);
    mocks.native.releaseDynamicCover.mockResolvedValue(undefined);
  });

  it("reuses a smaller portrait clip without submitting a generation request", async () => {
    mocks.native.acquireDynamicCover.mockResolvedValue({
      ...video,
      format: "portrait",
      width: 300,
      height: 400,
    });
    const handle = await dynamicCover.acquire({ ...request, format: "any" });
    expect(handle.status).toBe("ready");
    if (handle.status === "ready") {
      expect(handle.format).toBe("portrait");
      await handle.release();
    }
    expect(mocks.native.registerDynamicCoverDemand).not.toHaveBeenCalled();
  });

  it("registers a consumer demand separately and releases it once", async () => {
    mocks.native.registerDynamicCoverDemand.mockResolvedValue({
      demandId: "consumer",
    });
    mocks.native.releaseDynamicCoverDemand.mockResolvedValue(undefined);
    const demand = await dynamicCover.requestGeneration({
      coverArtId: "album-1",
      mode: "dynamic",
    });
    await Promise.all([demand?.release(), demand?.release()]);
    expect(mocks.native.acquireDynamicCover).not.toHaveBeenCalled();
    expect(
      mocks.native.releaseDynamicCoverDemand,
    ).toHaveBeenCalledExactlyOnceWith({ demandId: "consumer" });
  });

  it("converts iOS URLs and releases a lease once through the original provider", async () => {
    const result = await dynamicCover.acquire(request);
    expect(result.status).toBe("ready");
    if (result.status !== "ready") throw new Error("Expected video lease");
    expect(result.src).toBe(
      "capacitor://localhost/_capacitor_file_/private/cover.mp4",
    );
    mocks.runtime = "web";
    await Promise.all([result.release(), result.release()]);
    expect(mocks.native.releaseDynamicCover).toHaveBeenCalledExactlyOnceWith({
      leaseId: "lease-1",
    });
  });

  it.each([
    { ...video, coverArtId: "old-album" },
    { ...video, format: "portrait" },
  ])(
    "releases a mismatched result instead of displaying it",
    async (response) => {
      mocks.native.acquireDynamicCover.mockResolvedValue(response);
      expect(await dynamicCover.acquire(request)).toEqual({
        status: "mismatch",
      });
      expect(mocks.native.releaseDynamicCover).toHaveBeenCalledOnce();
    },
  );

  it("rejects animated results for a static request", async () => {
    expect(await dynamicCover.acquire({ ...request, mode: "static" })).toEqual({
      status: "mismatch",
    });
    expect(mocks.native.releaseDynamicCover).toHaveBeenCalledOnce();
  });

  it.each(["pending", "disabled", "busy"])(
    "passes %s through without creating a lease",
    async (status) => {
      mocks.native.acquireDynamicCover.mockResolvedValue({ status });
      expect(await dynamicCover.acquire(request)).toEqual({ status });
      expect(mocks.native.releaseDynamicCover).not.toHaveBeenCalled();
    },
  );

  it.each(["electron", "tauri"])(
    "uses an explicitly installed macOS %s provider",
    async (runtime) => {
      mocks.runtime = runtime;
      const release = vi.fn().mockResolvedValue(undefined);
      const host = {
        getCapabilities: vi.fn().mockResolvedValue(capabilities),
        acquire: vi.fn().mockResolvedValue({
          ...video,
          src: "aonsoku-media://artwork/token",
        }),
        release,
      };
      Object.assign(window, { aonsokuDynamicCover: host });
      const result = await dynamicCover.acquire(request);
      expect(result.status).toBe("ready");
      if (result.status !== "ready") throw new Error("Expected macOS lease");
      expect(result.src).toBe("aonsoku-media://artwork/token");
      Object.assign(window, { aonsokuDynamicCover: undefined });
      await result.release();
      expect(release).toHaveBeenCalledWith("lease-1");
      expect(mocks.native.acquireDynamicCover).not.toHaveBeenCalled();
    },
  );

  it.each(["web", "capacitor-android", "electron", "tauri"])(
    "reports missing implementation on %s without invoking iOS",
    async (runtime) => {
      mocks.runtime = runtime;
      expect(await dynamicCover.getCapabilities()).toMatchObject({
        available: false,
        reason: "provider-not-installed",
      });
      expect(await dynamicCover.acquire(request)).toMatchObject({
        status: "unavailable",
      });
      expect(mocks.native.acquireDynamicCover).not.toHaveBeenCalled();
    },
  );

  it("ignores desktop providers on Windows/Linux", async () => {
    mocks.runtime = "electron";
    mocks.mac = false;
    const acquire = vi.fn();
    Object.assign(window, { aonsokuDynamicCover: { acquire } });
    expect(await dynamicCover.acquire(request)).toMatchObject({
      status: "unavailable",
    });
    expect(acquire).not.toHaveBeenCalled();
  });

  it("does not acquire unsupported formats or protocol versions", async () => {
    mocks.native.getDynamicCoverCapabilities.mockResolvedValue({
      ...capabilities,
      version: 2,
    });
    expect(await dynamicCover.acquire(request)).toMatchObject({
      status: "unavailable",
    });
    mocks.native.getDynamicCoverCapabilities.mockResolvedValue({
      ...capabilities,
      formats: ["portrait"],
    });
    expect(await dynamicCover.acquire(request)).toMatchObject({
      status: "unavailable",
    });
    expect(mocks.native.acquireDynamicCover).not.toHaveBeenCalled();
  });
});
