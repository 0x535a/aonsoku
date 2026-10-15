import { AonsokuNativePreferences } from "@aonsoku/capacitor-native/preferences";
import { Capacitor } from "@capacitor/core";
import { getRuntime } from "@/utils/capabilities";
import { isMacOS } from "@/utils/desktop";
import type {
  DynamicCoverCapabilities,
  DynamicCoverHandle,
  DynamicCoverProvider,
  DynamicCoverRequest,
  DynamicCoverResult,
} from "./types";

export type * from "./types";

interface IOSDynamicCoverBridge {
  getDynamicCoverCapabilities(): Promise<DynamicCoverCapabilities>;
  acquireDynamicCover(
    request: DynamicCoverRequest,
  ): Promise<DynamicCoverResult>;
  releaseDynamicCover(request: { leaseId: string }): Promise<void>;
}

const iosBridge = AonsokuNativePreferences as unknown as IOSDynamicCoverBridge;
const iosProvider: DynamicCoverProvider = {
  getCapabilities: () => iosBridge.getDynamicCoverCapabilities(),
  async acquire(request) {
    const result = await iosBridge.acquireDynamicCover(request);
    if (result.status !== "ready") return result;
    try {
      return { ...result, src: Capacitor.convertFileSrc(result.src) };
    } catch (error) {
      await iosBridge.releaseDynamicCover({ leaseId: result.leaseId });
      throw error;
    }
  },
  release: (leaseId) => iosBridge.releaseDynamicCover({ leaseId }),
};

function provider(): DynamicCoverProvider | undefined {
  const runtime = getRuntime();
  if (
    runtime === "capacitor-ios" &&
    Capacitor.isPluginAvailable("AonsokuNativePreferences")
  ) {
    return iosProvider;
  }
  if (
    isMacOS &&
    (runtime === "electron" || runtime === "tauri") &&
    typeof window !== "undefined"
  ) {
    return (window as Window & { aonsokuDynamicCover?: DynamicCoverProvider })
      .aonsokuDynamicCover;
  }
  return undefined;
}

export const dynamicCover = {
  async getCapabilities(): Promise<DynamicCoverCapabilities> {
    const host = provider();
    if (!host) {
      return {
        version: 1,
        available: false,
        formats: [],
        reason: "provider-not-installed",
      };
    }
    return host.getCapabilities();
  },

  async acquire(
    request: DynamicCoverRequest,
  ): Promise<
    DynamicCoverHandle | Exclude<DynamicCoverResult, { status: "ready" }>
  > {
    const host = provider();
    if (!host) {
      return { status: "unavailable", reason: "provider-not-installed" };
    }
    const capabilities = await host.getCapabilities();
    if (
      capabilities.version !== 1 ||
      !capabilities.available ||
      !capabilities.formats.includes(request.format)
    ) {
      return {
        status: "unavailable",
        reason: capabilities.reason ?? "unsupported-format",
      };
    }
    const result = await host.acquire(request);
    if (result.status !== "ready") return result;
    let releasing: Promise<void> | undefined;
    const release = () => {
      if (!releasing) {
        releasing = host.release(result.leaseId).catch((error) => {
          releasing = undefined;
          throw error;
        });
      }
      return releasing;
    };
    if (
      result.coverArtId !== request.coverArtId ||
      result.format !== request.format ||
      (request.mode === "static" && result.stage !== "static")
    ) {
      await release();
      return { status: "mismatch" };
    }
    return { ...result, release };
  },
};
