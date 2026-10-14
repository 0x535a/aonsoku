import { AonsokuNativePreferences } from "@aonsoku/capacitor-native/preferences";
import { Capacitor } from "@capacitor/core";
import { getRuntime } from "@/utils/capabilities";

export type ArtworkTier = "fp16" | "p8" | "p6";
export interface ArtworkOptions {
  immersiveEnabled: boolean;
  dynamicEnabled: boolean;
  quality: "auto" | ArtworkTier;
  wifiOnly: boolean;
}
export type ArtworkModelStatus =
  | "notDownloaded"
  | "queued"
  | "waitingForWifi"
  | "waitingForResources"
  | "downloading"
  | "compiling"
  | "ready"
  | "error";
export interface ArtworkModelState {
  tier: ArtworkTier;
  status: ArtworkModelStatus;
  progress: number;
  downloadBytes: number;
  storedBytes: number;
  error?: string;
}
export interface ArtworkState {
  supported: boolean;
  options: ArtworkOptions;
  deviceMemoryBytes: number;
  recommendedTier: ArtworkTier;
  effectiveTier: ArtworkTier | null;
  generationStatus: string;
  models: ArtworkModelState[];
  modelRevision: string;
}
interface IOSArtworkPreferences {
  getLockScreenArtworkState(): Promise<ArtworkState>;
  configureLockScreenArtwork(
    options: Partial<ArtworkOptions>,
  ): Promise<ArtworkState>;
  downloadLockScreenArtworkModel(options: { tier: ArtworkTier }): Promise<void>;
  cancelLockScreenArtworkDownload(options: {
    tier: ArtworkTier;
  }): Promise<void>;
  deleteLockScreenArtworkModel(options: { tier: ArtworkTier }): Promise<void>;
}
export function isLockScreenArtworkAvailable(): boolean {
  return (
    getRuntime() === "capacitor-ios" &&
    Capacitor.isPluginAvailable("AonsokuNativePreferences")
  );
}
function plugin(): IOSArtworkPreferences {
  if (!isLockScreenArtworkAvailable()) {
    throw new Error("Lock-screen artwork settings require native iOS.");
  }
  // These methods are an iOS extension of the native preferences plugin;
  // other runtimes keep the common preferences/audio contracts unchanged.
  return AonsokuNativePreferences as unknown as IOSArtworkPreferences;
}
export const lockScreenArtwork = {
  getState: () => plugin().getLockScreenArtworkState(),
  configure: (options: Partial<ArtworkOptions>) =>
    plugin().configureLockScreenArtwork(options),
  download: (tier: ArtworkTier) =>
    plugin().downloadLockScreenArtworkModel({ tier }),
  cancel: (tier: ArtworkTier) =>
    plugin().cancelLockScreenArtworkDownload({ tier }),
  remove: (tier: ArtworkTier) =>
    plugin().deleteLockScreenArtworkModel({ tier }),
};
