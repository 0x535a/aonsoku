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

  it("keeps the wide-window header and system sidebar without duplicate Web chrome", () => {
    cy.viewport(1366, 900);
    cy.mount(<>
      <Fixture />
      <header data-native-web-header className="w-full hidden md:flex fixed top-0 h-header">
        <div data-native-web-sidebar-toggle><button type="button">Toggle sidebar</button></div>
        <button type="button">Account</button>
      </header>
      <aside data-native-web-sidebar className="hidden xl:flex fixed top-header bottom-0 pb-player w-sidebar" />
      <main data-native-main className="md:pl-mini-sidebar xl:pl-sidebar pt-header" />
      <footer data-native-web-player />
    </>);
    cy.window().then((win) => win.dispatchEvent(new CustomEvent("aonsoku-native-shell", { detail: { type: "layout", top: 0, bottom: 100, compact: false } })));
    cy.get('[data-native-web-header]').should("be.visible");
    cy.contains("button", "Account").should("be.visible");
    cy.contains("button", "Toggle sidebar").should("not.be.visible");
    cy.get('[data-native-web-sidebar]').should("have.css", "display", "none");
    cy.get('[data-native-main]').should("have.css", "padding-left", "0px");
    cy.get('[data-native-web-player]').should("have.css", "display", "none");
    cy.viewport(600, 900);
    cy.window().then((win) => win.dispatchEvent(new CustomEvent("aonsoku-native-shell", { detail: { type: "layout", top: 0, bottom: 180, compact: true } })));
    cy.get('[data-native-web-header]').should("have.css", "display", "none");
    cy.get('[data-native-web-sidebar]').should("have.css", "display", "none");
    cy.get('[data-native-main]').should("have.css", "padding-left", "0px");
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
