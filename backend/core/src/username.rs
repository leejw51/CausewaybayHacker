//! The name a wallet wears until somebody chooses one.
//!
//! An address is 42 characters of hex and that is not a name. `hacker-58a57e`
//! was one — it is the first six of the address with a word in front, which is
//! the same hex with the same problem: two accounts a player owns are
//! `hacker-58a57e` and `hacker-0d3eb2`, and neither is a thing you would say
//! out loud or recognise a day later.
//!
//! So an account that has not chosen a name gets `AdjectiveNoun####`, derived
//! from the address and from nothing else:
//!
//! ```text
//! hash   = keccak256(utf8(lowercase(address)))   // the "0x" is included
//! adj    = uint16(hash[0..2]) % ADJECTIVES.len()
//! noun   = uint16(hash[2..4]) % NOUNS.len()
//! num    = uint16(hash[4..6]) % 10000            // zero-padded to four
//! name   = ADJECTIVES[adj] + NOUNS[noun] + num
//! ```
//!
//! Two properties carry the weight, and both are pinned by the tests below.
//!
//! It hashes the **address**, never the phrase. The same wallet reached by
//! recovery phrase, by private key, or at a different account index is the
//! same account and must arrive at one name; hashing the credential would give
//! it a different name depending on how somebody signed in.
//!
//! The address is **lowercased** first, so a checksummed spelling and a
//! lowercase one agree. Callers here already normalise, which makes that
//! automatic — the test covers it anyway, because the invariant belongs to the
//! algorithm and not to the caller that happens to satisfy it.
//!
//! The algorithm and both word lists are `PocketSkynet-invites`'s, in its
//! order, so a player carries one name between the two. **Order is protocol.**
//! A word inserted anywhere but the end renames every account whose index
//! falls after it, and the lengths below are the modulus rather than a fact
//! about the arrays.

use sha3::{Digest, Keccak256};

/// 152 adjectives, in the reference order.
pub const ADJECTIVES: [&str; 152] = [
    "Epic",
    "Cyber",
    "Neon",
    "Mystic",
    "Cosmic",
    "Shadow",
    "Phoenix",
    "Quantum",
    "Stellar",
    "Thunder",
    "Blaze",
    "Frost",
    "Storm",
    "Vortex",
    "Turbo",
    "Alpha",
    "Nova",
    "Prism",
    "Apex",
    "Titan",
    "Zephyr",
    "Crimson",
    "Onyx",
    "Jade",
    "Atomic",
    "Binary",
    "Chrome",
    "Digital",
    "Plasma",
    "Sonic",
    "Vector",
    "Hyper",
    "Nano",
    "Omega",
    "Delta",
    "Gamma",
    "Sigma",
    "Zero",
    "Neo",
    "Meta",
    "Pixel",
    "Glitch",
    "Matrix",
    "Neural",
    "Synth",
    "Techno",
    "Vertex",
    "Photon",
    "Solar",
    "Lunar",
    "Arctic",
    "Ember",
    "Aqua",
    "Terra",
    "Volt",
    "Aero",
    "Pyro",
    "Cryo",
    "Inferno",
    "Aurora",
    "Eclipse",
    "Nebula",
    "Typhoon",
    "Tsunami",
    "Magma",
    "Quake",
    "Tidal",
    "Volcanic",
    "Blizzard",
    "Tempest",
    "Savage",
    "Fierce",
    "Swift",
    "Silent",
    "Stealth",
    "Rapid",
    "Prime",
    "Ultra",
    "Mega",
    "Giga",
    "Super",
    "Elite",
    "Royal",
    "Noble",
    "Supreme",
    "Grand",
    "Majestic",
    "Imperial",
    "Dominant",
    "Mighty",
    "Valor",
    "Glory",
    "Arcane",
    "Astral",
    "Ethereal",
    "Void",
    "Dark",
    "Light",
    "Crystal",
    "Golden",
    "Silver",
    "Iron",
    "Steel",
    "Diamond",
    "Ruby",
    "Sapphire",
    "Obsidian",
    "Mythic",
    "Legendary",
    "Ancient",
    "Primal",
    "Divine",
    "Sacred",
    "Cursed",
    "Blessed",
    "Enchanted",
    "Rogue",
    "Rebel",
    "Wild",
    "Feral",
    "Brave",
    "Bold",
    "Daring",
    "Radiant",
    "Blazing",
    "Frozen",
    "Wicked",
    "Chaos",
    "Fury",
    "Venomous",
    "Lethal",
    "Fatal",
    "Deadly",
    "Ruthless",
    "Fearless",
    "Relentless",
    "Azure",
    "Scarlet",
    "Violet",
    "Indigo",
    "Cobalt",
    "Emerald",
    "Amber",
    "Ivory",
    "Ebony",
    "Platinum",
    "Copper",
    "Bronze",
    "Nether",
    "Astro",
    "Galactic",
    "Celestial",
];

