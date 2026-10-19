package rules

// Element represents one of the 5 element types plus Aether wildcard (GDD v2 Â§4).
type Element string

const (
	ELight  Element = "light"
	EWater  Element = "water"
	ENature Element = "nature"
	EFire   Element = "fire"
	EShadow Element = "shadow"
	EAether Element = "aether"
)

var AllElements = []Element{ELight, EWater, ENature, EFire, EShadow}

// Cost is a map of element â†’ quantity.
type Cost map[Element]int

// CharacterCard is the server-side card data (GDD v2 Â§6).
type CharacterCard struct {
	ID       string  
	Name     string  
	Tier     int     
	Power    int     
	Affinity Element 
	HireCost Cost    
}

// Artifact is the server-side artifact data (GDD v2 Â§8).
type Artifact struct {
	ID          string 
	Name        string 
	Requirement Cost    // affinity counts required (hired characters)
}

// AllCards â€” 90 characters with Splendor-exact costs and Power (GDD v2 Â§7).
// Affinity = race gem: Hâ†’Light, Mâ†’Water, Eâ†’Nature, Dâ†’Fire, Vâ†’Shadow.
var AllCards = []CharacterCard{

	// â”€â”€ TIER 1 HUMANS (Diamond / Light) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "H-01", Name: "Elara the Farmhand", Tier: 1, Power: 0, Affinity: ELight, HireCost: Cost{EShadow: 3}},
	{ID: "H-02", Name: "Brother Cael", Tier: 1, Power: 0, Affinity: ELight, HireCost: Cost{EShadow: 2, ENature: 2}},
	{ID: "H-03", Name: "Venn the Scout", Tier: 1, Power: 0, Affinity: ELight, HireCost: Cost{EWater: 1, ENature: 1, EFire: 1, EShadow: 1}},
	{ID: "H-04", Name: "Mira the Militia Guard", Tier: 1, Power: 0, Affinity: ELight, HireCost: Cost{ENature: 2, EFire: 1}},
	{ID: "H-05", Name: "Aldric the Sellsword", Tier: 1, Power: 0, Affinity: ELight, HireCost: Cost{EWater: 1, ENature: 2, EShadow: 1}},
	{ID: "H-06", Name: "Soren the Apprentice Mage", Tier: 1, Power: 0, Affinity: ELight, HireCost: Cost{ENature: 1, EFire: 1, EShadow: 1}},
	{ID: "H-07", Name: "Commander Thessa", Tier: 1, Power: 0, Affinity: ELight, HireCost: Cost{EWater: 1, ENature: 1, EFire: 2, EShadow: 1}},
	{ID: "H-08", Name: "Ludo the Street Alchemist", Tier: 1, Power: 1, Affinity: ELight, HireCost: Cost{EWater: 4}},

	// â”€â”€ TIER 2 HUMANS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "H-09", Name: "Sir Edran the Lightkeeper", Tier: 2, Power: 1, Affinity: ELight, HireCost: Cost{ENature: 3, EFire: 2, EShadow: 2}},
	{ID: "H-10", Name: "Archmage Sylva", Tier: 2, Power: 1, Affinity: ELight, HireCost: Cost{ELight: 2, ENature: 3, EFire: 3}},
	{ID: "H-11", Name: "General Davan", Tier: 2, Power: 2, Affinity: ELight, HireCost: Cost{ENature: 1, EFire: 4, EShadow: 2}},
	{ID: "H-12", Name: "Seraphine the Radiant", Tier: 2, Power: 2, Affinity: ELight, HireCost: Cost{EFire: 5, EShadow: 3}},
	{ID: "H-13", Name: "The High Inquisitor", Tier: 2, Power: 2, Affinity: ELight, HireCost: Cost{ELight: 5}},
	{ID: "H-14", Name: "Saint Mirena of the Broken Crown", Tier: 2, Power: 3, Affinity: ELight, HireCost: Cost{ELight: 6}},

	// â”€â”€ TIER 3 HUMANS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "H-15", Name: "High King Alderon", Tier: 3, Power: 3, Affinity: ELight, HireCost: Cost{EWater: 3, ENature: 3, EFire: 5, EShadow: 3}},
	{ID: "H-16", Name: "The Prophet of the First Light", Tier: 3, Power: 4, Affinity: ELight, HireCost: Cost{EWater: 7}},
	{ID: "H-17", Name: "The Warlord Auron", Tier: 3, Power: 4, Affinity: ELight, HireCost: Cost{EWater: 3, ENature: 6, EFire: 3}},
	{ID: "H-18", Name: "Lumis, The Ascended", Tier: 3, Power: 5, Affinity: ELight, HireCost: Cost{EWater: 7, EFire: 3}},

	// â”€â”€ TIER 1 MERFOLK (Sapphire / Water) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "M-01", Name: "Cora the Tidewatcher", Tier: 1, Power: 0, Affinity: EWater, HireCost: Cost{ELight: 1, ENature: 2}},
	{ID: "M-02", Name: "Finn the Reef Runner", Tier: 1, Power: 0, Affinity: EWater, HireCost: Cost{ELight: 1, ENature: 1, EFire: 1, EShadow: 1}},
	{ID: "M-03", Name: "Nyla the Shellweaver", Tier: 1, Power: 0, Affinity: EWater, HireCost: Cost{ELight: 1, ENature: 2, EShadow: 1}},
	{ID: "M-04", Name: "Talan the Storm Caller", Tier: 1, Power: 0, Affinity: EWater, HireCost: Cost{ENature: 2, EShadow: 2}},
	{ID: "M-05", Name: "Selene the Sea Guard", Tier: 1, Power: 0, Affinity: EWater, HireCost: Cost{ELight: 1, ENature: 1, EFire: 1, EShadow: 2}},
	{ID: "M-06", Name: "Old Marec", Tier: 1, Power: 0, Affinity: EWater, HireCost: Cost{EFire: 1, EShadow: 2}},
	{ID: "M-07", Name: "Mira of the Pearl Guard", Tier: 1, Power: 0, Affinity: EWater, HireCost: Cost{ELight: 1, EFire: 2, EShadow: 2}},
	{ID: "M-08", Name: "Drave the Net Fisher", Tier: 1, Power: 1, Affinity: EWater, HireCost: Cost{ENature: 4}},

	// â”€â”€ TIER 2 MERFOLK â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "M-09", Name: "The Tide Duchess", Tier: 2, Power: 1, Affinity: EWater, HireCost: Cost{EWater: 2, ENature: 2, EFire: 3}},
	{ID: "M-10", Name: "Hydromancer Ven", Tier: 2, Power: 1, Affinity: EWater, HireCost: Cost{ELight: 2, EWater: 3, EShadow: 3}},
	{ID: "M-11", Name: "Deep Seer Iona", Tier: 2, Power: 2, Affinity: EWater, HireCost: Cost{ELight: 5, EWater: 3}},
	{ID: "M-12", Name: "Admiral Corven", Tier: 2, Power: 2, Affinity: EWater, HireCost: Cost{EWater: 5}},
	{ID: "M-13", Name: "Lysara the Abyssal", Tier: 2, Power: 2, Affinity: EWater, HireCost: Cost{ELight: 2, EFire: 1, EShadow: 4}},
	{ID: "M-14", Name: "The Stormborn Warrior", Tier: 2, Power: 3, Affinity: EWater, HireCost: Cost{EWater: 6}},

	// â”€â”€ TIER 3 MERFOLK â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "M-15", Name: "King Nereus of the Deep Throne", Tier: 3, Power: 3, Affinity: EWater, HireCost: Cost{ELight: 3, EWater: 3, ENature: 5, EShadow: 3}},
	{ID: "M-16", Name: "Tempest, The Unbound", Tier: 3, Power: 4, Affinity: EWater, HireCost: Cost{ELight: 7}},
	{ID: "M-17", Name: "Aquaria, The Ocean Dreamer", Tier: 3, Power: 4, Affinity: EWater, HireCost: Cost{ELight: 6, EWater: 3, EShadow: 3}},
	{ID: "M-18", Name: "Aqueon, Warden of Tides", Tier: 3, Power: 5, Affinity: EWater, HireCost: Cost{ELight: 7, EWater: 3}},

	// â”€â”€ TIER 1 ELVES (Emerald / Nature) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "E-01", Name: "Lyra the Seedkeeper", Tier: 1, Power: 0, Affinity: ENature, HireCost: Cost{ELight: 2, EShadow: 1}},
	{ID: "E-02", Name: "Bran the Bark Carver", Tier: 1, Power: 0, Affinity: ENature, HireCost: Cost{ELight: 1, EWater: 1, EFire: 1, EShadow: 1}},
	{ID: "E-03", Name: "Sael the Runner", Tier: 1, Power: 0, Affinity: ENature, HireCost: Cost{ELight: 1, EWater: 1, EFire: 1, EShadow: 2}},
	{ID: "E-04", Name: "Thorn the Briar Guard", Tier: 1, Power: 0, Affinity: ENature, HireCost: Cost{EFire: 3}},
	{ID: "E-05", Name: "Wren the Herb Gatherer", Tier: 1, Power: 0, Affinity: ENature, HireCost: Cost{ELight: 2, EWater: 1}},
	{ID: "E-06", Name: "Ash the Young Ranger", Tier: 1, Power: 0, Affinity: ENature, HireCost: Cost{EWater: 1, EFire: 2, EShadow: 1}},
	{ID: "E-07", Name: "Ivy the Grove Tender", Tier: 1, Power: 0, Affinity: ENature, HireCost: Cost{ELight: 1, EWater: 3, ENature: 1}},
	{ID: "E-08", Name: "Flint the Woodcutter", Tier: 1, Power: 1, Affinity: ENature, HireCost: Cost{EFire: 4}},

	// â”€â”€ TIER 2 ELVES â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "E-09", Name: "Thornwarden Sylvara", Tier: 2, Power: 1, Affinity: ENature, HireCost: Cost{ELight: 3, EWater: 2, EShadow: 2}},
	{ID: "E-10", Name: "The Root Oracle", Tier: 2, Power: 1, Affinity: ENature, HireCost: Cost{ELight: 2, EWater: 3, EFire: 3}},
	{ID: "E-11", Name: "Brightleaf the Battle Druid", Tier: 2, Power: 2, Affinity: ENature, HireCost: Cost{ENature: 5}},
	{ID: "E-12", Name: "Windwhisper Caelum", Tier: 2, Power: 2, Affinity: ENature, HireCost: Cost{EWater: 5, ENature: 3}},
	{ID: "E-13", Name: "Archdruid Elowen", Tier: 2, Power: 2, Affinity: ENature, HireCost: Cost{ELight: 4, EWater: 2, EShadow: 1}},
	{ID: "E-14", Name: "The Green Knight", Tier: 2, Power: 3, Affinity: ENature, HireCost: Cost{ENature: 6}},

	// â”€â”€ TIER 3 ELVES â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "E-15", Name: "Queen Aelindra of the Ancient Bough", Tier: 3, Power: 3, Affinity: ENature, HireCost: Cost{ELight: 3, EWater: 5, EFire: 3, EShadow: 3}},
	{ID: "E-16", Name: "Verdant, The Awakened", Tier: 3, Power: 4, Affinity: ENature, HireCost: Cost{EWater: 7}},
	{ID: "E-17", Name: "The Last Treesinger", Tier: 3, Power: 4, Affinity: ENature, HireCost: Cost{ELight: 3, EWater: 6, ENature: 3}},
	{ID: "E-18", Name: "Gaia-Touched, The Forest's Voice", Tier: 3, Power: 5, Affinity: ENature, HireCost: Cost{EWater: 7, ENature: 3}},

	// â”€â”€ TIER 1 DRAGONKIN (Ruby / Fire) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "D-01", Name: "Kael the Ember Ward", Tier: 1, Power: 0, Affinity: EFire, HireCost: Cost{ELight: 2, ENature: 1}},
	{ID: "D-02", Name: "Scalechild Rya", Tier: 1, Power: 0, Affinity: EFire, HireCost: Cost{ELight: 1, EWater: 1, ENature: 1, EShadow: 1}},
	{ID: "D-03", Name: "Forge Tender Brax", Tier: 1, Power: 0, Affinity: EFire, HireCost: Cost{ELight: 2, ENature: 1, EShadow: 1}},
	{ID: "D-04", Name: "Cinderback the Scout", Tier: 1, Power: 0, Affinity: EFire, HireCost: Cost{ELight: 1, ENature: 1, EShadow: 2}},
	{ID: "D-05", Name: "Ash the Pit Fighter", Tier: 1, Power: 0, Affinity: EFire, HireCost: Cost{ELight: 2, EShadow: 2}},
	{ID: "D-06", Name: "Pyrith the Young Mage", Tier: 1, Power: 0, Affinity: EFire, HireCost: Cost{EWater: 2, ENature: 1}},
	{ID: "D-07", Name: "Cinder the Blacksmith's Daughter", Tier: 1, Power: 0, Affinity: EFire, HireCost: Cost{ELight: 1, EWater: 2, ENature: 2}},
	{ID: "D-08", Name: "Flamecrest Warrior", Tier: 1, Power: 1, Affinity: EFire, HireCost: Cost{EShadow: 4}},

	// â”€â”€ TIER 2 DRAGONKIN â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "D-09", Name: "Magma Warden Torrak", Tier: 2, Power: 1, Affinity: EFire, HireCost: Cost{EWater: 3, ENature: 2, EShadow: 2}},
	{ID: "D-10", Name: "Pyromancer Vera", Tier: 2, Power: 1, Affinity: EFire, HireCost: Cost{ELight: 2, EFire: 2, EShadow: 3}},
	{ID: "D-11", Name: "The Ember Chancellor", Tier: 2, Power: 2, Affinity: EFire, HireCost: Cost{ELight: 1, EShadow: 4, EFire: 2}},
	{ID: "D-12", Name: "Blazewing, Winged Champion", Tier: 2, Power: 2, Affinity: EFire, HireCost: Cost{EFire: 5}},
	{ID: "D-13", Name: "Ashspeaker Venna", Tier: 2, Power: 2, Affinity: EFire, HireCost: Cost{ELight: 3, EFire: 5}},
	{ID: "D-14", Name: "The Dragon-Blood Warrior", Tier: 2, Power: 3, Affinity: EFire, HireCost: Cost{EFire: 6}},

	// â”€â”€ TIER 3 DRAGONKIN â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "D-15", Name: "The Volcano Throne's Emperor", Tier: 3, Power: 3, Affinity: EFire, HireCost: Cost{ELight: 3, EWater: 3, ENature: 3, EShadow: 5}},
	{ID: "D-16", Name: "Infernus, Flame Without End", Tier: 3, Power: 4, Affinity: EFire, HireCost: Cost{EShadow: 7}},
	{ID: "D-17", Name: "Pyraxis the World-Burner", Tier: 3, Power: 4, Affinity: EFire, HireCost: Cost{ELight: 3, EFire: 3, EShadow: 6}},
	{ID: "D-18", Name: "Ignis-Prime, The First Flame", Tier: 3, Power: 5, Affinity: EFire, HireCost: Cost{EFire: 3, EShadow: 7}},

	// â”€â”€ TIER 1 VOID BORN (Onyx / Shadow) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "V-01", Name: "Unit-7 the Courier Droid", Tier: 1, Power: 0, Affinity: EShadow, HireCost: Cost{ELight: 1, EWater: 1, ENature: 1, EFire: 1}},
	{ID: "V-02", Name: "Glitch the Rogue Fragment", Tier: 1, Power: 0, Affinity: EShadow, HireCost: Cost{ELight: 2, EWater: 1, ENature: 1, EFire: 1}},
	{ID: "V-03", Name: "Watchdog Protocol", Tier: 1, Power: 0, Affinity: EShadow, HireCost: Cost{ENature: 1, EFire: 3}},
	{ID: "V-04", Name: "Nullshade Scout", Tier: 1, Power: 0, Affinity: EShadow, HireCost: Cost{EWater: 2, EFire: 2}},
	{ID: "V-05", Name: "Circuit-Born Reva", Tier: 1, Power: 0, Affinity: EShadow, HireCost: Cost{EWater: 2, ENature: 2}},
	{ID: "V-06", Name: "The Indexer", Tier: 1, Power: 0, Affinity: EShadow, HireCost: Cost{ELight: 1, EWater: 2, ENature: 1, EFire: 1}},
	{ID: "V-07", Name: "Shade the Shadow Thief", Tier: 1, Power: 0, Affinity: EShadow, HireCost: Cost{ENature: 3}},
	{ID: "V-08", Name: "Protocol-9 the Mediator", Tier: 1, Power: 1, Affinity: EShadow, HireCost: Cost{EFire: 4}},

	// â”€â”€ TIER 2 VOID BORN â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "V-09", Name: "Shadow Circuit Commander", Tier: 2, Power: 1, Affinity: EShadow, HireCost: Cost{EWater: 3, ENature: 3, EShadow: 2}},
	{ID: "V-10", Name: "Void Walker Cade", Tier: 2, Power: 1, Affinity: EShadow, HireCost: Cost{ELight: 3, EWater: 2, ENature: 2}},
	{ID: "V-11", Name: "The Memory Keeper", Tier: 2, Power: 2, Affinity: EShadow, HireCost: Cost{EWater: 4, ENature: 1, EFire: 2}},
	{ID: "V-12", Name: "Blackout, The Network Ghost", Tier: 2, Power: 2, Affinity: EShadow, HireCost: Cost{ENature: 5, EFire: 3}},
	{ID: "V-13", Name: "Null, The Unwritten", Tier: 2, Power: 2, Affinity: EShadow, HireCost: Cost{EShadow: 5}},
	{ID: "V-14", Name: "The Architect of Shadows", Tier: 2, Power: 3, Affinity: EShadow, HireCost: Cost{EShadow: 6}},

	// â”€â”€ TIER 3 VOID BORN â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	{ID: "V-15", Name: "The Obsidian Sovereign", Tier: 3, Power: 3, Affinity: EShadow, HireCost: Cost{ELight: 3, EWater: 3, ENature: 5, EFire: 3}},
	{ID: "V-16", Name: "Void Eternal, The Last Protocol", Tier: 3, Power: 4, Affinity: EShadow, HireCost: Cost{EFire: 7}},
	{ID: "V-17", Name: "Negentropy, The Shadow God", Tier: 3, Power: 4, Affinity: EShadow, HireCost: Cost{ELight: 3, EWater: 3, EFire: 6}},
	{ID: "V-18", Name: "Omega-Null, The End of Silence", Tier: 3, Power: 5, Affinity: EShadow, HireCost: Cost{EFire: 7, EShadow: 3}},
}

