import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PlaybackSnapshot } from "@/coordination/types";
import { LanControlMessageType } from "@/types/lanControl";
import type { IPlayerContext } from "@/types/playerContext";
import { LoopState } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";
import { createQueueActions } from "./queue-actions";

const mocks = vi.hoisted(() => ({
  seekPlaybackTarget: vi.fn(),
}));

vi.mock("@/player/playback/backend-registry", () => ({
  seekPlaybackTarget: mocks.seekPlaybackTarget,
}));

vi.mock("@/player/queue-controller", () => ({
  getNativeQueueController: () => null,
}));

function makeSong(id: string): ISong {
  return {
    id,
    title: id,
    album: "album",
    artist: "artist",
    duration: 120,
  } as ISong;
}

function makeState(): IPlayerContext {
  const currentSong = makeSong("a");

  return {
    playerState: {
      audioPlayerRef: { currentTime: 5 },
      isPlaying: false,
      isTransitioning: false,
      loopState: LoopState.Off,
      currentDuration: 120,
    },
    playerProgress: {
      progress: 2,
      bufferedProgress: 10,
    },
    songlist: {
      currentSong,
      contextQueue: {
        songs: [currentSong],
        currentIndex: 0,
        sourceId: null,
        sourceName: null,
      },
      sourceQueue: {
        songs: [currentSong],
        currentIndex: 0,
        sourceId: null,
        sourceName: null,
      },
      userQueue: { songs: [] },
      isInUserQueue: false,
      playedUserQueueHistory: [],
      isShuffleActive: false,
      shuffleHistory: [],
      shuffleStartHistory: [],
      originalContextSongs: [],
      originalUserSongs: [],
      radioList: [],
    },
  } as unknown as IPlayerContext;
}

describe("queue actions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("restarts the current song when previous is used without a real previous song", () => {
    const state = makeState();
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.playPrevSong?.();

    expect(state.playerProgress.progress).toBe(0);
    expect(state.playerProgress.bufferedProgress).toBe(0);
    expect(state.songlist.contextQueue.currentIndex).toBe(0);
    expect(mocks.seekPlaybackTarget).toHaveBeenCalledWith(
      state.playerState.audioPlayerRef,
      0,
    );
  });

  it("adds play-next songs before the existing user queue", () => {
    const state = makeState();
    state.songlist.userQueue.songs = [makeSong("queued")];
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setNextOnQueue?.([makeSong("next")]);

    expect(state.songlist.userQueue.songs.map((song) => song.id)).toEqual([
      "next",
      "queued",
    ]);
  });

  it("keeps the current user-queue song first when adding play-next songs", () => {
    const state = makeState();
    state.songlist.isInUserQueue = true;
    state.songlist.userQueue.songs = [makeSong("current"), makeSong("queued")];
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setNextOnQueue?.([makeSong("next-1"), makeSong("next-2")]);

    expect(state.songlist.userQueue.songs.map((song) => song.id)).toEqual([
      "current",
      "next-1",
      "next-2",
      "queued",
    ]);
  });

  it("replaces a non-empty context queue immediately", () => {
    const state = makeState();
    state.playerState.isPlaying = true;
    state.songlist.userQueue.songs = [makeSong("manually-queued")];
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setSongList?.([makeSong("replacement")], 0, false, {
      albumId: "album-2",
    });

    expect(state.songlist.contextQueue.songs[0]?.id).toBe("replacement");
    expect(state.songlist.userQueue.songs).toEqual([]);
    expect(state.songlist.contextQueue.sourceId).toEqual({
      type: "album",
      id: "album-2",
    });
  });

  it("replaces remote playback immediately even with manual songs queued", () => {
    const state = makeState();
    const remoteSend = vi.fn(() => true);
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state,
      isRemoteActive: () => true,
      getRemotePlaybackTarget: () => ({
        deviceId: "remote-device",
        snapshot: {
          songId: "remote-current",
          isPlaying: true,
          userQueue: ["manual"],
          contextQueue: ["remote-current"],
          inUserQueue: false,
          shuffle: false,
          sourceId: null,
        } as PlaybackSnapshot,
      }),
      remoteSend,
      clearSonglistState: vi.fn(),
    });
    actions.setSongList([makeSong("replacement")], 0, false, {
      albumId: "album-2",
    });
    expect(remoteSend).toHaveBeenCalledWith(LanControlMessageType.PLAY_ALBUM, {
      albumId: "album-2",
      songIndex: 0,
    });
    expect(state.songlist.contextQueue.songs[0]?.id).toBe("a");
  });

  it("replaces immediately when callers pass the compatibility option", () => {
    const state = makeState();
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setSongList?.(
      [makeSong("replacement")],
      0,
      false,
      { albumId: "album-2" },
      "Album 2",
      { bypassQueueConfirmation: true },
    );

    expect(state.songlist.contextQueue.songs[0]?.id).toBe("replacement");
    expect(state.songlist.contextQueue.sourceId).toEqual({
      type: "album",
      id: "album-2",
    });
  });

  it.each(["next", "last"] as const)(
    "preserves the requested remote %s insertion position",
    (position) => {
      const state = makeState();
      const remoteSend = vi.fn(() => true);
      const actions = createQueueActions({
        set: (fn) => fn(state as never),
        get: () => state as never,
        isRemoteActive: () => true,
        remoteSend,
        clearSonglistState: vi.fn(),
      });
      const add =
        position === "next" ? actions.setNextOnQueue : actions.setLastOnQueue;
      add?.([makeSong("selected")], { albumId: "album-with-other-songs" });
      expect(remoteSend).toHaveBeenCalledWith(
        LanControlMessageType.ADD_TO_QUEUE,
        {
          songIds: ["selected"],
          position,
        },
      );
    },
  );

  it("replaces the queue with one song immediately", () => {
    const state = makeState();
    state.playerState.isPlaying = true;
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });
    Object.assign(state, { actions });

    actions.playSong?.(makeSong("replacement"));

    expect(state.songlist.contextQueue.songs[0]?.id).toBe("replacement");
  });
});
