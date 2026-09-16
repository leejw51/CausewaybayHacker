--- The name a wallet wears until somebody chooses one.
---
--- An address is 42 characters of hex and that is not a name. `hacker-58a57e`
--- was one — the first six of the address with a word in front — and it has
--- hex's problem: two accounts one player owns are `hacker-58a57e` and
--- `hacker-0d3eb2`, and neither is a thing anybody says out loud or recognises
--- a day later. So an account that has not chosen a name gets
--- `AdjectiveNoun####`, derived from the address and from nothing else:
---
---     hash = keccak256(utf8(lowercase(address)))   -- the "0x" is included
---     adj  = uint16(hash[0..2]) % #ADJECTIVES
---     noun = uint16(hash[2..4]) % #NOUNS
---     num  = uint16(hash[4..6]) % 10000            -- zero-padded to four
---
--- **The third implementation of this, and that is on purpose.** The server
--- (`backend/core/src/username.rs`) needs it to name a row nobody seeded; each
--- client needs it to show a name before there is an account to ask about.
--- All three carry the same word lists in the same order and the same four
--- test vectors, and the vectors are the thing that stops them drifting — a
--- login box that promised a name the server then disagreed with would be
--- worse than no box.
---
--- The lists are `PocketSkynet-invites`'s, so a player carries one name
--- between the projects. **Order is protocol.** A word inserted anywhere but
--- the end renames every account whose index falls after it; the lengths are
--- the modulus rather than a fact about the tables.
---
--- The keccak comes from the key library (`op = "keccak"`), because this
--- client already depends on it for every other hash and a second
--- implementation in Lua would be a second thing to be wrong.

local M = {}

--- 152 adjectives, in the reference order.
M.ADJECTIVES = {
  "Epic", "Cyber", "Neon", "Mystic", "Cosmic", "Shadow", "Phoenix", "Quantum", "Stellar",
  "Thunder", "Blaze", "Frost", "Storm", "Vortex", "Turbo", "Alpha", "Nova", "Prism", "Apex",
  "Titan", "Zephyr", "Crimson", "Onyx", "Jade", "Atomic", "Binary", "Chrome", "Digital",
  "Plasma", "Sonic", "Vector", "Hyper", "Nano", "Omega", "Delta", "Gamma", "Sigma", "Zero",
  "Neo", "Meta", "Pixel", "Glitch", "Matrix", "Neural", "Synth", "Techno", "Vertex",
  "Photon", "Solar", "Lunar", "Arctic", "Ember", "Aqua", "Terra", "Volt", "Aero", "Pyro",
  "Cryo", "Inferno", "Aurora", "Eclipse", "Nebula", "Typhoon", "Tsunami", "Magma", "Quake",
  "Tidal", "Volcanic", "Blizzard", "Tempest", "Savage", "Fierce", "Swift", "Silent",
  "Stealth", "Rapid", "Prime", "Ultra", "Mega", "Giga", "Super", "Elite", "Royal", "Noble",
  "Supreme", "Grand", "Majestic", "Imperial", "Dominant", "Mighty", "Valor", "Glory",
  "Arcane", "Astral", "Ethereal", "Void", "Dark", "Light", "Crystal", "Golden", "Silver",
  "Iron", "Steel", "Diamond", "Ruby", "Sapphire", "Obsidian", "Mythic", "Legendary",
  "Ancient", "Primal", "Divine", "Sacred", "Cursed", "Blessed", "Enchanted", "Rogue",
  "Rebel", "Wild", "Feral", "Brave", "Bold", "Daring", "Radiant", "Blazing", "Frozen",
  "Wicked", "Chaos", "Fury", "Venomous", "Lethal", "Fatal", "Deadly", "Ruthless", "Fearless",
  "Relentless", "Azure", "Scarlet", "Violet", "Indigo", "Cobalt", "Emerald", "Amber",
  "Ivory", "Ebony", "Platinum", "Copper", "Bronze", "Nether", "Astro", "Galactic",
  "Celestial",
}

