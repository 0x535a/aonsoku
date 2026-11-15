import { usePlayerStore } from "@/store/player.store";
import type { ISong } from "@/types/responses/song";
import { FullscreenSongQueue } from "./queue";

for (const useVirtualization of [false, true]) {
  describe(`Fullscreen queue occurrences (virtualized=${useVirtualization})`, () => {
    beforeEach(() => {
      cy.changeLang("en-US");
      cy.viewport(500, 1000);
      cy.mockCoverArt();
    });

    it("shows queued copies of the current song and selects the exact occurrence", () => {
      cy.fixture("songs/random").then((songs: ISong[]) => {
        const { actions } = usePlayerStore.getState();
        actions.clearPlayerState();
        actions.setSongList([songs[0], songs[1]], 0);
        actions.setLastOnQueue([songs[0], songs[0], songs[1]]);
        cy.mount(<div className="h-screen w-screen"><FullscreenSongQueue hideHistory useVirtualization={useVirtualization} /></div>);
        cy.get('[data-queue-tier="user"]').should("have.length", 3);
        cy.get('[data-queue-tier="user"][data-queue-index="1"]').click();
        cy.then(() => {
          const { songlist } = usePlayerStore.getState();
          expect(songlist.isInUserQueue).to.equal(true);
          expect(songlist.userQueue.songs).to.have.length(2);
          expect(songlist.playedUserQueueHistory).to.have.length(1);
        });
        cy.get('[data-queue-tier="user"]').should("have.length", 1);
      });
    });

    it("renders each repeated context occurrence with its own queue index", () => {
      cy.fixture("songs/random").then((songs: ISong[]) => {
        const { actions } = usePlayerStore.getState();
        actions.clearPlayerState();
        actions.setSongList([songs[0], songs[1], songs[1]], 0);
        cy.mount(<div className="h-screen w-screen"><FullscreenSongQueue hideHistory useVirtualization={useVirtualization} /></div>);
        cy.get('[data-queue-tier="context"][data-queue-index]').should("have.length", 2);
        cy.get('[data-queue-tier="context"][data-queue-index="2"]').click();
        cy.then(() => expect(usePlayerStore.getState().songlist.contextQueue.currentIndex).to.equal(2));
      });
    });
  });
}
