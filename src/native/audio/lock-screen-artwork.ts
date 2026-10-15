import { AonsokuNativePreferences } from "@aonsoku/capacitor-native/preferences";
import { Capacitor } from "@capacitor/core";
import {
  isMacArtworkAvailable,
  macArtworkCommand,
} from "@/native/artwork/tauri";
import { getRuntime } from "@/utils/capabilities";

export type ArtworkTier = "fp16" | "p8" | "p6";
export interface ArtworkCachedVideo {
  id: string;
  kind: "static" | "dynamic";
  format: string;
  sizeBytes: number;
  cachedAt: number;
  lastAccessedAt: number;
  protected: boolean;
}
export interface ArtworkOptions {
  immersiveEnabled: boolean;
  dynamicEnabled: boolean;
  quality: "auto" | ArtworkTier;
  wifiOnly: boolean;
  /** iOS only; absent on other hosts. Missing values retain protection. */
  resourceProtectionEnabled?: boolean;
  motionAmplitude: number;
  motionSpeed: number;
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
interface ArtworkPreferencesBridge {
  listLockScreenArtworkVideos(): Promise<{ videos: ArtworkCachedVideo[] }>;
  deleteLockScreenArtworkVideo(options: { id: string }): Promise<void>;
  clearLockScreenArtworkVideos(options: {
    kind: "all" | "static" | "dynamic";
  }): Promise<{ deleted: number; retained: number }>;
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
    isMacArtworkAvailable() ||
    (getRuntime() === "capacitor-ios" &&
      Capacitor.isPluginAvailable("AonsokuNativePreferences"))
  );
}
function plugin(): ArtworkPreferencesBridge {
  if (isMacArtworkAvailable()) return macPreferences;
  if (!isLockScreenArtworkAvailable()) {
    throw new Error("Artwork settings require native iOS or macOS Tauri.");
  }
  // These methods are an iOS extension of the native preferences plugin;
  // other runtimes keep the common preferences/audio contracts unchanged.
  return AonsokuNativePreferences as unknown as ArtworkPreferencesBridge;
}
const macPreferences: ArtworkPreferencesBridge = {
  listLockScreenArtworkVideos: () => macArtworkCommand("listVideos"),
  deleteLockScreenArtworkVideo: (options) =>
    macArtworkCommand("deleteVideo", options),
  clearLockScreenArtworkVideos: (options) =>
    macArtworkCommand("clearVideos", options),
  getLockScreenArtworkState: () => macArtworkCommand("state"),
  configureLockScreenArtwork: (options) =>
    macArtworkCommand("configure", options),
  downloadLockScreenArtworkModel: (options) =>
    macArtworkCommand("download", options),
  cancelLockScreenArtworkDownload: (options) =>
    macArtworkCommand("cancel", options),
  deleteLockScreenArtworkModel: (options) =>
    macArtworkCommand("remove", options),
};
export const lockScreenArtwork = {
  listVideos: async () => (await plugin().listLockScreenArtworkVideos()).videos,
  deleteVideo: (id: string) => plugin().deleteLockScreenArtworkVideo({ id }),
  clearVideos: (kind: "all" | "static" | "dynamic" = "all") =>
    plugin().clearLockScreenArtworkVideos({ kind }),
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