--- 156 nouns, in the reference order.
M.NOUNS = {
  "Wolf", "Hawk", "Dragon", "Ninja", "Samurai", "Knight", "Ranger", "Hunter", "Warrior",
  "Guardian", "Phantom", "Viper", "Falcon", "Tiger", "Panther", "Raven", "Eagle", "Lion",
  "Shark", "Fox", "Lynx", "Cobra", "Bear", "Leopard", "Phoenix", "Griffin", "Hydra",
  "Kraken", "Sphinx", "Chimera", "Wyvern", "Raptor", "Basilisk", "Cerberus", "Leviathan",
  "Fenrir", "Pegasus", "Minotaur", "Gargoyle", "Wyrm", "Drake", "Behemoth", "Cyclops",
  "Titan", "Scorpion", "Mantis", "Spider", "Jaguar", "Puma", "Orca", "Crow", "Owl",
  "Serpent", "Python", "Mustang", "Stallion", "Rhino", "Gorilla", "Wolverine", "Badger",
  "Condor", "Vulture", "Barracuda", "Piranha", "Mamba", "Hornet", "Wasp", "Beetle",
  "Paladin", "Ronin", "Shogun", "Viking", "Spartan", "Gladiator", "Crusader", "Assassin",
  "Sentinel", "Warden", "Champion", "Commander", "Captain", "Admiral", "General", "Marshal",
  "Berserker", "Centurion", "Legionnaire", "Templar", "Mercenary", "Pirate", "Bandit",
  "Outlaw", "Wizard", "Sorcerer", "Mage", "Warlock", "Druid", "Shaman", "Oracle", "Prophet",
  "Reaper", "Specter", "Wraith", "Ghost", "Spirit", "Demon", "Angel", "Golem", "Necromancer",
  "Alchemist", "Enchanter", "Summoner", "Invoker", "Seraph", "Valkyrie", "Djinn", "Blade",
  "Sword", "Dagger", "Arrow", "Bolt", "Comet", "Meteor", "Pulsar", "Quasar", "Star", "Moon",
  "Sun", "Flame", "Striker", "Breaker", "Slayer", "Hammer", "Axe", "Spear", "Scythe",
  "Trident", "Shield", "Crown", "Throne", "Hacker", "Cipher", "Virus", "Coder", "Sniper",
  "Gunner", "Pilot", "Driver", "Racer", "Runner", "Bomber", "Tank", "Drone", "Mech",
  "Android", "Cyborg",
}

--- Pick the three parts out of a 32-byte digest given as `0x…` hex.
---
--- Split from `M.of` so the arithmetic can be tested against the published
--- vectors without a key library present — the tests run headless, and the
--- library is a `.dylib` that a headless run has no reason to load.
function M.from_digest(digest)
  local hex = tostring(digest):gsub("^0x", "")
  local function at(i)
    -- `i` counts bytes from zero; two hex characters to a byte, one-based.
    return tonumber(hex:sub(i * 2 + 1, i * 2 + 4), 16)
  end
  local adjective = M.ADJECTIVES[at(0) % #M.ADJECTIVES + 1]
  local noun = M.NOUNS[at(2) % #M.NOUNS + 1]
  return ("%s%s%04d"):format(adjective, noun, at(4) % 10000)
end

--- The name this address is known by when nobody has chosen one.
---
--- Hashes the **address**, never the phrase: the same wallet reached by
--- recovery phrase, by private key, or at a different account index is one
--- account and has to arrive at one name. Lowercased first, so a checksummed
--- spelling and a lowercase one agree.
---
--- Returns nil when the library is missing or refuses, because a missing name
--- is a box the player fills in and a raised error is a screen they cannot
--- use.
function M.of(lib, address)
  if not lib or type(address) ~= "string" or address == "" then return nil end
  local Wallet = require("src.wallet")
  local ok, reply = pcall(Wallet.keccak, lib, address:lower())
  if not ok or type(reply) ~= "table" or not reply.digest then return nil end
  return M.from_digest(reply.digest)
end

return M
