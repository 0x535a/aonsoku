import { useEffect, useLayoutEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { useLocation, useNavigate } from "react-router-dom";
import {
  isNativeShellLayout,
  nativeShellHandler,
  nativeShellTabIndex,
  nativeShellTabs,
} from "@/native/ios-shell";
import { openFullscreenPlayerWithHistory } from "@/routes/fullscreenRouter";
import { usePlayerStore } from "@/store/player.store";
import { useThemeStore } from "@/store/theme.store";
import { isDarkTheme } from "@/types/themeContext";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";

export interface NativeIOSShellProps {
  trackId: string;
  title: string;
  artist: string;
  isPlaying: boolean;
  hasNext: boolean;
  progress?: number;
  duration?: number;
  canOpenPlayer: boolean;
}

// Mount only when the iOS host advertises the message handler. Other runtimes keep their UI.
export function NativeIOSShell(props: NativeIOSShellProps) {
  return nativeShellHandler() ? <ShellSync {...props} /> : null;
}

function ShellSync(props: NativeIOSShellProps) {
  const { t } = useTranslation();
  const location = useLocation();
  const navigate = useNavigate();
  const fullscreen = usePlayerStore(
    (state) => state.playerState.fullscreenPlayerOpen,
  );
  const localProgress = usePlayerStore(
    (state) => state.playerProgress.progress,
  );
  const localDuration = usePlayerStore(
    (state) => state.playerState.currentDuration ?? 0,
  );
  const playbackProgress = props.progress ?? localProgress;
  const playbackDuration = props.duration ?? localDuration;
  const theme = useThemeStore((state) => state.theme);
  const latest = useRef({ props, location, navigate });
  latest.current = { props, location, navigate };
  const tabLocations = useRef(new Map<number, string>());
  const activeIndex = nativeShellTabIndex(location.pathname);
  tabLocations.current.set(
    activeIndex,
    location.pathname +
      location.search
        .replace(/([?&])player=[^&]+&?/, "$1")
        .replace(/[?&]$/, ""),
  );
  const lastState = useRef("");
  const lastArtwork = useRef("");

  useLayoutEffect(() => {
    const handler = nativeShellHandler();
    if (!handler) return;
    const root = document.documentElement;
    lastState.current = "";
    root.classList.add("native-ios-shell");
    const onEvent = (event: Event) => {
      const detail: unknown = (event as CustomEvent).detail;
      if (isNativeShellLayout(detail)) {
        root.style.setProperty("--native-shell-top", `${detail.top}px`);
        root.style.setProperty("--native-shell-bottom", `${detail.bottom}px`);
        root.classList.toggle("native-ios-compact", detail.compact);
        return;
      }
      if (!detail || typeof detail !== "object") return;
      const action = detail as {
        type?: string;
        index?: number;
        action?: string;
      };
      const current = latest.current;
      if (
        action.type === "tab" &&
        Number.isInteger(action.index) &&
        action.index !== undefined &&
        action.index >= 0 &&
        action.index <= 2
      ) {
        current.navigate(
          tabLocations.current.get(action.index) ??
            nativeShellTabs[action.index],
        );
      } else if (action.type === "back") {
        current.navigate(-1);
      } else if (action.type === "openPlayer" && current.props.canOpenPlayer) {
        openFullscreenPlayerWithHistory("playing");
      } else if (action.type === "control") {
        const actions = usePlayerStore.getState().actions;
        if (action.action === "togglePlayPause" && current.props.trackId)
          actions.togglePlayPause();
        if (action.action === "playNextSong" && current.props.hasNext)
          actions.playNextSong();
      }
    };
    window.addEventListener("aonsoku-native-shell", onEvent);
    return () => {
      handler.postMessage({ type: "state", enabled: false });
      window.removeEventListener("aonsoku-native-shell", onEvent);
      root.classList.remove("native-ios-shell", "native-ios-compact");
      root.style.removeProperty("--native-shell-top");
      root.style.removeProperty("--native-shell-bottom");
    };
  }, []);

  // Suspend the overlay for every Web dialog/sheet, including ones opened outside playback.
  // Observing only body scroll-lock attributes avoids watching long-list DOM mutations.
  const obstructed = useRef(false);
  useLayoutEffect(() => {
    const publish = () => {
      obstructed.current = document.body.hasAttribute("data-scroll-locked");
      nativeShellHandler()?.postMessage({
        type: "visibility",
        obscured: fullscreen || obstructed.current,
      });
    };
    const observer = new MutationObserver(publish);
    observer.observe(document.body, {
      attributes: true,
      attributeFilter: ["data-scroll-locked"],
    });
    publish();
    return () => observer.disconnect();
  }, [fullscreen]);

  useLayoutEffect(() => {
    const state = {
      type: "state",
      enabled: true,
      obscured: fullscreen || obstructed.current,
      trackId: props.trackId,
      hasContent: Boolean(props.trackId),
      canOpenPlayer: props.canOpenPlayer,
      title: props.title,
      artist: props.artist,
      isPlaying: props.isPlaying,
      hasNext: props.hasNext,
      progressFraction:
        playbackDuration > 0
          ? Math.min(1, Math.max(0, playbackProgress / playbackDuration))
          : 0,
      progressLabel: `${convertSecondsToTime(playbackProgress)} / ${convertSecondsToTime(playbackDuration)}`,
      activeIndex,
      labels: [
        t("sidebar.home"),
        t("sidebar.library"),
        t("sidebar.miniSearch"),
      ],
      playLabel: t("player.tooltips.play"),
      pauseLabel: t("player.tooltips.pause"),
      nextLabel: t("player.tooltips.next"),
      backLabel: t("navigation.back"),
      openPlayerLabel: t("fullscreen.switchButton"),
      trackLabel: `${props.title}, ${props.artist}`,
      dark: isDarkTheme(theme),
    };
    const serialized = JSON.stringify(state);
    if (serialized !== lastState.current) {
      lastState.current = serialized;
      nativeShellHandler()?.postMessage(state);
    }
  }, [
    props,
    playbackProgress,
    playbackDuration,
    activeIndex,
    fullscreen,
    t,
    theme,
  ]);

  useEffect(() => {
    lastArtwork.current = "";
    const sendArtwork = (event?: Event) => {
      const image = document.getElementById("track-song-image");
      if (
        !(image instanceof HTMLImageElement) ||
        (event && event.target !== image) ||
        image
          .closest("[data-native-song-id]")
          ?.getAttribute("data-native-song-id") !== props.trackId ||
        !image.complete ||
        !image.naturalWidth
      )
        return;
      const key = `${props.trackId}|${image.currentSrc}`;
      if (key === lastArtwork.current) return;
      try {
        const canvas = document.createElement("canvas");
        canvas.width = 128;
        canvas.height = 128;
        const context = canvas.getContext("2d");
        if (!context) return;
        context.drawImage(image, 0, 0, 128, 128);
        const coverData = canvas.toDataURL("image/jpeg", 0.75);
        nativeShellHandler()?.postMessage({
          type: "artwork",
          trackId: props.trackId,
          coverData,
        });
        lastArtwork.current = key;
      } catch {
        // Inaccessible/invalid covers retain the native placeholder, without a second fetch.
      }
    };
    document.addEventListener("load", sendArtwork, true);
    sendArtwork();
    return () => document.removeEventListener("load", sendArtwork, true);
  }, [props.trackId]);
  return null;
}