/// 156 nouns, in the reference order.
pub const NOUNS: [&str; 156] = [
    "Wolf",
    "Hawk",
    "Dragon",
    "Ninja",
    "Samurai",
    "Knight",
    "Ranger",
    "Hunter",
    "Warrior",
    "Guardian",
    "Phantom",
    "Viper",
    "Falcon",
    "Tiger",
    "Panther",
    "Raven",
    "Eagle",
    "Lion",
    "Shark",
    "Fox",
    "Lynx",
    "Cobra",
    "Bear",
    "Leopard",
    "Phoenix",
    "Griffin",
    "Hydra",
    "Kraken",
    "Sphinx",
    "Chimera",
    "Wyvern",
    "Raptor",
    "Basilisk",
    "Cerberus",
    "Leviathan",
    "Fenrir",
    "Pegasus",
    "Minotaur",
    "Gargoyle",
    "Wyrm",
    "Drake",
    "Behemoth",
    "Cyclops",
    "Titan",
    "Scorpion",
    "Mantis",
    "Spider",
    "Jaguar",
    "Puma",
    "Orca",
    "Crow",
    "Owl",
    "Serpent",
    "Python",
    "Mustang",
    "Stallion",
    "Rhino",
    "Gorilla",
    "Wolverine",
    "Badger",
    "Condor",
    "Vulture",
    "Barracuda",
    "Piranha",
    "Mamba",
    "Hornet",
    "Wasp",
    "Beetle",
    "Paladin",
    "Ronin",
    "Shogun",
    "Viking",
    "Spartan",
    "Gladiator",
    "Crusader",
    "Assassin",
    "Sentinel",
    "Warden",
    "Champion",
    "Commander",
    "Captain",
    "Admiral",
    "General",
    "Marshal",
    "Berserker",
    "Centurion",
    "Legionnaire",
    "Templar",
    "Mercenary",
    "Pirate",
    "Bandit",
    "Outlaw",
    "Wizard",
    "Sorcerer",
    "Mage",
    "Warlock",
    "Druid",
    "Shaman",
    "Oracle",
    "Prophet",
    "Reaper",
    "Specter",
    "Wraith",
    "Ghost",
    "Spirit",
    "Demon",
    "Angel",
    "Golem",
    "Necromancer",
    "Alchemist",
    "Enchanter",
    "Summoner",
    "Invoker",
    "Seraph",
    "Valkyrie",
    "Djinn",
    "Blade",
    "Sword",
    "Dagger",
    "Arrow",
    "Bolt",
    "Comet",
    "Meteor",
    "Pulsar",
    "Quasar",
    "Star",
    "Moon",
    "Sun",
    "Flame",
    "Striker",
    "Breaker",
    "Slayer",
    "Hammer",
    "Axe",
    "Spear",
    "Scythe",
    "Trident",
    "Shield",
    "Crown",
    "Throne",
    "Hacker",
    "Cipher",
    "Virus",
    "Coder",
    "Sniper",
    "Gunner",
    "Pilot",
    "Driver",
    "Racer",
    "Runner",
    "Bomber",
    "Tank",
    "Drone",
    "Mech",
    "Android",
    "Cyborg",
];

/// The name this address is known by when nobody has chosen one.
///
/// Always ASCII letters and digits ending in exactly four digits, which keeps
/// it inside the 48-character cap `users` applies and stops it colliding with
/// a bare dictionary word somebody picked by hand.
pub fn deterministic(address: &str) -> String {
    let lowered = address.to_ascii_lowercase();
    let digest = Keccak256::digest(lowered.as_bytes());
    let at = |i: usize| u16::from_be_bytes([digest[i], digest[i + 1]]) as usize;
    let adjective = ADJECTIVES[at(0) % ADJECTIVES.len()];
    let noun = NOUNS[at(2) % NOUNS.len()];
    let number = at(4) % 10_000;
    format!("{adjective}{noun}{number:04}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The reference implementation's own vectors, carried over verbatim.
    ///
    /// They are the whole point of matching `PocketSkynet-invites` rather than
    /// inventing a scheme: if either project edits a word list or the
    /// arithmetic, these stop agreeing and say so. The last two are the
    /// wallets this repo's own tests already sign in as.
    const VECTORS: [(&str, &str); 4] = [
        (
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            "OmegaMustang0198",
        ),
        (
            "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            "AmberLion9030",
        ),
        (
            "0x9858effd232b4033e47d90003d41ec34ecaeda94",
            "AmberEnchanter2784",
        ),
        (
            "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf",
            "AmberRunner7074",
        ),
    ];

    #[test]
    fn the_lists_are_the_reference_lists() {
        // The lengths are the modulus, so they are part of the contract. A
        // list that grew by one word renames roughly every account.
        assert_eq!(ADJECTIVES.len(), 152);
        assert_eq!(NOUNS.len(), 156);
    }

    #[test]
    fn names_match_the_reference_implementation() {
        for (address, want) in VECTORS {
            assert_eq!(deterministic(address), want, "diverged for {address}");
        }
    }

    #[test]
    fn the_casing_of_the_address_cannot_change_the_name() {
        assert_eq!(
            deterministic("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"),
            deterministic("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
        );
    }

    #[test]
    fn a_name_always_fits_what_the_user_row_will_take() {
        // `users` truncates to 48 characters, and a name the store then cuts
        // in half would be a different name on the screen than in the column.
        for i in 0u32..512 {
            let name = deterministic(&format!("0x{i:040x}"));
            assert!(name.chars().count() <= 48, "{name} is too long");
            assert!(name.chars().all(|c| c.is_ascii_alphanumeric()), "{name}");
            assert!(name[name.len() - 4..].chars().all(|c| c.is_ascii_digit()));
        }
    }

    #[test]
    fn the_whole_address_reaches_the_name() {
        let names: std::collections::HashSet<String> = (0u32..1024)
            .map(|i| deterministic(&format!("0x{i:040x}")))
            .collect();
        // Not "all distinct": 237 million names will collide eventually and
        // asserting otherwise would make this flaky. What matters is that the
        // name is a function of the address rather than of a few bits of it.
        assert!(names.len() > 1000, "only {} distinct names", names.len());
    }
}
