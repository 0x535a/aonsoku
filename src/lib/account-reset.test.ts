import { beforeEach, describe, expect, it, vi } from "vitest";

const tauri = vi.hoisted(() => ({
  available: false,
  invoke: vi.fn(async (_command: string) => undefined),
}));
vi.mock("@/utils/desktop", () => ({ hasTauriBridge: () => tauri.available }));
vi.mock("@/utils/tauri", () => ({ getTauriInvoke: () => tauri.invoke }));
vi.mock("@/native/artwork/tauri", () => ({
  isMacArtworkAvailable: () => false,
  macArtworkCommand: vi.fn(),
}));
vi.mock("@/native/preferences/facade", () => ({
  isNativePreferencesAvailable: () => false,
}));

import {
  ACCOUNT_RESET_KEY,
  finishAccountReset,
  resetAccountPreferences,
} from "./account-reset";

describe("account transition before mounting stores", () => {
  beforeEach(() => {
    localStorage.clear();
    tauri.available = false;
    tauri.invoke.mockReset().mockResolvedValue(undefined);
  });

  it("removes old library/media and personal choices before another user starts", async () => {
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.open("aonsoku-library", 1);
      request.onupgradeneeded = () => {
        request.result
          .createObjectStore("songs")
          .put({ title: "private song of A" }, "same-song-id");
      };
      request.onsuccess = () => {
        request.result.close();
        resolve();
      };
      request.onerror = () => reject(request.error);
    });
    localStorage.setItem("pinned_home_store", "private pins of A");
    localStorage.setItem("player_history", "private history of A");
    localStorage.setItem(
      "player_store",
      JSON.stringify({
        version: 6,
        state: {
          settings: {
            lyrics: { selectedCustomLyrics: { old: { key: "private" } } },
            volume: 0.5,
          },
          songlist: { currentSong: { id: "same-song-id" } },
        },
      }),
    );
    localStorage.setItem("theme_store", "user theme");
    localStorage.setItem(ACCOUNT_RESET_KEY, "switch-A-to-B");
    const removeMedia = vi.fn(async () => true);
    vi.stubGlobal("caches", { delete: removeMedia });
    await finishAccountReset();
    expect(
      indexedDB.databases
        ? (await indexedDB.databases()).some(
            (db) => db.name === "aonsoku-library",
          )
        : false,
    ).toBe(false);
    expect(localStorage.getItem("pinned_home_store")).toBeNull();
    expect(localStorage.getItem("player_history")).toBeNull();
    expect(JSON.parse(localStorage.getItem("player_store")!).state).toEqual({
      settings: { lyrics: { selectedCustomLyrics: {} }, volume: 0.5 },
    });
    expect(localStorage.getItem("theme_store")).toBe("user theme");
    expect(localStorage.getItem(ACCOUNT_RESET_KEY)).toBeNull();
    expect(removeMedia).toHaveBeenCalledWith("aonsoku-media-cache");
  });

  it("retains the reset marker for a retry when storage cleanup fails", async () => {
    localStorage.setItem(ACCOUNT_RESET_KEY, "pending");
    vi.stubGlobal("caches", {
      delete: vi.fn(async () => {
        throw new Error("storage unavailable");
      }),
    });
    await expect(finishAccountReset()).rejects.toThrow("storage unavailable");
    expect(localStorage.getItem(ACCOUNT_RESET_KEY)).toBe("pending");
  });

  it("stops Tauri playback and clears native audio before adopting another account", async () => {
    tauri.available = true;
    localStorage.setItem(ACCOUNT_RESET_KEY, "pending");
    vi.stubGlobal("caches", { delete: vi.fn(async () => true) });
    await finishAccountReset();
    expect(tauri.invoke.mock.calls.map(([command]) => command)).toEqual([
      "desktop_audio_stop",
      "media_clear_session",
      "desktop_cache_clear_audio_files",
    ]);
    expect(localStorage.getItem(ACCOUNT_RESET_KEY)).toBeNull();
  });

  it("preserves credentials but resets account counts and rejects corrupt personal stores", () => {
    const raw = JSON.stringify({
      state: { data: { username: "B", password: "token", songCount: 42 } },
    });
    expect(
      JSON.parse(resetAccountPreferences("app_store", raw)!).state.data,
    ).toEqual({
      username: "B",
      password: "token",
      songCount: null,
      favoriteCount: null,
    });
    expect(resetAccountPreferences("player_store", "broken")).toBeNull();
  });
});
