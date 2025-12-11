

set_rule(self.multiworld.get_entrance("Upper Undead Burg -> Undead Burg Basement Door", self.player),
         lambda state: state.has("Taurus Demon Defeated", self.player) and state.has("Basement Key", self.player))