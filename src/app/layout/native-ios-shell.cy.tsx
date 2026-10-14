import { Capacitor } from "@capacitor/core";
import { StrictMode } from "react";
import { useLocation } from "react-router-dom";
import { NativeIOSShell } from "@/app/layout/native-ios-shell";
import { usePlayerStore } from "@/store/player.store";

const props = { trackId: "song-1", title: "Song one", artist: "Artist", isPlaying: true, hasNext: true, progress: 42, duration: 180, canOpenPlayer: true };
function Fixture() {
  const location = useLocation();
  return <><NativeIOSShell {...props} /><output data-testid="path">{location.pathname}</output></>;
}

describe("iOS native shell integration", () => {
  beforeEach(() => {
    cy.changeLang("en-US");
    cy.stub(Capacitor, "getPlatform").returns("ios");
    cy.window().then((win) => {
      Object.defineProperty(win, "webkit", { configurable: true, value: { messageHandlers: { aonsokuShell: { postMessage: cy.stub().as("nativeMessage") } } } });
    });
    usePlayerStore.getState().actions.closeFullscreenPlayer();
  });

  it("publishes projected playback, accepts measured insets and navigates without replacing playback", () => {
    cy.mount(<StrictMode><Fixture /></StrictMode>, { routerProps: { initialEntries: ["/library/albums/album-1"] } });
    cy.get("@nativeMessage").should("have.been.calledWithMatch", { type: "state", title: "Song one", activeIndex: 1, isPlaying: true });
    cy.window().then((win) => win.dispatchEvent(new CustomEvent("aonsoku-native-shell", { detail: { type: "layout", top: 88, bottom: 100, compact: false } })));
    cy.get("html").should("have.class", "native-ios-shell").and("have.css", "--native-shell-bottom", "100px");
    cy.window().then((win) => win.dispatchEvent(new CustomEvent("aonsoku-native-shell", { detail: { type: "tab", index: 2 } })));
    cy.get('[data-testid="path"]').should("have.text", "/mobile/search");
    cy.window().then((win) => win.dispatchEvent(new CustomEvent("aonsoku-native-shell", { detail: { type: "tab", index: 1 } })));
    cy.get('[data-testid="path"]').should("have.text", "/library/albums/album-1");
  });

  it("gets out of the way of dialogs and fullscreen, then restores the controls", () => {
    cy.mount(<StrictMode><Fixture /></StrictMode>);
    cy.document().then((doc) => doc.body.setAttribute("data-scroll-locked", "1"));
    cy.get("@nativeMessage").should("have.been.calledWithMatch", { type: "visibility", obscured: true });
    cy.document().then((doc) => doc.body.removeAttribute("data-scroll-locked"));
    cy.then(() => usePlayerStore.getState().actions.openFullscreenPlayer("playing"));
    cy.get("@nativeMessage").should("have.been.calledWithMatch", { type: "state", obscured: true });
    cy.then(() => usePlayerStore.getState().actions.closeFullscreenPlayer());
    cy.get("@nativeMessage").should("have.been.calledWithMatch", { type: "visibility", obscured: false });
  });
});
