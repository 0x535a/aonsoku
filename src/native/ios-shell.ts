import { Capacitor } from "@capacitor/core";
import { ROUTES } from "@/routes/routesList";

export const nativeShellTabs = [
  ROUTES.LIBRARY.HOME,
  ROUTES.MOBILE.LIBRARY,
  ROUTES.MOBILE.SEARCH,
] as const;

export function nativeShellTabIndex(path: string): number {
  if (path === ROUTES.MOBILE.SEARCH) return 2;
  if (
    path === ROUTES.MOBILE.LIBRARY ||
    path === ROUTES.MOBILE.SETTINGS ||
    Object.values(ROUTES.LIBRARY).some(
      (route) =>
        route !== ROUTES.LIBRARY.HOME &&
        (path === route || path.startsWith(`${route}/`)),
    )
  )
    return 1;
  return 0;
}

export function nativeShellHandler() {
  if (Capacitor.getPlatform() !== "ios") return undefined;
  return (
    window as Window & {
      webkit?: {
        messageHandlers?: {
          aonsokuShell?: {
            postMessage: (state: Record<string, unknown>) => void;
          };
        };
      };
    }
  ).webkit?.messageHandlers?.aonsokuShell;
}

export interface NativeShellLayout {
  type: "layout";
  top: number;
  bottom: number;
  compact: boolean;
  active?: boolean;
}

export function isNativeShellLayout(
  value: unknown,
): value is NativeShellLayout {
  if (!value || typeof value !== "object") return false;
  const event = value as Partial<NativeShellLayout>;
  return (
    event.type === "layout" &&
    typeof event.top === "number" &&
    Number.isFinite(event.top) &&
    event.top >= 0 &&
    event.top <= 200 &&
    typeof event.bottom === "number" &&
    Number.isFinite(event.bottom) &&
    event.bottom >= 0 &&
    event.bottom <= 300 &&
    typeof event.compact === "boolean" &&
    (event.active === undefined || typeof event.active === "boolean")
  );
}
