import { expect, it, vi } from "vitest";
import { lockScreenArtwork } from "../audio/lock-screen-artwork";
import { dynamicCover } from ".";

const invoke = vi.hoisted(() => vi.fn());
vi.mock("@/utils/capabilities", () => ({ getRuntime: () => "tauri" }));
vi.mock("@/utils/desktop", () => ({ isMacOS: true }));
vi.mock("@/utils/tauri", () => ({ getTauriInvoke: () => invoke }));

it("routes macOS settings, cache and a video lease through the native host", async () => {
  invoke.mockImplementation(async (_command, { operation }) => {
    if (operation === "capabilities")
      return { version: 1, available: true, formats: ["square"] };
    if (operation === "acquire")
      return {
        status: "ready",
        leaseId: "lease",
        coverArtId: "cover",
        format: "square",
        stage: "depth",
        src: "aonsoku-artwork://localhost/session/lease",
      };
    return {};
  });
  await lockScreenArtwork.configure({ quality: "p8", motionSpeed: 2 });
  await lockScreenArtwork.download("p8");
  await lockScreenArtwork.clearVideos("dynamic");
  const handle = await dynamicCover.acquire({
    coverArtId: "cover",
    format: "square",
    mode: "dynamic",
  });
  expect(handle.status).toBe("ready");
  if (handle.status !== "ready") throw new Error("Expected a macOS lease");
  expect(handle.src).toBe("aonsoku-artwork://localhost/session/lease");
  await handle.release();
  expect(invoke.mock.calls.map((call) => call[1])).toEqual([
    { operation: "configure", payload: { quality: "p8", motionSpeed: 2 } },
    { operation: "download", payload: { tier: "p8" } },
    { operation: "clearVideos", payload: { kind: "dynamic" } },
    { operation: "capabilities", payload: {} },
    {
      operation: "acquire",
      payload: { coverArtId: "cover", format: "square", mode: "dynamic" },
    },
    { operation: "release", payload: { leaseId: "lease" } },
  ]);
});