// AllArtifacts â€” 10 tiles, Splendor-exact noble requirements (GDD v2 Â§8).
// Requirement values are affinity counts (hired characters of that element).
var AllArtifacts = []Artifact{
	{ID: "A-01", Name: "Excalibur Reborn", Requirement: Cost{ENature: 4, ELight: 4}},
	{ID: "A-02", Name: "The Tidal Throne", Requirement: Cost{EWater: 4, ENature: 4}},
	{ID: "A-03", Name: "Crown of Ancient Roots", Requirement: Cost{ELight: 4, EShadow: 4}},
	{ID: "A-04", Name: "The Void Compass", Requirement: Cost{EFire: 4, EShadow: 4}},
	{ID: "A-05", Name: "The Ember Covenant", Requirement: Cost{EFire: 4, EWater: 4}},
	{ID: "A-06", Name: "The World-Root Staff", Requirement: Cost{ELight: 3, EWater: 3, ENature: 3}},
	{ID: "A-07", Name: "The Solar Spear", Requirement: Cost{EWater: 3, ENature: 3, EShadow: 3}},
	{ID: "A-08", Name: "The Abyssal Mirror", Requirement: Cost{ENature: 3, EFire: 3, EShadow: 3}},
	{ID: "A-09", Name: "The Stormheart", Requirement: Cost{ELight: 3, EFire: 3, EShadow: 3}},
	{ID: "A-10", Name: "The Eternal Circuit", Requirement: Cost{ELight: 3, EWater: 3, EFire: 3}},
}

// cardByID is a lookup map built at init time.
var cardByID map[string]*CharacterCard

func init() {
	cardByID = make(map[string]*CharacterCard, len(AllCards))
	for i := range AllCards {
		cardByID[AllCards[i].ID] = &AllCards[i]
	}
}

